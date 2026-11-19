#!/usr/bin/env bash
# Nothing is written outside $TEST_TMPDIR: an openmeter_stack runs from a
# read-only working directory with a read-only HOME and TMPDIR; the test
# ingests and queries (Kafka log segments, ClickHouse parts, Postgres rows,
# OpenMeter's logs), and afterwards no file outside $TEST_TMPDIR is newer
# than a marker. Also: OpenMeter's processes listen only on their own
# 127.0.0.1 ports, and SIGTERM stops the whole stack (every process gone,
# the env file removed, exit 0).
#
# Argv: <openmeter_stack (rootpath)> <listeners.py> <testlib.sh>
set -euo pipefail
fail() { echo "FAIL: $*" >&2; exit 1; }
STACK="$TEST_SRCDIR/_main/$1"
LISTENERS="$TEST_SRCDIR/_main/$2"
source "$TEST_SRCDIR/_main/$3"

ro="$TEST_TMPDIR/readonly"
mkdir -p "$ro"
marker="$TEST_TMPDIR/marker"
touch "$marker"
sleep 1   # mtime granularity
chmod 555 "$ro"

env_file="$TEST_TMPDIR/iso_stack.env"
(cd "$ro" && HOME="$ro" TMPDIR="$ro" exec "$STACK") &
pid=$!
trap 'kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true; chmod 755 "$ro"' EXIT
for _ in $(seq 1 6000); do [[ -f "$env_file" ]] && break; kill -0 "$pid" 2>/dev/null || fail "stack exited"; sleep 0.1; done
[[ -f "$env_file" ]] || fail "env file not written"
set -a; source "$env_file"; set +a

[[ "$OPENMETER_STATE_DIR" == "$TEST_TMPDIR/iso_stack" ]] || fail "state dir $OPENMETER_STATE_DIR"
[[ "$OPENMETER_CONFIG" == "$TEST_TMPDIR/iso_stack/config.yaml" ]] || fail "config $OPENMETER_CONFIG"
[[ "$OPENMETER_URL" == "http://127.0.0.1:$OPENMETER_PORT" ]] || fail "url $OPENMETER_URL"
[[ "$OPENMETER_INGEST_URL" == "$OPENMETER_URL/api/v1/events" ]] || fail "ingest url $OPENMETER_INGEST_URL"
[[ "$OPENMETER_NAMESPACE" == default && "$OPENMETER_EVENTS_TOPIC" == om_default_events ]] || fail "namespace"
echo "ok: env file contract"

(cd "$ro" && HOME="$ro" TMPDIR="$ro" om_ingest --type prompt --subject iso --data '{"tokens": 4, "model": "a"}')
(cd "$ro" && HOME="$ro" TMPDIR="$ro" om_wait_value 4 tokens_total --subject iso)
echo "ok: ingested and queried"

# OpenMeter's listeners: the API + telemetry ports (server), telemetry (sink).
srv=$(python3 -I "$LISTENERS" "$OPENMETER_SERVER_PID")
snk=$(python3 -I "$LISTENERS" "$OPENMETER_SINK_PID")
tel=${OPENMETER_TELEMETRY_URL##*:}; stel=${OPENMETER_SINK_TELEMETRY_URL##*:}
[[ "$(awk '{print $1}' <<<"$srv" | sort -n | paste -sd' ')" == "$(printf '%s\n' "$OPENMETER_PORT" "$tel" | sort -n | paste -sd' ')" ]] \
  || fail "server listeners: $srv"
[[ "$(awk '{print $1}' <<<"$snk")" == "$stel" ]] || fail "sink worker listeners: $snk"
if printf '%s\n%s\n' "$srv" "$snk" | awk '$3 != "0100007F"' | grep -q .; then fail "non-loopback listener: $srv $snk"; fi
echo "ok: the API server listens on 127.0.0.1:$OPENMETER_PORT and :$tel, the sink worker on :$stel"

kafka_pid="$(set -a; source "$OPENMETER_KAFKA_ENV"; echo "$KAFKA_PID")"
pids="$OPENMETER_SERVER_PID $OPENMETER_SINK_PID $kafka_pid"
kill -TERM "$pid"; wait "$pid" || fail "SIGTERM exit status $?"
trap 'chmod 755 "$ro"' EXIT
for p in $pids; do kill -0 "$p" 2>/dev/null && fail "pid $p still running after SIGTERM"; done
[[ ! -e "$env_file" ]] || fail "env file left behind"
# Processes (not this script or its ancestors: the sandbox's own
# command line names $TEST_TMPDIR) whose command line names the test's
# temp dir or an OpenMeter binary.
ancestors=" "; a=$$
while [[ -n "$a" && "$a" != 0 ]]; do ancestors+="$a "; a=$(awk '/^PPid:/{print $2}' /proc/$a/status 2>/dev/null); done
left=$(ls /proc | grep -E '^[0-9]+$' | while read -r p; do
  [[ "$ancestors" == *" $p "* ]] && continue
  c=$( { tr '\0' ' ' < /proc/$p/cmdline; } 2>/dev/null) || continue
  [[ -n "$c" && "$c" != *linux-sandbox* ]] || continue
  case "$c" in *"$TEST_TMPDIR"*|*usr/local/bin/openmeter*) echo "$p $c";; esac
done || true)
[[ -z "$left" ]] || fail "processes left after SIGTERM: $left"
echo "ok: SIGTERM stopped the stack (OpenMeter, Kafka, ClickHouse, Postgres); env file removed"

outside=()
for d in "$PWD" "$TEST_SRCDIR" /tmp /var/tmp /dev/shm; do
  [[ -d "$d" ]] || continue
  filter=(cat)
  # /var/tmp and /dev/shm are the host's, shared with every other process:
  # only names that could be this stack's count. Postgres's POSIX dynamic
  # shared memory segments (/dev/shm/PostgreSQL.<n>, rules_pg leaves
  # dynamic_shared_memory_type at its default) are excluded: they live only
  # while a server runs, and on a shared host other tests' can't be told
  # from this one's.
  [[ "$d" == /var/tmp || "$d" == /dev/shm ]] && filter=(grep -iE 'openmeter|kafka|clickhouse|postgres|pg_|hsperf')
  [[ "$d" == /dev/shm ]] && filter=(sh -c "grep -iE 'openmeter|kafka|clickhouse|postgres|pg_|hsperf' | grep -vE '^/dev/shm/PostgreSQL\.[0-9]+\$'")
  while IFS= read -r f; do outside+=("$f"); done < <(
    find "$d" -xdev \( -path "$TEST_TMPDIR" -o -path "$TEST_TMPDIR/*" \) -prune -o -newer "$marker" \
      ! -type d -print 2>/dev/null | "${filter[@]}" || true)
done
if (( ${#outside[@]} )); then printf '  %s\n' "${outside[@]}" >&2; fail "files written outside \$TEST_TMPDIR"; fi
echo "ok: no file outside \$TEST_TMPDIR is newer than the start"
echo PASS
