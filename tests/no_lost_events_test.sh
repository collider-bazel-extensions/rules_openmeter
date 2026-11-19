#!/usr/bin/env bash
# No acknowledged event is lost, starting the moment the stack is ready.
# The trampoline runs this as soon as the env file exists; the events go in
# one by one from then on (each acknowledged, 204), so if the sink worker
# isn't really consuming yet when the stack says ready (an offset still
# being resolved to "latest"), the first ones are skipped and the sum falls
# short. Then a burst as one batch, and a check against ClickHouse itself.
set -euo pipefail
source "$OPENMETER_TESTLIB"

n=0
for i in $(seq 1 20); do
  om_ingest --type prompt --subject race --id "race-$i" --data '{"tokens": 1, "model": "a"}'
  n=$((n + 1))
done
batch="["
for i in $(seq 1 50); do
  batch+="{\"specversion\": \"1.0\", \"id\": \"burst-$i\", \"source\": \"t\", \"type\": \"prompt\", \"subject\": \"race\", \"data\": {\"tokens\": 1}},"
done
om_ingest "${batch%,}]"
n=$((n + 50))
om_wait_value "$n" tokens_total --subject race
om_wait_value "$n" prompts --subject race

# Every acknowledged event is a row in ClickHouse's om_events.
set -a; source "$OPENMETER_CLICKHOUSE_ENV"; set +a
rows=$(python3 -I - <<'PY'
import os, urllib.parse, urllib.request
q = "SELECT count() FROM om_events WHERE subject = 'race'"
url = os.environ["CLICKHOUSE_HTTP_URL"] + "/?" + urllib.parse.urlencode({"database": os.environ["CLICKHOUSE_DATABASE"], "query": q})
print(urllib.request.urlopen(url, timeout=30).read().decode().strip())
PY
)
[[ "$rows" == "$n" ]] || { echo "FAIL: $rows rows in om_events for $n acknowledged events" >&2; exit 1; }
echo "ok: all $n acknowledged events are queryable and in om_events"
echo PASS
