#!/usr/bin/env python3
"""openmeter_stack launcher: one whole OpenMeter stack for one test.

  stack.py --name N --kafka K --clickhouse C --postgres P --openmeter O
           --kafka-name KN --clickhouse-name CN --postgres-name PN
           [--ready-timeout S]

Starts the four servers at once (each is its own launcher: rules_kafka's,
rules_clickhouse's, rules_pg's and openmeter_server's; the OpenMeter one
waits for the other three's env files), each in its own session with
PR_SET_PDEATHSIG=SIGKILL on Linux. Everything lives under $TEST_TMPDIR:

  $TEST_TMPDIR/<KN>/, <KN>.env           Kafka (rules_kafka)
  $TEST_TMPDIR/clickhouse-<CN>/, <CN>.env ClickHouse (rules_clickhouse)
  $TEST_TMPDIR/<PN>/                      Postgres (rules_pg), run with
                                          TEST_TMPDIR=$TEST_TMPDIR/<PN>: rules_pg
                                          keeps its data in $TEST_TMPDIR/pgdata
                                          whatever the server's name, so two
                                          stacks would share it otherwise
  $TEST_TMPDIR/<N>/, <N>.env              OpenMeter (the stack's env file)

The stack is ready when $TEST_TMPDIR/<N>.env exists (openmeter_server writes
it). If any server exits first, the others are stopped and the stack exits
1 naming it. On SIGTERM/SIGINT/SIGHUP: OpenMeter stops first, then the
backing services, and the stack exits 0.
"""

import argparse
import ctypes
import os
import signal
import subprocess
import sys
import time

_STOP_TIMEOUT = 60


def log(msg):
    print(f"[openmeter_stack] {msg}", file=sys.stderr, flush=True)


def _child_setup():
    os.setsid()
    if sys.platform.startswith("linux"):
        try:
            ctypes.CDLL(None, use_errno=True).prctl(1, signal.SIGKILL)  # PR_SET_PDEATHSIG
        except (OSError, AttributeError):
            pass


def spawn(cmd, env):
    return subprocess.Popen(cmd, env=env, stdin=subprocess.DEVNULL, preexec_fn=_child_setup)


def stop(procs, timeout=_STOP_TIMEOUT):
    """SIGTERM each launcher (it stops its server cleanly), then wait;
    SIGKILL the process group of any still running after `timeout`."""
    live = [p for p in procs if p is not None and p.poll() is None]
    for p in live:
        try:
            os.kill(p.pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
    deadline = time.monotonic() + timeout
    for p in live:
        try:
            p.wait(max(0.1, deadline - time.monotonic()))
        except subprocess.TimeoutExpired:
            log(f"pid {p.pid} still running after {timeout}s; SIGKILL")
            try:
                os.killpg(p.pid, signal.SIGKILL)
            except (ProcessLookupError, PermissionError):
                pass
            p.wait()


def main(argv):
    ap = argparse.ArgumentParser(prog="openmeter_stack")
    for f in ("name", "kafka", "clickhouse", "postgres", "openmeter",
              "kafka-name", "clickhouse-name", "postgres-name"):
        ap.add_argument("--" + f, required=True)
    ap.add_argument("--ready-timeout", type=float, default=600)
    a = ap.parse_args(argv)

    tmp = os.environ.get("TEST_TMPDIR")
    if not tmp:
        sys.exit("openmeter_stack: TEST_TMPDIR not set (run it under bazel test or rules_itest)")
    env_file = os.path.join(tmp, a.name + ".env")
    pg_tmp = os.path.join(tmp, a.postgres_name)
    os.makedirs(pg_tmp, exist_ok=True)
    pg_env = os.path.join(pg_tmp, a.postgres_name + ".env")
    for f in (env_file, pg_env):
        try:
            os.remove(f)
        except FileNotFoundError:
            pass

    stopping = []

    def on_signal(signum, _frame):
        stopping.append(signum)

    for s in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
        signal.signal(s, on_signal)

    base = dict(os.environ)
    t0 = time.monotonic()
    procs = {}
    procs["kafka"] = spawn([a.kafka], base)
    procs["clickhouse"] = spawn([a.clickhouse], base)
    procs["postgres"] = spawn([a.postgres], dict(base, TEST_TMPDIR=pg_tmp))
    procs["openmeter"] = spawn([
        a.openmeter,
        "--env-file", env_file,
        "--state-dir", os.path.join(tmp, a.name),
        "--kafka-env", os.path.join(tmp, a.kafka_name + ".env"),
        "--clickhouse-env", os.path.join(tmp, a.clickhouse_name + ".env"),
        "--postgres-env", pg_env,
    ], base)

    def shutdown(rc):
        stop([procs["openmeter"]])
        stop([procs["kafka"], procs["clickhouse"], procs["postgres"]])
        return rc

    deadline = t0 + a.ready_timeout
    ready = False
    while True:
        if stopping:
            return shutdown(0)
        for svc, p in procs.items():
            if p.poll() is not None:
                what = "before the stack was ready" if not ready else "while the stack was running"
                log(f"the {svc} server exited (status {p.returncode}) {what}; see its log lines above. Stopping the stack.")
                try:
                    os.remove(env_file)
                except FileNotFoundError:
                    pass
                return shutdown(1)
        if not ready:
            if os.path.isfile(env_file):
                ready = True
                log(f"stack {a.name} ready in {time.monotonic() - t0:.1f}s ({env_file})")
            elif time.monotonic() >= deadline:
                log(f"stack {a.name} not ready within {a.ready_timeout:.0f}s")
                return shutdown(1)
        time.sleep(0.1)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
