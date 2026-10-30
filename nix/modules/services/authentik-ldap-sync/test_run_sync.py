"""Completion must reflect the dispatched task, not a missing Dramatiq result."""

import pathlib
import runpy
import unittest
from types import SimpleNamespace

wait_for_task = runpy.run_path(str(pathlib.Path(__file__).with_name("run-sync.py")))[
    "wait_for_task"
]


def model(states, skip=False):
    states = iter(states)

    def first():
        state, status = next(states)
        return SimpleNamespace(
            state=state,
            aggregated_status=status,
            tasklogs=SimpleNamespace(filter=lambda **_: SimpleNamespace(exists=lambda: skip)),
        )

    def query(**kwargs):
        assert kwargs == {"message_id": "test-message"}
        return SimpleNamespace(first=first)

    return SimpleNamespace(objects=SimpleNamespace(filter=query))


def test_waits_for_the_specific_queued_task_to_finish():
    pauses = []
    wait_for_task(
        model([("queued", "queued"), ("running", "running"), ("done", "info")]),
        "test-message",
        clock=lambda: 0,
        pause=pauses.append,
    )
    assert pauses == [2, 2]


def test_task_errors_and_warnings_cannot_report_success():
    for status in ("error", "warning"):
        with unittest.TestCase().assertRaises(RuntimeError):
            wait_for_task(model([("done", status)]), "test-message", clock=lambda: 0)


def test_overlap_is_retried_instead_of_dropping_the_directory_change():
    with unittest.TestCase().assertRaisesRegex(RuntimeError, "Another LDAP sync"):
        wait_for_task(model([("done", "info")], skip=True), "test-message", clock=lambda: 0)


def test_rejected_task_preserves_the_request_for_retry():
    with unittest.TestCase().assertRaisesRegex(RuntimeError, "rejected"):
        wait_for_task(model([("rejected", "rejected")]), "test-message", clock=lambda: 0)


def test_wait_is_bounded_when_the_worker_does_not_complete():
    times = iter([0, 0, 601])
    with unittest.TestCase().assertRaises(TimeoutError):
        wait_for_task(
            model([("running", "running")]),
            "test-message",
            clock=lambda: next(times),
            pause=lambda _: None,
        )
