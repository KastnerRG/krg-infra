"""Scheduled worker for Outline group reconciliation (mTLS required)."""

import argparse
import asyncio
import logging
import os
import signal
from collections import Counter
from concurrent.futures import ThreadPoolExecutor
from datetime import timedelta
from pathlib import Path

from temporalio import activity
from temporalio.client import (
    Client,
    Schedule,
    ScheduleActionStartWorkflow,
    ScheduleAlreadyRunningError,
    ScheduleIntervalSpec,
    ScheduleOverlapPolicy,
    SchedulePolicy,
    ScheduleSpec,
)
from temporalio.service import TLSConfig
from temporalio.worker import Worker

from sync import from_env
from workflow import OutlineGroupSync

TASK_QUEUE = "outline-group-sync"
SCHEDULE_ID = "outline-group-sync"


@activity.defn
def reconcile_outline_groups() -> dict:
    apply = os.environ.get("SYNC_APPLY", "false").lower()
    if apply not in ("true", "false"):
        raise ValueError("SYNC_APPLY must be true or false")
    result = from_env(apply=apply == "true", progress=activity.heartbeat)
    summary = {
        "apply": result["apply"],
        "changes": dict(Counter(op["method"] for op in result["operations"])),
    }
    activity.logger.info("Outline group reconciliation: %s", summary)
    return summary


def schedule():
    return Schedule(
        action=ScheduleActionStartWorkflow(
            OutlineGroupSync.run,
            id="outline-group-sync",
            task_queue=TASK_QUEUE,
            execution_timeout=timedelta(minutes=35),
        ),
        spec=ScheduleSpec(intervals=[ScheduleIntervalSpec(every=timedelta(minutes=5))]),
        policy=SchedulePolicy(overlap=ScheduleOverlapPolicy.SKIP),
    )


async def connect():
    cert = Path(os.environ["TEMPORAL_TLS_CERT"]).read_bytes()
    return await Client.connect(
        os.environ.get("TEMPORAL_ADDRESS", "workflows.krg.ucsd.edu:7233"),
        namespace=os.environ.get("TEMPORAL_NAMESPACE", "default"),
        tls=TLSConfig(
            server_root_ca_cert=Path(os.environ["TEMPORAL_TLS_CA"]).read_bytes(),
            domain=os.environ.get("TEMPORAL_TLS_SERVER_NAME", "workflows.krg.ucsd.edu"),
            client_cert=cert,
            client_private_key=Path(
                os.environ.get("TEMPORAL_TLS_KEY", os.environ["TEMPORAL_TLS_CERT"])
            ).read_bytes(),
        ),
    )


async def main(command):
    client = await connect()
    if command == "schedule":
        try:
            await client.create_schedule(SCHEDULE_ID, schedule())
            logging.info("Created five-minute Outline group sync schedule")
        except ScheduleAlreadyRunningError:
            logging.info("Schedule already exists; preserving its settings and paused state")
        return
    with ThreadPoolExecutor(max_workers=1) as executor:
        stop = asyncio.Event()
        loop = asyncio.get_running_loop()
        for sig in (signal.SIGTERM, signal.SIGINT):
            loop.add_signal_handler(sig, stop.set)
        async with Worker(
            client,
            task_queue=TASK_QUEUE,
            workflows=[OutlineGroupSync],
            activities=[reconcile_outline_groups],
            activity_executor=executor,
            max_concurrent_activities=1,
            graceful_shutdown_timeout=timedelta(seconds=45),
        ):
            await stop.wait()


if __name__ == "__main__":
    logging.basicConfig(level=logging.INFO)
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("worker", "schedule"), default="worker", nargs="?")
    asyncio.run(main(parser.parse_args().command))
