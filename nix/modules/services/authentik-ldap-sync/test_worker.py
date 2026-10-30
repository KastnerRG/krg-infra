"""Exercise queue handling around the real worker with a fake sync command."""
import pathlib
import subprocess

WORKER = pathlib.Path(__file__).with_name("worker.sh")


def run_worker(queue, processing, *command):
    return subprocess.run(["bash", str(WORKER), str(queue), str(processing), *command], check=False)


def test_pending_is_consumed_without_interpreting_its_contents(tmp_path):
    queue = tmp_path / "requests"
    queue.mkdir()
    marker = queue / "pending"
    marker.write_text("$(touch '" + str(tmp_path / "should-never-execute") + "')")
    processing = tmp_path / "processing"
    assert run_worker(queue, processing, "true").returncode == 0
    assert not marker.exists()
    assert not processing.exists()
    assert not (tmp_path / "should-never-execute").exists()


def test_change_during_sync_queues_another_pass(tmp_path):
    queue = tmp_path / "requests"
    queue.mkdir()
    marker = queue / "pending"
    marker.touch()
    processing = tmp_path / "processing"
    # The sync command represents a directory change made while syncing.
    assert run_worker(queue, processing, "touch", str(marker)).returncode == 0
    assert marker.exists()
    assert not processing.exists()
    assert run_worker(queue, processing, "true").returncode == 0
    assert not marker.exists()


def test_failure_preserves_work_and_retry_also_preserves_new_requests(tmp_path):
    queue = tmp_path / "requests"
    queue.mkdir()
    marker = queue / "pending"
    marker.touch()
    processing = tmp_path / "processing"
    assert run_worker(queue, processing, "false").returncode != 0
    assert processing.exists()
    marker.touch()  # An additional edit arrives before the failed sync retries.
    assert run_worker(queue, processing, "true").returncode == 0
    assert not processing.exists()
    assert marker.exists()
    assert run_worker(queue, processing, "true").returncode == 0
    assert not marker.exists()


def test_without_a_request_no_sync_is_started(tmp_path):
    queue = tmp_path / "requests"
    queue.mkdir()
    assert run_worker(queue, tmp_path / "processing", "false").returncode == 0


def test_request_symlink_is_removed_without_touching_its_target(tmp_path):
    queue = tmp_path / "requests"
    queue.mkdir()
    target = tmp_path / "target"
    target.write_text("unchanged")
    marker = queue / "pending"
    marker.symlink_to(target)
    assert run_worker(queue, tmp_path / "processing", "true").returncode == 0
    assert target.read_text() == "unchanged"
    assert not marker.is_symlink()
