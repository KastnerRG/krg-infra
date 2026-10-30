"""Deterministic workflow; HTTP and credentials stay in the worker activity."""

from datetime import timedelta

from temporalio import workflow
from temporalio.common import RetryPolicy


@workflow.defn
class OutlineGroupSync:
    @workflow.run
    async def run(self) -> dict:
        return await workflow.execute_activity(
            "reconcile_outline_groups",
            start_to_close_timeout=timedelta(minutes=20),
            schedule_to_close_timeout=timedelta(minutes=30),
            heartbeat_timeout=timedelta(minutes=2),
            retry_policy=RetryPolicy(
                initial_interval=timedelta(seconds=30),
                maximum_interval=timedelta(minutes=2),
                maximum_attempts=8,
            ),
        )
