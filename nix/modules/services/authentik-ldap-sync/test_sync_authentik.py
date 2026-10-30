"""Validate worker discovery against Compose labels rather than container names."""

import os
import pathlib
import subprocess

SYNC = pathlib.Path(__file__).with_name("sync-authentik.sh")


def invoke(tmp_path, containers, ps_status="0", exec_status="0"):
    docker = tmp_path / "docker"
    calls = tmp_path / "calls"
    docker.write_text(
        "#!/usr/bin/env bash\n"
        'printf "%s\\n" "$*" >> "$CALLS"\n'
        'if [[ "$3" == ps ]]; then\n'
        '  printf "%s" "$CONTAINERS"\n'
        '  exit "$PS_STATUS"\n'
        "fi\n"
        'exit "$EXEC_STATUS"\n'
    )
    docker.chmod(0o755)
    result = subprocess.run(
        ["bash", str(SYNC)],
        env={
            **os.environ,
            "PATH": str(tmp_path) + os.pathsep + os.environ["PATH"],
            "CALLS": str(calls),
            "CONTAINERS": containers,
            "PS_STATUS": ps_status,
            "EXEC_STATUS": exec_status,
        },
        check=False,
        capture_output=True,
        text=True,
    )
    return result, calls.read_text().splitlines()


def test_finds_worker_by_project_and_service_labels(tmp_path):
    result, calls = invoke(tmp_path, "abcdef123456\n")
    assert result.returncode == 0
    assert "label=com.docker.compose.project=krg-prod" in calls[0]
    assert "label=com.docker.compose.service=authentik_worker" in calls[0]
    assert (
        calls[1] == "--host unix:///var/run/docker.sock exec abcdef123456 ak ldap_sync krg-samba-ad"
    )


def test_no_running_worker_is_retriable(tmp_path):
    result, calls = invoke(tmp_path, "")
    assert result.returncode != 0
    assert len(calls) == 1


def test_multiple_workers_are_rejected(tmp_path):
    result, calls = invoke(tmp_path, "abcdef123456\n123456abcdef\n")
    assert result.returncode != 0
    assert len(calls) == 1


def test_discovery_failure_cannot_start_a_sync(tmp_path):
    result, calls = invoke(tmp_path, "abcdef123456\n", ps_status="1")
    assert result.returncode != 0
    assert len(calls) == 1


def test_sync_failure_propagates_to_queue_retry(tmp_path):
    result, calls = invoke(tmp_path, "abcdef123456\n", exec_status="1")
    assert result.returncode != 0
    assert len(calls) == 2
