import asyncio
import copy
import json
from datetime import datetime, timedelta, timezone

import httpx
import pytest
from temporalio import workflow as temporal_workflow
from temporalio.worker.workflow_sandbox import SandboxedWorkflowRunner

from sync import API, SyncError, assert_sync_healthy, plan_sync, reconcile
from worker import schedule
from workflow import OutlineGroupSync


def ak_user(**changes):
    return {
        "pk": 1,
        "email": "a@ucsd.edu",
        "is_active": True,
        "type": "internal",
        "groups": ["g1"],
        **changes,
    }


def ol_group(**changes):
    return {"id": "o1", "name": "FishSense", "externalId": "krg-ldap:source:g1", **changes}


def plan(groups=None, users=None, ol_groups=None, ol_users=None, memberships=None):
    return plan_sync(
        "source",
        [{"pk": "g1", "name": "FishSense"}] if groups is None else groups,
        [ak_user()] if users is None else users,
        [ol_group()] if ol_groups is None else ol_groups,
        [{"id": "u1", "email": "A@ucsd.edu"}] if ol_users is None else ol_users,
        {"o1": set()} if memberships is None else memberships,
    )


def test_creates_groups_without_provisioning_missing_people():
    ops = plan(ol_groups=[], ol_users=[])
    assert ops == [
        {"method": "groups.create", "name": "FishSense", "externalId": "krg-ldap:source:g1"}
    ]


def test_existing_user_matched_case_insensitively_and_membership_removed():
    assert plan(memberships={"o1": {"stale"}}) == [
        {"method": "groups.add_user", "id": "o1", "userId": "u1"},
        {"method": "groups.remove_user", "id": "o1", "userId": "stale"},
    ]


def test_converged_plan_is_empty():
    assert plan(memberships={"o1": {"u1"}}) == []


@pytest.mark.parametrize(
    "changes", [{"is_active": False}, {"type": "external"}, {"type": "service_account"}]
)
def test_ineligible_authentik_user_loses_managed_membership(changes):
    assert plan(users=[ak_user(**changes)], memberships={"o1": {"u1"}}) == [
        {"method": "groups.remove_user", "id": "o1", "userId": "u1"}
    ]


def test_same_name_local_group_adopted_and_rename_preserves_id():
    ops = plan(ol_groups=[ol_group(externalId=None)])
    assert ops[0] == {
        "method": "groups.update",
        "id": "o1",
        "name": "FishSense",
        "externalId": "krg-ldap:source:g1",
    }
    ops = plan(groups=[{"pk": "g1", "name": "New name"}])
    assert ops[0]["id"] == "o1"
    assert ops[0]["name"] == "New name"


def test_deleted_ldap_group_emptied_unrelated_group_untouched():
    assert plan(
        groups=[],
        ol_groups=[ol_group(), ol_group(id="manual", name="Manual", externalId=None)],
        memberships={"o1": {"u1"}},
    ) == [{"method": "groups.remove_user", "id": "o1", "userId": "u1"}]


@pytest.mark.parametrize(
    "changes", [{"externalGroup": {"id": "enterprise"}}, {"externalId": "another-source"}]
)
def test_external_provider_collision_fails(changes):
    with pytest.raises(SyncError):
        plan(ol_groups=[ol_group(**changes)])


def test_duplicate_email_fails_even_if_one_is_inactive():
    with pytest.raises(SyncError):
        plan(users=[ak_user(), ak_user(pk=2, email="A@ucsd.edu", is_active=False)])


def test_missing_email_in_outline_fails_before_removal():
    with pytest.raises(SyncError):
        plan(ol_users=[{"id": "u1"}])


def test_rename_name_collision_fails_before_any_write():
    with pytest.raises(SyncError):
        plan(
            groups=[{"pk": "g1", "name": "Taken"}],
            ol_groups=[ol_group(), ol_group(id="o2", name="Taken", externalId=None)],
        )


class Server:
    """Stateful API fixture: uses the versioned serializers' actual response shapes."""

    def __init__(self):
        self.groups = []
        self.members = {}
        self.writes = []
        self.status = {
            "is_running": False,
            "last_sync_status": "done",
            "last_successful_sync": datetime.now(timezone.utc).isoformat(),
        }
        self.fail_read = None
        self.fail_add_once = False

    def handle(self, request):
        path = request.url.path
        if path == self.fail_read:
            return httpx.Response(503)
        if path.endswith("/sync/status/"):
            return httpx.Response(200, json=self.status)
        if path.endswith("/sources/ldap/krg-samba-ad/"):
            return httpx.Response(200, json={"pk": "source", "enabled": True, "sync_groups": True})
        ak = {
            "/api/v3/sources/group_connections/ldap/": [
                {"pk": "link", "source": "source", "group": "g1"}
            ],
            "/api/v3/core/groups/": [
                {"pk": "g1", "name": "FishSense"},
                {"pk": "local", "name": "Authentik admins"},
            ],
            "/api/v3/core/users/": [ak_user()],
        }
        if path in ak:
            rows = ak[path]
            return httpx.Response(
                200,
                json={
                    "pagination": {"next": 0, "total_pages": 1, "count": len(rows)},
                    "results": rows,
                },
            )
        body = json.loads(request.content)
        method = path.split("/")[-1]
        if method == "groups.list":
            data = {"groups": self.groups}
            total = len(self.groups)
        elif method == "users.list":
            data, total = [{"id": "u1", "email": "a@ucsd.edu"}], 1
        elif method == "groups.memberships":
            rows = [{"id": uid + "-o1", "userId": uid} for uid in sorted(self.members[body["id"]])]
            data, total = {"groupMemberships": rows}, len(rows)
        else:
            if method == "groups.add_user" and self.fail_add_once:
                self.fail_add_once = False
                return httpx.Response(429)
            self.writes.append((method, body))
            if method == "groups.create":
                group = {"id": "o1", **body}
                self.groups.append(group)
                self.members["o1"] = set()
                return httpx.Response(200, json={"ok": True, "data": group})
            if method == "groups.add_user":
                self.members[body["id"]].add(body["userId"])
            elif method == "groups.remove_user":
                self.members[body["id"]].discard(body["userId"])
            else:
                raise AssertionError(method)
            return httpx.Response(200, json={"ok": True, "data": {}})
        return httpx.Response(
            200, json={"ok": True, "data": copy.deepcopy(data), "pagination": {"total": total}}
        )


def apis(server):
    transport = httpx.MockTransport(server.handle)
    return API("https://auth.test/api/v3/", "ak", transport=transport), API(
        "https://docs.test/api/", "ol", transport=transport
    )


def test_full_dry_run_apply_and_repeat_no_user_or_collection_writes():
    server = Server()
    ak, ol = apis(server)
    dry = reconcile(ak, ol, "krg-samba-ad")
    assert [op["method"] for op in dry["operations"]] == ["groups.create", "groups.add_user"]
    assert server.writes == []
    reconcile(ak, ol, "krg-samba-ad", apply=True)
    assert server.members == {"o1": {"u1"}}
    assert reconcile(ak, ol, "krg-samba-ad", apply=True)["operations"] == []
    assert len(server.writes) == 2


def test_partial_write_retry_reuses_group():
    server = Server()
    server.fail_add_once = True
    ak, ol = apis(server)
    with pytest.raises(SyncError, match="429"):
        reconcile(ak, ol, "krg-samba-ad", apply=True)
    reconcile(ak, ol, "krg-samba-ad", apply=True)
    assert len(server.groups) == 1
    assert server.members == {"o1": {"u1"}}


def test_read_failure_before_mutations():
    server = Server()
    server.groups = [ol_group()]
    server.fail_read = "/api/groups.memberships"
    ak, ol = apis(server)
    with pytest.raises(SyncError):
        reconcile(ak, ol, "krg-samba-ad", apply=True)
    assert server.writes == []


@pytest.mark.parametrize(
    "change",
    [
        {"is_running": True},
        {"last_sync_status": "error"},
        {"last_successful_sync": "2020-01-01T00:00:00Z"},
        {"last_successful_sync": "invalid"},
    ],
)
def test_unhealthy_ldap_sync_prevents_changes(change):
    server = Server()
    server.status.update(change)
    ak, ol = apis(server)
    with pytest.raises(SyncError):
        reconcile(ak, ol, "krg-samba-ad", apply=True)
    assert server.writes == []


@pytest.mark.parametrize("kind", ["authentik", "outline"])
def test_pagination_reads_more_than_one_hundred_members(kind):
    def handle(request):
        if kind == "authentik":
            page = int(request.url.params["page"])
            start, end = (0, 100) if page == 1 else (100, 123)
            return httpx.Response(
                200,
                json={
                    "pagination": {"next": 2 if page == 1 else 0, "count": 123, "total_pages": 2},
                    "results": [{"pk": str(i)} for i in range(start, end)],
                },
            )
        body = json.loads(request.content)
        start = body["offset"]
        return httpx.Response(
            200,
            json={
                "ok": True,
                "pagination": {"total": 123},
                "data": {
                    "groupMemberships": [
                        {"id": str(i)} for i in range(start, min(start + 100, 123))
                    ]
                },
            },
        )

    api = API("https://test/api/", "secret", transport=httpx.MockTransport(handle))
    rows = (
        api.authentik_list("groups/")
        if kind == "authentik"
        else api.outline_list("groups.memberships", "groupMemberships", id="o1")
    )
    assert len(rows) == 123


def test_incomplete_pagination_fails():
    api = API(
        "https://test/api/",
        "secret",
        transport=httpx.MockTransport(
            lambda r: httpx.Response(
                200,
                json={
                    "pagination": {"next": 0, "total_pages": 1, "count": 2},
                    "results": [{"pk": "one"}],
                },
            )
        ),
    )
    with pytest.raises(SyncError):
        api.authentik_list("groups/")


def test_pagination_cannot_send_credentials_to_another_origin():
    api = API("https://test/api/", "secret")
    with pytest.raises(SyncError):
        api.request("https://attacker.test/api/")


def test_sync_age_limit():
    assert_sync_healthy(
        {
            "is_running": False,
            "last_sync_status": "info",
            "last_successful_sync": (datetime.now(timezone.utc) - timedelta(hours=1)).isoformat(),
        },
        24,
    )


def test_workflow_sandbox_and_schedule():
    async def prepare():
        SandboxedWorkflowRunner().prepare_workflow(
            temporal_workflow._Definition.must_from_class(OutlineGroupSync)
        )

    asyncio.run(prepare())
    assert schedule().spec.intervals[0].every == timedelta(minutes=5)
    assert schedule().policy.overlap.name == "SKIP"
