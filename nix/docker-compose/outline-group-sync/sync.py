"""LDAP-backed Authentik groups -> local Outline groups; never provision users."""

import argparse
import json
import os
from datetime import datetime, timedelta, timezone
from urllib.parse import quote, urljoin, urlsplit

import httpx


class SyncError(RuntimeError):
    """An incomplete or ambiguous snapshot must not change permissions."""


class API:
    def __init__(self, base, token, *, transport=None, progress=lambda: None):
        if urlsplit(base).scheme != "https":
            raise SyncError("API URLs must use HTTPS")
        self.base = base.rstrip("/") + "/"
        self.progress = progress
        self.client = httpx.Client(
            headers={"Authorization": "Bearer " + token},
            timeout=30,
            follow_redirects=False,
            transport=transport,
        )

    def close(self):
        self.client.close()

    def request(self, path, body=None):
        self.progress()
        url = urljoin(self.base, path)
        # Never forward a token to a pagination URL supplied by another origin.
        if not url.startswith(self.base) or urlsplit(url).fragment:
            raise SyncError("API pagination escaped the configured base URL")
        try:
            response = self.client.get(url) if body is None else self.client.post(url, json=body)
            response.raise_for_status()
        except httpx.HTTPError as exc:
            # Response bodies and headers can contain credentials or personal data.
            status = (
                exc.response.status_code if isinstance(exc, httpx.HTTPStatusError) else "network"
            )
            raise SyncError(f"API request failed ({status}) at {urlsplit(url).path}") from None
        try:
            result = response.json()
        except ValueError:
            raise SyncError("API returned invalid JSON") from None
        if not isinstance(result, dict):
            raise SyncError("API returned an unexpected response")
        return result

    def authentik_list(self, path):
        rows, seen = [], set()
        page, pages, count = 1, None, None
        while True:
            separator = "&" if "?" in path else "?"
            result = self.request(f"{path}{separator}page={page}&page_size=100")
            pagination = result["pagination"]
            if pages is None:
                pages, count = pagination["total_pages"], pagination["count"]
            if (pagination["total_pages"], pagination["count"]) != (pages, count):
                raise SyncError("Authentik changed during pagination; retry")
            batch = result["results"]
            if not isinstance(batch, list):
                raise SyncError("Invalid Authentik results")
            for row in batch:
                if row["pk"] in seen:
                    raise SyncError("Duplicate Authentik result during pagination")
                seen.add(row["pk"])
            rows.extend(batch)
            if not pagination["next"]:
                if len(rows) != count or page != max(1, pages):
                    raise SyncError("Incomplete Authentik pagination")
                return rows
            if not batch or page >= pages:
                raise SyncError("Invalid Authentik pagination")
            page += 1

    def outline(self, method, **body):
        result = self.request(method, body)
        if result.get("ok") is not True:
            raise SyncError(f"Outline rejected {method}")
        return result

    def outline_list(self, method, key=None, **body):
        rows, seen = [], set()
        offset, total = 0, None
        while True:
            result = self.outline(method, offset=offset, limit=100, **body)
            current_total = result["pagination"]["total"]
            if total is None:
                total = current_total
            if current_total != total:
                raise SyncError("Outline changed during pagination; retry")
            batch = result["data"][key] if key else result["data"]
            if not isinstance(batch, list):
                raise SyncError("Invalid Outline results")
            for row in batch:
                if row["id"] in seen:
                    raise SyncError("Duplicate Outline result during pagination")
                seen.add(row["id"])
            rows.extend(batch)
            offset += len(batch)
            if offset == total:
                return rows
            if not batch or offset > total:
                raise SyncError("Incomplete Outline pagination")


def index_unique(rows, key):
    result = {}
    for row in rows:
        value = key(row)
        if not value or value in result:
            raise SyncError("Missing or duplicate identity in snapshot")
        result[value] = row
    return result


def email(row):
    value = row.get("email")
    return value.strip().casefold() if isinstance(value, str) else ""


def assert_sync_healthy(status, max_age_hours):
    if status.get("is_running") is not False:
        raise SyncError("LDAP sync is running or its status is unknown")
    # Authentik TaskStatus DONE/INFO represent successful sync tasks.
    if status.get("last_sync_status") not in ("done", "info"):
        raise SyncError("LDAP last sync was not successful")
    try:
        last = datetime.fromisoformat(status["last_successful_sync"].replace("Z", "+00:00"))
        age = datetime.now(timezone.utc) - last
    except (KeyError, TypeError, ValueError):
        raise SyncError("LDAP sync has no valid successful timestamp") from None
    if age < timedelta(minutes=-5) or age > timedelta(hours=max_age_hours):
        raise SyncError("LDAP sync snapshot is stale")


def plan_sync(source_id, ldap_groups, ak_users, outline_groups, outline_users, memberships):
    """Return API operations after validating the entire snapshot, including collisions.

    externalId records ownership and survives LDAP renames. Same-name local groups
    are adopted. Removed LDAP groups are emptied, never deleted (preserves grants).
    """
    prefix = f"krg-ldap:{source_id}:"
    desired_groups = index_unique(ldap_groups, lambda g: g["pk"])
    index_unique(ldap_groups, lambda g: g["name"])
    by_name = index_unique(outline_groups, lambda g: g["name"])
    by_external = index_unique(
        [g for g in outline_groups if g.get("externalId")], lambda g: g["externalId"]
    )
    # Blank emails cannot match; duplicate nonblank emails must never pick a winner.
    ak_by_email = index_unique([u for u in ak_users if email(u)], email)
    ol_by_email = index_unique(outline_users, email)
    desired_members = {pk: set() for pk in desired_groups}
    for address, user in ol_by_email.items():
        ak = ak_by_email.get(address)
        if not ak or ak["is_active"] is not True or ak["type"] != "internal":
            continue
        if user.get("isSuspended") or user.get("role") == "guest":
            continue
        for pk in ak["groups"]:
            if pk in desired_members:
                desired_members[pk].add(user["id"])

    operations, used = [], set()
    for pk, source in sorted(desired_groups.items()):
        external_id = prefix + pk
        target = by_external.get(external_id)
        same_name = by_name.get(source["name"])
        if target and same_name and target["id"] != same_name["id"]:
            raise SyncError("LDAP rename collides with another Outline group")
        target = target or same_name
        if target:
            if target.get("externalGroup") or target.get("externalId") not in (
                None,
                "",
                external_id,
            ):
                raise SyncError("Outline group belongs to another external source")
            if target["id"] in used:
                raise SyncError("Multiple LDAP groups map to one Outline group")
            used.add(target["id"])
            group_id = target["id"]
            if target.get("externalId") != external_id or target["name"] != source["name"]:
                operations.append(
                    {
                        "method": "groups.update",
                        "id": group_id,
                        "name": source["name"],
                        "externalId": external_id,
                    }
                )
            current = memberships[group_id]
        else:
            # Symbolic ID is resolved by apply_plan after groups.create.
            group_id = external_id
            current = set()
            operations.append(
                {"method": "groups.create", "name": source["name"], "externalId": external_id}
            )
        for user_id in sorted(desired_members[pk] - current):
            operations.append({"method": "groups.add_user", "id": group_id, "userId": user_id})
        for user_id in sorted(current - desired_members[pk]):
            operations.append({"method": "groups.remove_user", "id": group_id, "userId": user_id})

    for group in outline_groups:
        if (group.get("externalId") or "").startswith(prefix) and group["id"] not in used:
            if group.get("externalGroup"):
                raise SyncError("Managed group is now owned by an external provider")
            for user_id in sorted(memberships[group["id"]]):
                operations.append(
                    {"method": "groups.remove_user", "id": group["id"], "userId": user_id}
                )
    return operations


def apply_plan(outline, operations, progress=lambda: None):
    created = {}
    for operation in operations:
        progress()
        body = {k: v for k, v in operation.items() if k != "method"}
        if "id" in body:
            body["id"] = created.get(body["id"], body["id"])
        result = outline.outline(operation["method"], **body)
        if operation["method"] == "groups.create":
            created[body["externalId"]] = result["data"]["id"]


def reconcile(
    authentik, outline, source_slug, *, apply=False, max_age_hours=24, progress=lambda: None
):
    source_path = f"sources/ldap/{quote(source_slug, safe='')}/"
    source = authentik.request(source_path)
    if source["enabled"] is not True or source["sync_groups"] is not True:
        raise SyncError("LDAP source is disabled or does not sync groups")
    before = authentik.request(source_path + "sync/status/")
    assert_sync_healthy(before, max_age_hours)
    source_id = source["pk"]
    links = authentik.authentik_list("sources/group_connections/ldap/")
    group_ids = {link["group"] for link in links if link["source"] == source_id}
    if not group_ids:
        raise SyncError("No LDAP-backed groups found; refusing an empty directory snapshot")
    progress()
    groups = authentik.authentik_list("core/groups/")
    ldap_groups = [g for g in groups if g["pk"] in group_ids]
    if {g["pk"] for g in ldap_groups} != group_ids:
        raise SyncError("LDAP group source connections reference unreadable groups")
    users = authentik.authentik_list("core/users/")
    progress()
    ol_users = outline.outline_list("users.list")
    ol_groups = outline.outline_list("groups.list", "groups")
    relevant = {g["name"] for g in ldap_groups}
    prefix = f"krg-ldap:{source_id}:"
    memberships = {}
    for group in ol_groups:
        if group["name"] in relevant or (group.get("externalId") or "").startswith(prefix):
            progress()
            rows = outline.outline_list("groups.memberships", "groupMemberships", id=group["id"])
            memberships[group["id"]] = {row["userId"] for row in rows}
    after = authentik.request(source_path + "sync/status/")
    assert_sync_healthy(after, max_age_hours)
    if before != after:
        raise SyncError("LDAP sync changed while reading; retry")
    operations = plan_sync(source_id, ldap_groups, users, ol_groups, ol_users, memberships)
    if apply:
        apply_plan(outline, operations, progress)
    return {"apply": apply, "operations": operations}


def from_env(*, apply=False, progress=lambda: None):
    authentik = API(os.environ["AUTHENTIK_URL"], os.environ["AUTHENTIK_TOKEN"], progress=progress)
    outline = API(os.environ["OUTLINE_URL"], os.environ["OUTLINE_TOKEN"], progress=progress)
    try:
        return reconcile(
            authentik,
            outline,
            os.environ.get("AUTHENTIK_LDAP_SOURCE", "krg-samba-ad"),
            apply=apply,
            max_age_hours=float(os.environ.get("LDAP_MAX_AGE_HOURS", "24")),
            progress=progress,
        )
    finally:
        authentik.close()
        outline.close()


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--apply", action="store_true", help="Write changes (default: dry run)")
    print(json.dumps(from_env(apply=parser.parse_args().apply), indent=2))
