"""Unit tests for compose-reload's handoff planning and its fail-safe abort path.

The parts worth pinning down are the ones whose bugs are silent or costly: WHICH
services get handed off (a wrong plan either skips the graceful path or tries it on a
service that can't take it), and that a failed handoff never retires the old
container or runs the final `up -d` (either would turn "bad update" into "outage").

Stdlib + pytest only, matching .github/workflows/tests.yml (no Docker daemon needed).
"""

import importlib.util
import json
import pathlib

MODULE_PATH = pathlib.Path(__file__).with_name("compose-reload.py")
_spec = importlib.util.spec_from_file_location("compose_reload", MODULE_PATH)
cr = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(cr)
REAL_STACK = cr.Stack  # captured before any test monkeypatches it

HC = {"test": ["CMD", "true"]}
HANDOFF = {cr.ROLLOUT_LABEL: "handoff"}


class FakeDocker:
    """Just enough of `docker compose` + `docker` for compose-reload's calls.

    services: {name: spec}; desired: {name: hash}; containers: {id: {...}}.
    `new_health` is the health sequence a freshly scaled-up container reports, one
    entry per poll (the last entry repeats).
    """

    def __init__(self, services, desired, containers, new_health=("healthy",), new_state="running"):
        self.services = services
        self.desired = desired
        self.containers = containers
        self.new_health = list(new_health)
        self.new_state = new_state
        self.calls = []
        self._seq = 0

    def __call__(self, argv, stderr=False):
        self.calls.append(argv)
        if argv[:2] == ["docker", "compose"]:
            return self._compose(argv[2:])
        return self._docker(argv[1:])

    def _compose(self, args):
        while args and args[0] in ("--project-directory", "-f", "--env-file"):
            args = args[2:]  # the stack's base-command flags, not part of the subcommand
        if args[:3] == ["config", "--format", "json"]:
            return json.dumps({"services": self.services})
        if args[0] == "pull":
            self.pulled = True
            return ""
        if args[:2] == ["--dry-run", "up"]:
            assert getattr(self, "pulled", False), "dry run before pulling missing images"
            # compose's own decision: a running container whose config differs from the
            # desired one is reported `Recreate`; the rest `Running`.
            return "".join(
                f" Container {c} {'Recreate' if v['hash'] != self.desired[v['svc']] else 'Running'} \n"
                for c, v in self.containers.items()
                if v["state"] == "running"
            )
        if args[:4] == ["ps", "--all", "--format", "{{.Name}}\t{{.Service}}"]:
            return "".join(f"{c}\t{v['svc']}\n" for c, v in self.containers.items())
        if args[:2] == ["ps", "--quiet"]:
            svc = args[2]
            return "".join(
                f"{c}\n"
                for c, v in self.containers.items()
                if v["svc"] == svc and v["state"] == "running"
            )
        if args[:3] == ["ps", "--all", "--quiet"]:
            svc = args[3]
            return "".join(f"{c}\n" for c, v in self.containers.items() if v["svc"] == svc)
        if args[0] == "up" and "--scale" in args:
            svc, n = args[args.index("--scale") + 1].split("=")
            have = [c for c, v in self.containers.items() if v["svc"] == svc]
            for _ in range(int(n) - len(have)):
                self._seq += 1
                cid = f"new{self._seq}"
                self.containers[cid] = {
                    "svc": svc,
                    "hash": self.desired[svc],
                    "state": self.new_state,
                    "health": list(self.new_health),
                }
            return ""
        raise AssertionError(f"unexpected compose call: {args}")

    def _docker(self, args):
        if args[0] == "inspect":
            fmt, cid = args[2], args[3]
            c = self.containers[cid]
            if ".Config.Healthcheck" in fmt:
                return json.dumps(c.get("hc")) + "\n"
            health = c["health"].pop(0) if len(c["health"]) > 1 else c["health"][0]
            return f"{c['state']} {health}\n"
        if args[0] == "stop":
            for cid in args[1:]:
                self.containers[cid]["state"] = "exited"
            return ""
        if args[0] == "rm":
            for cid in args[1:]:
                del self.containers[cid]
            return ""
        if args[0] == "logs":
            return "boom\n"
        if args[0] == "exec" and args[2:] == ["touch", cr.DRAIN_FILE]:
            c = self.containers[args[1]]
            c["drained"] = True
            if cr.DRAIN_FILE in json.dumps(c.get("hc")):
                c["health"] = ["healthy", "unhealthy"]  # the next check fails
            return ""
        raise AssertionError(f"unexpected docker call: {args}")


def stack(fake):
    return cr.Stack(
        ["docker", "compose", "--project-directory", "/srv", "-f", "/nix/store/x/compose.yml"],
        runner=fake,
    )


def one(svc, spec, old_hash, new_hash, **kw):
    return FakeDocker(
        {svc: spec},
        {svc: new_hash},
        {"old1": {"svc": svc, "hash": old_hash, "state": "running", "health": ["healthy"]}},
        **kw,
    )


def no_sleep(_):
    pass


# ── planning ────────────────────────────────────────────────────────────────────


def test_changed_labelled_service_is_planned():
    fake = one("web", {"labels": HANDOFF, "healthcheck": HC}, "h1", "h2")
    assert cr.plan(stack(fake)) == [("web", ["old1"])]


def test_unchanged_service_is_not_planned():
    fake = one("web", {"labels": HANDOFF, "healthcheck": HC}, "h1", "h1")
    assert cr.plan(stack(fake)) == []


def test_unlabelled_service_is_left_to_up():
    fake = one("db", {"healthcheck": HC}, "h1", "h2")
    assert cr.plan(stack(fake)) == []


def test_not_running_service_is_left_to_up():
    fake = one("web", {"labels": HANDOFF, "healthcheck": HC}, "h1", "h2")
    fake.containers["old1"]["state"] = "exited"
    assert cr.plan(stack(fake)) == []


def test_ineligible_services_fall_back_to_in_place():
    for spec in (
        {"labels": HANDOFF, "healthcheck": HC, "container_name": "web"},
        {"labels": HANDOFF, "healthcheck": HC, "ports": [{"target": 80, "published": "80"}]},
        {"labels": HANDOFF},
        {"labels": HANDOFF, "healthcheck": {"disable": True}},
        {"labels": HANDOFF, "healthcheck": {"test": ["NONE"]}},
    ):
        fake = one("web", spec, "h1", "h2")
        assert cr.plan(stack(fake)) == [], spec


def test_interrupted_handoff_with_two_containers_is_not_planned():
    fake = one("web", {"labels": HANDOFF, "healthcheck": HC}, "h1", "h2")
    fake.containers["old2"] = {
        "svc": "web",
        "hash": "h1",
        "state": "running",
        "health": ["healthy"],
    }
    assert cr.plan(stack(fake)) == []


# ── handoff ─────────────────────────────────────────────────────────────────────


def test_successful_handoff_retires_only_the_old_container():
    fake = one(
        "web",
        {"labels": HANDOFF, "healthcheck": HC},
        "h1",
        "h2",
        new_health=("starting", "starting", "healthy"),
    )
    assert cr.handoff(stack(fake), "web", ["old1"], timeout=60, drain=0, sleep=no_sleep)
    assert list(fake.containers) == ["new1"]
    assert fake.containers["new1"]["state"] == "running"


def test_old_container_is_not_stopped_before_new_one_is_healthy():
    fake = one(
        "web",
        {"labels": HANDOFF, "healthcheck": HC},
        "h1",
        "h2",
        new_health=("starting", "healthy"),
    )
    cr.handoff(stack(fake), "web", ["old1"], timeout=60, drain=0, sleep=no_sleep)
    stop = next(i for i, c in enumerate(fake.calls) if c[1:3] == ["stop", "old1"])
    last_health_check = max(
        i for i, c in enumerate(fake.calls) if c[1] == "inspect" and c[-1] == "new1"
    )
    assert last_health_check < stop


def test_unhealthy_new_container_is_removed_and_old_keeps_serving():
    fake = one(
        "web",
        {"labels": HANDOFF, "healthcheck": HC},
        "h1",
        "h2",
        new_health=("starting", "unhealthy"),
    )
    assert not cr.handoff(stack(fake), "web", ["old1"], timeout=60, drain=0, sleep=no_sleep)
    assert list(fake.containers) == ["old1"]
    assert fake.containers["old1"]["state"] == "running"


def test_crashed_new_container_aborts():
    fake = one("web", {"labels": HANDOFF, "healthcheck": HC}, "h1", "h2", new_state="exited")
    assert not cr.handoff(stack(fake), "web", ["old1"], timeout=60, drain=0, sleep=no_sleep)
    assert fake.containers["old1"]["state"] == "running"
    assert "new1" not in fake.containers


def test_timeout_aborts():
    fake = one("web", {"labels": HANDOFF, "healthcheck": HC}, "h1", "h2", new_health=("starting",))
    ticks = iter(range(0, 1000, 10))
    ok = cr.handoff(
        stack(fake), "web", ["old1"], timeout=30, drain=0, sleep=no_sleep, clock=lambda: next(ticks)
    )
    assert not ok
    assert list(fake.containers) == ["old1"]


def test_failed_handoff_skips_final_up(monkeypatch):
    fake = one("web", {"labels": HANDOFF, "healthcheck": HC}, "h1", "h2", new_health=("unhealthy",))
    orig = cr.Stack
    monkeypatch.setattr(cr, "Stack", lambda cmd: orig(cmd, runner=fake))
    monkeypatch.setattr(cr.time, "sleep", no_sleep)
    final_up = []
    monkeypatch.setattr(cr.subprocess, "run", lambda *a, **k: final_up.append(a))
    rc = cr.main(["--drain", "0", "--", "docker", "compose", "-f", "c.yml"])
    assert rc == 1
    assert final_up == []
    assert fake.containers["old1"]["state"] == "running"


def test_success_runs_final_up(monkeypatch):
    fake = one("web", {"labels": HANDOFF, "healthcheck": HC}, "h1", "h2")
    orig = cr.Stack
    monkeypatch.setattr(cr, "Stack", lambda cmd: orig(cmd, runner=fake))
    monkeypatch.setattr(cr.time, "sleep", no_sleep)
    final_up = []
    monkeypatch.setattr(cr.subprocess, "run", lambda argv, **k: final_up.append(argv))
    rc = cr.main(["--drain", "0", "--", "docker", "compose", "-f", "c.yml"])
    assert rc == 0
    assert final_up == [["docker", "compose", "-f", "c.yml", "up", "--detach", "--remove-orphans"]]


# ── draining ────────────────────────────────────────────────────────────────────

DRAIN_HC = {
    "Test": ["CMD-SHELL", f"test ! -f {cr.DRAIN_FILE} && wget -q -O /dev/null http://127.0.0.1/"]
}


def test_old_container_is_drained_before_it_is_stopped():
    fake = one("web", {"labels": HANDOFF, "healthcheck": HC}, "h1", "h2")
    fake.containers["old1"]["hc"] = DRAIN_HC
    assert cr.handoff(stack(fake), "web", ["old1"], timeout=60, drain=0, sleep=no_sleep)
    touch = next(i for i, c in enumerate(fake.calls) if c[1:3] == ["exec", "old1"])
    stop = next(i for i, c in enumerate(fake.calls) if c[1:3] == ["stop", "old1"])
    went_unhealthy = [
        i
        for i, c in enumerate(fake.calls)
        if c[1] == "inspect" and c[-1] == "old1" and ".State" in c[3] and i > touch
    ]
    assert touch < stop
    assert went_unhealthy and max(went_unhealthy) < stop


def test_healthcheck_without_the_drain_file_is_not_drained():
    fake = one("web", {"labels": HANDOFF, "healthcheck": HC}, "h1", "h2")
    fake.containers["old1"]["hc"] = {"Test": ["CMD", "true"]}
    assert cr.handoff(stack(fake), "web", ["old1"], timeout=60, drain=0, sleep=no_sleep)
    assert not any(c[1] == "exec" for c in fake.calls)


def test_drain_that_never_goes_unhealthy_still_completes():
    fake = one("web", {"labels": HANDOFF, "healthcheck": HC}, "h1", "h2")
    fake.containers["old1"]["hc"] = DRAIN_HC
    # The container claims to honour the drain file but its health never changes.
    orig_docker = fake._docker

    def sticky(args):
        out = orig_docker(args)
        if args[0] == "exec":
            fake.containers[args[1]]["health"] = ["healthy"]
        return out

    fake._docker = sticky
    ticks = iter(range(0, 10000, 10))
    assert cr.handoff(
        stack(fake), "web", ["old1"], timeout=30, drain=0, sleep=no_sleep, clock=lambda: next(ticks)
    )
    assert list(fake.containers) == ["new1"]


# ── robustness (found by the NixOS VM test: an image without /tmp) ──────────────


def test_drain_exec_failure_does_not_abort_the_handoff():
    fake = one("web", {"labels": HANDOFF, "healthcheck": HC}, "h1", "h2")
    fake.containers["old1"]["hc"] = DRAIN_HC
    orig = fake._docker

    def no_tmp(args):
        if args[0] == "exec":
            raise cr.subprocess.CalledProcessError(1, ["docker"] + args)
        return orig(args)

    fake._docker = no_tmp
    assert cr.handoff(stack(fake), "web", ["old1"], timeout=60, drain=0, sleep=no_sleep)
    assert list(fake.containers) == ["new1"]


class Args:
    timeout = 60
    drain = 0


def test_unexpected_error_leaves_old_serving_and_removes_new(monkeypatch):
    fake = one("web", {"labels": HANDOFF, "healthcheck": HC}, "h1", "h2")
    orig = fake._docker

    def stop_old_fails(args):
        if args[:2] == ["stop", "old1"]:
            raise RuntimeError("daemon hiccup")
        return orig(args)

    fake._docker = stop_old_fails
    monkeypatch.setattr(cr.time, "sleep", no_sleep)
    assert cr._safe_handoff(stack(fake), "web", ["old1"], Args) is False
    assert list(fake.containers) == ["old1"]
    assert fake.containers["old1"]["state"] == "running"


# ── bind-mounted config (#458): resolved mount sources as the change signal ─────


def bind(src, target="/etc/app"):
    return {"type": "bind", "source": str(src), "target": target}


def retarget(link, dest):
    if link.is_symlink() or link.exists():
        link.unlink()
    link.symlink_to(dest)


def test_fingerprint_resolves_symlinks_and_ignores_volumes(tmp_path):
    store = tmp_path / "store-aaa-grafana"
    store.mkdir()
    link = tmp_path / "grafana"
    link.symlink_to(store)
    specs = {
        "grafana": {
            "volumes": [bind(link), {"type": "volume", "source": "grafana-data", "target": "/var"}]
        },
        "db": {"volumes": [bind(tmp_path / "data")]},  # a plain dir: resolves to itself
        "bare": {},
    }
    fp = cr.mount_fingerprints(specs)
    assert fp["grafana"] == [str(store)]
    assert fp["db"] == [str(tmp_path / "data")]
    assert fp["bare"] == []


def test_mounts_changed():
    assert cr.mounts_changed(None, {"a": ["/x"]}) == set()  # first run: record, don't force
    prev = {"a": ["/s/1"], "b": ["/d"]}
    cur = {"a": ["/s/2"], "b": ["/d"], "new": ["/s/9"]}
    assert cr.mounts_changed(prev, cur) == {"a"}  # new services are just started by `up`


def mount_stack(tmp_path, label=None):
    """A restart-tier `cfg` service mounting a symlinked config dir, plus `web`."""
    s1, s2 = tmp_path / "store-1", tmp_path / "store-2"
    s1.mkdir()
    s2.mkdir()
    link = tmp_path / "cfg"
    retarget(link, s1)
    spec = {"volumes": [bind(link)], "healthcheck": HC}
    if label:
        spec["labels"] = label
    fake = FakeDocker(
        {"cfg": spec, "web": {"labels": HANDOFF, "healthcheck": HC}},
        {"cfg": "c1", "web": "w1"},
        {
            "oldc": {"svc": "cfg", "hash": "c1", "state": "running", "health": ["healthy"]},
            "oldw": {"svc": "web", "hash": "w1", "state": "running", "health": ["healthy"]},
        },
    )
    return fake, link, s2


def run_main(monkeypatch, fake, state):
    orig = REAL_STACK
    monkeypatch.setattr(cr, "Stack", lambda cmd: orig(cmd, runner=fake))
    monkeypatch.setattr(cr.time, "sleep", no_sleep)
    calls = []
    monkeypatch.setattr(cr.subprocess, "run", lambda argv, **k: calls.append(argv))
    rc = cr.main(["--drain", "0", "--state", str(state), "--", "docker", "compose"])
    return rc, calls


def test_first_run_records_state_and_forces_nothing(tmp_path, monkeypatch):
    fake, _, _ = mount_stack(tmp_path)
    state = tmp_path / "state.json"
    rc, calls = run_main(monkeypatch, fake, state)
    assert rc == 0
    assert calls == [["docker", "compose", "up", "--detach", "--remove-orphans"]]
    assert json.loads(state.read_text())["mounts"]["cfg"] == [str(tmp_path / "store-1")]


def test_config_only_change_recreates_just_that_service(tmp_path, monkeypatch):
    fake, link, s2 = mount_stack(tmp_path)
    state = tmp_path / "state.json"
    run_main(monkeypatch, fake, state)  # record
    retarget(link, s2)  # a deploy moved the L+ symlink: compose's hash can't see it
    rc, calls = run_main(monkeypatch, fake, state)
    assert rc == 0
    assert calls == [
        ["docker", "compose", "up", "--detach", "--no-deps", "--force-recreate", "cfg"],
        ["docker", "compose", "up", "--detach", "--remove-orphans"],
    ]
    assert json.loads(state.read_text())["mounts"]["cfg"] == [str(s2)]
    rc, calls = run_main(monkeypatch, fake, state)  # nothing moved since: no recreate
    assert calls == [["docker", "compose", "up", "--detach", "--remove-orphans"]]


def test_config_only_change_on_a_handoff_service_hands_off(tmp_path, monkeypatch):
    fake, link, s2 = mount_stack(tmp_path, label=HANDOFF)
    state = tmp_path / "state.json"
    run_main(monkeypatch, fake, state)
    retarget(link, s2)
    rc, calls = run_main(monkeypatch, fake, state)
    assert rc == 0
    assert "oldc" not in fake.containers  # handed off (compose hash unchanged)
    assert any(c["svc"] == "cfg" and c["state"] == "running" for c in fake.containers.values())
    assert not any("--force-recreate" in c for c in calls)  # not ALSO recreated in place


def test_failed_handoff_keeps_old_state_so_the_change_is_retried(tmp_path, monkeypatch):
    fake, link, s2 = mount_stack(tmp_path, label=HANDOFF)
    state = tmp_path / "state.json"
    run_main(monkeypatch, fake, state)
    retarget(link, s2)
    fake.new_health = ["unhealthy"]
    rc, _ = run_main(monkeypatch, fake, state)
    assert rc == 1
    assert json.loads(state.read_text())["mounts"]["cfg"] == [str(tmp_path / "store-1")]


# ── content fingerprints for store-path mounts (found on the first production run:
#    every L+ link points into ONE store path, so path identity recreated everything) ──


def fake_store(tmp_path, monkeypatch):
    store = tmp_path / "store"
    store.mkdir()
    monkeypatch.setattr(cr, "STORE", str(store) + "/")
    return store


def config_dir(store, name, files):
    d = store / name
    d.mkdir(parents=True)
    for rel, body in files.items():
        (d / rel).parent.mkdir(parents=True, exist_ok=True)
        (d / rel).write_text(body)
    return d


def test_store_mount_is_fingerprinted_by_content(tmp_path, monkeypatch):
    store = fake_store(tmp_path, monkeypatch)
    a = config_dir(store, "aaa-krg-prod/grafana", {"grafana.ini": "x=1", "dash/d.json": "{}"})
    b = config_dir(store, "bbb-krg-prod/grafana", {"grafana.ini": "x=1", "dash/d.json": "{}"})
    c = config_dir(store, "ccc-krg-prod/grafana", {"grafana.ini": "x=2", "dash/d.json": "{}"})
    fp = lambda d: cr.mount_fingerprints({"g": {"volumes": [bind(d)]}})["g"]  # noqa: E731
    assert fp(a) == fp(b)  # different store path, same content: unchanged
    assert fp(a) != fp(c)  # content changed
    assert fp(a)[0].startswith("sha256:")


def test_single_store_file_mount(tmp_path, monkeypatch):
    store = fake_store(tmp_path, monkeypatch)
    f1 = config_dir(store, "aaa-krg-prod/loki", {"loki-config.yaml": "a"}) / "loki-config.yaml"
    f2 = config_dir(store, "bbb-krg-prod/loki", {"loki-config.yaml": "a"}) / "loki-config.yaml"
    fps = [cr.mount_fingerprints({"l": {"volumes": [bind(f)]}})["l"] for f in (f1, f2)]
    assert fps[0] == fps[1]


def test_unrelated_compose_dir_change_recreates_nothing(tmp_path, monkeypatch):
    """The production case: a new compose-dir store path, this service's config identical."""
    store = fake_store(tmp_path, monkeypatch)
    s1 = config_dir(store, "aaa-krg-prod/cfg", {"app.conf": "same"})
    s2 = config_dir(store, "bbb-krg-prod/cfg", {"app.conf": "same"})
    s3 = config_dir(store, "ccc-krg-prod/cfg", {"app.conf": "changed"})
    fake, link, _ = mount_stack(tmp_path)
    retarget(link, s1)
    state = tmp_path / "state.json"
    run_main(monkeypatch, fake, state)  # record
    retarget(link, s2)  # deploy moved every L+ link; this config is byte-identical
    _, calls = run_main(monkeypatch, fake, state)
    assert calls == [["docker", "compose", "up", "--detach", "--remove-orphans"]]
    retarget(link, s3)  # this service's config really changed
    _, calls = run_main(monkeypatch, fake, state)
    assert calls[0] == [
        "docker",
        "compose",
        "up",
        "--detach",
        "--no-deps",
        "--force-recreate",
        "cfg",
    ]


def test_older_state_format_only_records(tmp_path, monkeypatch):
    """Upgrading from version-1 state (paths) must not read as 'everything changed'."""
    fake, link, s2 = mount_stack(tmp_path)
    state = tmp_path / "state.json"
    state.write_text(json.dumps({"mounts": {"cfg": ["/nix/store/old-path/cfg"], "web": []}}))
    rc, calls = run_main(monkeypatch, fake, state)
    assert rc == 0
    assert calls == [["docker", "compose", "up", "--detach", "--remove-orphans"]]
    assert json.loads(state.read_text())["version"] == cr.STATE_VERSION


# ── change detection = compose's own dry run (found in production: `config --hash`
#    disagrees with the label `up` stamps for env_file services → nightly re-handoffs) ──


def test_changed_services_parses_compose_dry_run():
    out = (
        " Container krg-prod-outline-3 Running \n"
        " Container krg-prod-fleet-3 Recreate \n"
        " Container krg-prod-fleet-3 Recreated \n"
        " Container postgres_authentik Recreate \n"
    )
    ps = "krg-prod-outline-3\toutline\nkrg-prod-fleet-3\tfleet\npostgres_authentik\tpostgres_authentik\n"

    def runner(argv, stderr=False):
        if "pull" in argv:
            return ""
        if "--dry-run" in argv:
            assert stderr, "dry-run results are on stderr; they must be captured"
            return out
        if "--format" in argv:
            return ps
        raise AssertionError(argv)

    st = cr.Stack(["docker", "compose"], runner=runner)
    assert st.changed_services() == {"fleet", "postgres_authentik"}


def test_nothing_to_recreate_skips_the_ps_call():
    calls = []

    def runner(argv, stderr=False):
        calls.append(argv)
        return " Container a-1 Running \n"

    assert cr.Stack(["docker", "compose"], runner=runner).changed_services() == set()
    assert [c[2] for c in calls] == ["pull", "--dry-run"]  # pull, dry run, and no ps


def test_missing_images_are_pulled_before_the_dry_run():
    """Production: a newly pinned digest wasn't on the host, so `--dry-run up` failed with
    'No such image' and crashed the reload. Pull (missing only, skip buildable) first."""
    calls = []

    def runner(argv, stderr=False):
        calls.append(argv[2:])
        return ""

    cr.Stack(["docker", "compose"], runner=runner).changed_services()
    assert calls[0] == ["pull", "--quiet", "--policy", "missing", "--ignore-buildable"]
    assert calls[1][:2] == ["--dry-run", "up"]
