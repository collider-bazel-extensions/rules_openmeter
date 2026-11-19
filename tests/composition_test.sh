#!/usr/bin/env bash
# rules_itest composition with each service on its own: kafka_server,
# clickhouse_server and pg_server as itest_services, openmeter_server
# depending on them. The test reads every service's env file.
set -euo pipefail
set -a
source "$TEST_TMPDIR/om.env"
source "$TEST_TMPDIR/om_clickhouse.env"
set +a
source "$OPENMETER_TESTLIB_PATH"
[[ "$OPENMETER_KAFKA_ENV" == "$TEST_TMPDIR/om_kafka.env" ]]
[[ "$OPENMETER_NAMESPACE" == metering ]]
[[ "$OPENMETER_EVENTS_TOPIC" == om_metering_events ]]
[[ "$OPENMETER_SINK_FLUSH_INTERVAL" == 100ms ]]

om_ingest --type prompt --subject c --data '{"tokens": 9, "model": "x"}'
om_wait_value 9 tokens_total --subject c

# The event is in ClickHouse's events table, in the composition's database.
python3 -I - <<'PY'
import os, urllib.request, urllib.parse
q = "SELECT count() FROM om_events WHERE namespace = 'metering' AND subject = 'c'"
url = os.environ["CLICKHOUSE_HTTP_URL"] + "/?" + urllib.parse.urlencode({"database": os.environ["CLICKHOUSE_DATABASE"], "query": q})
n = urllib.request.urlopen(url, timeout=30).read().decode().strip()
assert n == "1", n
print("ok: 1 row in om_events in", os.environ["CLICKHOUSE_DATABASE"])
PY
echo PASS
