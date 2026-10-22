"""compose-reload — apply a changed compose stack without taking it down.

The krg.composeStacks ExecReload for stacks with `reloadOnChange = true` (ADR 0024 P1).
A plain `docker compose up -d` already recreates only the services whose config
changed, but it recreates them IN PLACE: the old container stops before the new one
exists, so every changed service has an outage. For services labelled

    labels:
      krg.rollout: handoff

this does a graceful handoff instead, the same dance as wowu/docker-rollout (which we
can't use directly: it has no --project-directory, and every stack here needs one):

  1. scale the service to 2x with --no-recreate, so the NEW container starts next to
     the old one (Traefik load-balances across every healthy container of a service);
  2. wait for the new container's healthcheck to report healthy;
  3. if the old container's healthcheck honours the DRAIN FILE (below), create it and
     wait for the old container to report unhealthy, so Traefik stops routing to it;
  4. wait a short drain so in-flight requests finish and Traefik has caught up;
  5. stop + remove the old container (stop_signal, honouring stop_grace_period).

Draining. Without step 3, Traefik keeps sending requests to the old container until it
sees the container die, and a request caught in that window hangs with no response
(measured: ~1 per handoff). A service opts in by making its healthcheck fail while
/tmp/krg-drain exists, e.g.

    healthcheck:
      test: ["CMD-SHELL", "test ! -f /tmp/krg-drain && wget -q -O /dev/null http://127.0.0.1/"]

The image needs a shell with `test` + `touch`. Without the opt-in (or in a distroless
image) the handoff still works; it just skips step 3.

Every other changed service is left to the final `up -d`, which recreates it in place
exactly as before.

Bind-mounted config (issue #458). Compose's config hash does not see a CHANGE TO THE
CONTENT of a bind-mounted file or directory, and this repo mounts committed config via
tmpfiles `L+` symlinks into the Nix store (./grafana, ./loki/loki-config.yaml, ...), so
a config-only change would otherwise never reach the running container. With --state,
this records a fingerprint of each service's bind-mount sources after every successful
reload and treats a service whose fingerprint changed as changed: a handoff for handoff
services, and `up -d --no-deps --force-recreate` for the rest. A source that resolves
into the Nix store is fingerprinted by its CONTENT, not its path: krg-prod's L+ links
all point into ONE store path (the whole compose dir), so any edit anywhere moves every
link — fingerprinting the path recreated every config-mounting service on every change
(seen on the first production handoff). Other sources (data dirs) keep their resolved
path, which doesn't change. The first run (no state, or an older state format) only
records: enabling or upgrading this recreates nothing.

FAIL SAFE, which is the point of doing this carefully: if a new container never
becomes healthy, it is removed, the OLD container keeps serving, and this exits
non-zero WITHOUT running the final `up -d` (which would otherwise recreate the
service in place with the bad config and take it down). The unit's reload fails
loudly; nothing that was serving stops serving.

A handoff service must have: a healthcheck, no container_name, no host `ports:`
(two containers can't share a name or a host port), and old + new versions able to
run against the same database at once (true for patch/digest bumps, not for upgrades
that migrate a schema). A service that is labelled but ineligible falls back to the
in-place recreate, with the reason logged.

Usage (from the unit; everything after `--` is the stack's base compose command):

    compose-reload [--timeout S] [--drain S] [--state FILE] [--dry-run] -- docker compose --project-directory D -f F ...
"""

import argparse
import hashlib
import json
import os
import subprocess
import sys
import time

ROLLOUT_LABEL = "krg.rollout"
HASH_LABEL = "com.docker.compose.config-hash"
DRAIN_FILE = "/tmp/krg-drain"


def log(msg):
    print(f"compose-reload: {msg}", flush=True)


def run(argv):
    """Run a command and return its stdout; raise CalledProcessError on failure."""
    return subprocess.run(argv, check=True, capture_output=True, text=True).stdout


class Stack:
    """The docker/compose calls this tool makes. `runner` is injectable for tests."""

    def __init__(self, compose_cmd, runner=run):
        self.compose_cmd = list(compose_cmd)
        self.docker = self.compose_cmd[0]  # .../bin/docker; `compose` is a subcommand
        self.runner = runner

    def compose(self, *args):
        return self.runner(self.compose_cmd + list(args))

    def docker_cmd(self, *args):
        return self.runner([self.docker] + list(args))

    def specs(self):
        """Resolved compose config: {service: spec}."""
        return json.loads(self.compose("config", "--format", "json")).get("services", {})

    def desired_hashes(self):
        """{service: config-hash} as compose would stamp it on a fresh container."""
        hashes = {}
        for line in self.compose("config", "--hash", "*").splitlines():
            parts = line.split()
            if len(parts) == 2:
                hashes[parts[0]] = parts[1]
        return hashes

    def running(self, service):
        """IDs of the service's RUNNING containers."""
        return self.compose("ps", "--quiet", service).split()

    def all_containers(self, service):
        """IDs of ALL the service's containers, including ones that already exited."""
        return self.compose("ps", "--all", "--quiet", service).split()

    def container_hash(self, cid):
        fmt = '{{index .Config.Labels "' + HASH_LABEL + '"}}'
        return self.docker_cmd("inspect", "--format", fmt, cid).strip()

    def drains(self, cid):
        """Whether this container's healthcheck fails while DRAIN_FILE exists."""
        return DRAIN_FILE in self.docker_cmd(
            "inspect", "--format", "{{json .Config.Healthcheck}}", cid
        )

    def health(self, cid):
        """(state, health): e.g. ("running", "healthy"); health is "none" without a check."""
        fmt = "{{.State.Status}} {{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}"
        out = self.docker_cmd("inspect", "--format", fmt, cid).split()
        return (out[0], out[1]) if len(out) == 2 else ("unknown", "unknown")


def ineligible(spec):
    """Why a labelled service can't be handed off, or None if it can."""
    if spec.get("container_name"):
        return "has container_name (two containers can't share a name)"
    if spec.get("ports"):
        return "publishes host ports (two containers can't bind the same port)"
    hc = spec.get("healthcheck") or {}
    if not hc or hc.get("disable") or hc.get("test") in (["NONE"], "NONE"):
        return "has no healthcheck (nothing to tell when the new container is ready)"
    return None


STATE_VERSION = 2  # 2: store-path mounts fingerprinted by CONTENT (see mount_fingerprints)
STORE = "/nix/store/"


def content_hash(path):
    """sha256 over a file's bytes, or a directory tree's names, file bytes and symlink
    targets (sorted, not following links). Only ever run on /nix/store paths: small,
    immutable config."""
    h = hashlib.sha256()
    if os.path.isfile(path):
        with open(path, "rb") as f:
            h.update(f.read())
        return h.hexdigest()
    for root, dirs, files in os.walk(path):
        dirs.sort()
        for name in sorted(files) + sorted(
            d for d in dirs if os.path.islink(os.path.join(root, d))
        ):
            p = os.path.join(root, name)
            h.update(os.path.relpath(p, path).encode() + b"\0")
            if os.path.islink(p):
                h.update(b"L" + os.readlink(p).encode())
            elif os.path.isfile(p):
                with open(p, "rb") as f:
                    h.update(b"F" + f.read())
            h.update(b"\0")
    return h.hexdigest()


def mount_fingerprints(specs, resolve=os.path.realpath, store=None):
    """{service: sorted fingerprints of its bind-mount sources} — see "Bind-mounted config".

    A source that resolves into the Nix store is fingerprinted by CONTENT, not path:
    krg-prod's L+ links all point into ONE store path (the whole compose directory), so
    any change anywhere in it moves every link even when a service's own config is
    byte-identical. Anything else (data dirs, sockets, /var/log) keeps its resolved
    path, which doesn't change, so it never triggers a recreate.
    """
    store = store or STORE
    cache = {}
    out = {}
    for svc, spec in specs.items():
        fps = []
        for v in spec.get("volumes") or []:
            if not (isinstance(v, dict) and v.get("type") == "bind" and v.get("source")):
                continue
            real = resolve(v["source"])
            if real.startswith(store) and os.path.exists(real):
                if real not in cache:
                    cache[real] = "sha256:" + content_hash(real)
                fps.append(cache[real])
            else:
                fps.append(real)
        out[svc] = sorted(fps)
    return out


def mounts_changed(prev, cur):
    """Services whose resolved mount sources moved since the last successful reload.

    No previous state (first run) → nothing: record, don't force.
    """
    if prev is None:
        return set()
    return {svc for svc, srcs in cur.items() if svc in prev and prev[svc] != srcs}


def load_state(path):
    """Previous fingerprints, or None if absent, unreadable, or from another VERSION
    (a format change must re-record, not read as "everything changed")."""
    try:
        with open(path, encoding="utf-8") as f:
            state = json.load(f)
    except (OSError, ValueError):
        return None
    if state.get("version") != STATE_VERSION:
        return None
    return state.get("mounts")


def save_state(path, mounts):
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump({"version": STATE_VERSION, "mounts": mounts}, f, indent=1, sort_keys=True)
    os.replace(tmp, path)


def plan(stack, forced=frozenset()):
    """[(service, old_container_ids)] to hand off; logs every labelled service skipped.

    `forced`: services whose mounted config changed (compose's hash can't see it).
    """
    specs = stack.specs()
    desired = stack.desired_hashes()
    todo = []
    for svc in sorted(specs):
        spec = specs[svc]
        if (spec.get("labels") or {}).get(ROLLOUT_LABEL) != "handoff":
            continue
        old = stack.running(svc)
        if not old:
            log(f"{svc}: not running, `up -d` will start it")
            continue
        if svc not in forced and all(stack.container_hash(c) == desired.get(svc) for c in old):
            continue  # unchanged: `up -d` leaves it alone
        if len(old) > 1:
            log(
                f"{svc}: changed, but {len(old)} containers are running (an interrupted handoff?); recreating in place"
            )
            continue
        reason = ineligible(spec)
        if reason:
            log(f"{svc}: changed, but {reason}; recreating in place")
            continue
        todo.append((svc, old))
    return todo


def handoff(stack, svc, old, timeout, drain, poll=2.0, sleep=time.sleep, clock=time.monotonic):
    """Start the new container next to the old one, then retire the old. True on success."""
    log(f"{svc}: handing off ({len(old)} -> {len(old)} new)")
    stack.compose(
        "up", "--detach", "--no-deps", "--no-recreate", "--scale", f"{svc}={2 * len(old)}", svc
    )
    # --all: a new container that crashed on start is not "running", but it must still be
    # found, judged failed, and removed, or it lingers and confuses the next reload.
    new = [c for c in stack.all_containers(svc) if c not in old]
    if len(new) != len(old):
        log(f"{svc}: expected {len(old)} new container(s), found {len(new)}")
        return _abort(stack, svc, new)

    deadline = clock() + timeout
    while True:
        states = [stack.health(c) for c in new]
        # State first: an exited container can still report its last (stale) "healthy".
        if all(s == "running" and h == "healthy" for s, h in states):
            break
        if any(s != "running" or h == "unhealthy" for s, h in states):
            log(f"{svc}: new container failed: {states}")
            return _abort(stack, svc, new)
        if clock() >= deadline:
            log(f"{svc}: new container not healthy after {timeout}s: {states}")
            return _abort(stack, svc, new)
        sleep(poll)

    log(f"{svc}: new container healthy")
    _drain(stack, svc, old, timeout, poll, sleep, clock)
    log(f"{svc}: waiting {drain}s before retiring the old container")
    sleep(drain)
    stack.docker_cmd("stop", *old)
    stack.docker_cmd("rm", *old)
    log(f"{svc}: handoff complete")
    return True


def _drain(stack, svc, old, timeout, poll, sleep, clock):
    """Take the old container(s) out of Traefik's rotation before stopping them.

    Only for containers whose own healthcheck honours DRAIN_FILE; the OLD container's
    check is what matters, so the first handoff after adding the opt-in skips this.
    Best effort: if a container never reports unhealthy, stopping it is still no
    worse than not draining.
    """
    targets = []
    for c in old:
        try:
            if stack.drains(c):
                stack.docker_cmd("exec", c, "touch", DRAIN_FILE)
                targets.append(c)
        except subprocess.CalledProcessError as e:
            # e.g. no /tmp or no `touch` in the image: skip draining, never abort the
            # handoff over it (the new container is already healthy and serving).
            log(f"{svc}: could not drain {c[:12]} ({e}); stopping it without draining")
    if not targets:
        return
    log(f"{svc}: draining the old container (waiting for it to report unhealthy)")
    deadline = clock() + timeout
    while True:
        states = [stack.health(c) for c in targets]
        if all(s != "running" or h == "unhealthy" for s, h in states):
            return
        if clock() >= deadline:
            log(f"{svc}: old container still {states} after {timeout}s; stopping it anyway")
            return
        sleep(poll)


def _safe_handoff(stack, svc, old, args):
    """handoff(), but an unexpected error counts as a FAILED handoff, never a crash.

    A crash mid-handoff can leave the new container running beside the old one; if the
    old one is still running, remove the extra container(s) so it keeps serving alone,
    and main() skips the final `up -d`.
    """
    try:
        return handoff(stack, svc, old, args.timeout, args.drain)
    except Exception as e:  # noqa: BLE001 — any failure must leave the old container serving
        log(f"{svc}: handoff error: {e}")
        try:
            if any(c in stack.running(svc) for c in old):
                return _abort(stack, svc, [c for c in stack.all_containers(svc) if c not in old])
        except subprocess.CalledProcessError as e2:
            log(f"{svc}: cleanup after the error also failed: {e2}")
        return False


def _abort(stack, svc, new):
    """Remove the failed new container(s); the old ones are untouched and keep serving."""
    for c in new:
        try:
            log(f"{svc}: last logs of {c[:12]}:\n" + stack.docker_cmd("logs", "--tail", "50", c))
        except subprocess.CalledProcessError:
            pass
    if new:
        stack.docker_cmd("stop", *new)
        stack.docker_cmd("rm", *new)
    log(f"{svc}: handoff ABORTED; the old container is still serving")
    return False


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument(
        "--timeout",
        type=float,
        default=180,
        help="seconds to wait for a new container to be healthy",
    )
    parser.add_argument(
        "--drain",
        type=float,
        default=5,
        help="seconds between healthy and retiring the old container",
    )
    parser.add_argument(
        "--state",
        help="JSON file recording each service's resolved bind-mount sources (#458)",
    )
    parser.add_argument("--dry-run", action="store_true", help="print the handoff plan and exit")
    parser.add_argument("compose", nargs=argparse.REMAINDER, help="-- base compose command")
    args = parser.parse_args(argv)
    compose_cmd = args.compose[1:] if args.compose[:1] == ["--"] else args.compose
    if not compose_cmd:
        parser.error("missing the base compose command after --")

    stack = Stack(compose_cmd)
    mounts = mount_fingerprints(stack.specs()) if args.state else {}
    prev = load_state(args.state) if args.state else None
    if args.state and prev is None:
        log("no previous mount state: recording it (nothing forced this time)")
    forced = mounts_changed(prev, mounts)
    if forced:
        log(f"mounted config changed for: {', '.join(sorted(forced))}")
    todo = plan(stack, forced)
    handed = {svc for svc, _ in todo}
    # Mount-changed services that aren't handed off: compose's hash says "unchanged",
    # so `up -d` would leave them alone; recreate exactly these, in place.
    recreate = sorted(s for s in forced if s not in handed)
    if args.dry_run:
        for svc, old in todo:
            log(f"would hand off {svc} (old: {', '.join(c[:12] for c in old)})")
        for svc in recreate:
            log(f"would recreate {svc} in place (mounted config changed)")
        return 0

    failed = [svc for svc, old in todo if not _safe_handoff(stack, svc, old, args)]
    if failed:
        log(
            f"handoff failed for {', '.join(failed)}; NOT running `up -d` (it would recreate them in place)"
        )
        return 1  # state NOT saved: the next reload sees the same mount change again

    if recreate:
        subprocess.run(
            compose_cmd + ["up", "--detach", "--no-deps", "--force-recreate"] + recreate,
            check=True,
        )
    # Everything else that changed (restart-tier services, new/removed services). The
    # handed-off and force-recreated services now match their desired hash, so `up`
    # leaves them alone.
    subprocess.run(compose_cmd + ["up", "--detach", "--remove-orphans"], check=True)
    if args.state:
        save_state(args.state, mounts)
    return 0


if __name__ == "__main__":
    sys.exit(main())
