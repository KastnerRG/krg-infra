"""Trigger the LDAP sync schedule and wait for its persisted task status.

Executed by `ak shell`; avoid ldap_sync's non-blocking get_result() call.
"""

import os
import time


def wait_for_task(task_model, message_id, timeout=600, clock=time.monotonic, pause=time.sleep):
    deadline = clock() + timeout
    while clock() < deadline:
        task = task_model.objects.filter(message_id=message_id).first()
        if task and task.state == "done":
            if task.aggregated_status in {"error", "warning"}:
                raise RuntimeError("Authentik LDAP sync finished with errors or warnings")
            if task.tasklogs.filter(
                event__contains="Synchronization is already running. Skipping"
            ).exists():
                raise RuntimeError("Another LDAP sync is running; retry this request afterwards")
            print("Authentik LDAP sync task completed", flush=True)
            return
        if task and task.state == "rejected":
            raise RuntimeError("Authentik rejected the LDAP sync task")
        pause(2)
    raise TimeoutError("Timed out waiting for the Authentik LDAP sync task")


def main():
    from authentik.sources.ldap.models import LDAPSource
    from authentik.tasks.models import Task

    source = LDAPSource.objects.get(
        slug=os.environ.get("ROSTER_LDAP_SOURCE", "krg-samba-ad"), enabled=True
    )
    schedule = source.schedules.get(actor_name="authentik.sources.ldap.tasks.ldap_sync")
    message = schedule.send()
    print("Authentik LDAP sync task queued:", message.message_id, flush=True)
    wait_for_task(Task, message.message_id)


if __name__ == "__main__":
    main()
