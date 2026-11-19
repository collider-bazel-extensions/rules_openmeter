#!/usr/bin/env bash
# End to end: CloudEvents for two subjects in two hourly windows, through
# the ingest API, Kafka, the sink worker and ClickHouse, queried per
# subject and per window (SUM over $.tokens and COUNT).
set -euo pipefail
source "$OPENMETER_TESTLIB"

# Two whole hours, ending at least an hour ago.
h0=$(( ($(date -u +%s) / 3600 - 3) * 3600 ))
h1=$(( h0 + 3600 ))
h2=$(( h1 + 3600 ))
t() { date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ; }
from="$(t $h0)"; mid="$(t $h1)"; to="$(t $h2)"

start=$(date +%s.%N)
# One single event, then a batch.
om_ingest --type prompt --subject alice --time "$(t $((h0 + 60)))" --data '{"tokens": 10, "model": "a"}'
om_ingest "[
  {\"specversion\": \"1.0\", \"id\": \"e2\", \"source\": \"test\", \"type\": \"prompt\", \"subject\": \"alice\", \"time\": \"$(t $((h0 + 120)))\", \"data\": {\"tokens\": 5, \"model\": \"b\"}},
  {\"specversion\": \"1.0\", \"id\": \"e3\", \"source\": \"test\", \"type\": \"prompt\", \"subject\": \"alice\", \"time\": \"$(t $((h1 + 60)))\", \"data\": {\"tokens\": 7, \"model\": \"a\"}},
  {\"specversion\": \"1.0\", \"id\": \"e4\", \"source\": \"test\", \"type\": \"prompt\", \"subject\": \"bob\",   \"time\": \"$(t $((h0 + 300)))\", \"data\": {\"tokens\": 100, \"model\": \"a\"}},
  {\"specversion\": \"1.0\", \"id\": \"e5\", \"source\": \"test\", \"type\": \"other\",  \"subject\": \"bob\",   \"time\": \"$(t $((h0 + 300)))\", \"data\": {\"tokens\": 1000}}
]"

# Ingest -> queryable: the last event of the batch to arrive decides.
om_wait_value 122 tokens_total --from "$from" --to "$to"
end=$(date +%s.%N)
echo "ingest -> queryable: $(python3 -c "print(f'{$end - $start:.2f}')")s (sink_flush_interval $OPENMETER_SINK_FLUSH_INTERVAL)"

# Per subject.
[[ "$(om_query tokens_total --from "$from" --to "$to" --subject alice)" == 22 ]]
[[ "$(om_query tokens_total --from "$from" --to "$to" --subject bob)" == 100 ]]
[[ "$(om_query prompts --from "$from" --to "$to" --subject alice)" == 3 ]]
[[ "$(om_query prompts --from "$from" --to "$to" --subject bob)" == 1 ]]   # the `other` event isn't a prompt

# Per window (hourly), all subjects, then one subject.
[[ "$(om_query tokens_total --from "$from" --to "$to" --window-size HOUR | paste -sd' ')" == "115 7" ]]
[[ "$(om_query prompts --from "$from" --to "$to" --window-size HOUR --subject alice | paste -sd' ')" == "2 1" ]]

# Per window and subject, as TSV rows.
got="$(om_query tokens_total --from "$from" --to "$to" --window-size HOUR --group-by subject --tsv | cut -f1,3,5)"
want="$(printf '%s\t%s\t%s\n' "$from" alice 15 "$from" bob 100 "$mid" alice 7)"
[[ "$got" == "$want" ]] || { echo "per window and subject: got"; echo "$got"; echo "want"; echo "$want"; exit 1; } >&2

# Grouped by a meter's groupBy key.
[[ "$(om_query tokens_total --from "$from" --to "$to" --filter-group-by model=a)" == 117 ]]

# A window with nothing in it.
[[ "$(om_query tokens_total --from "$to" --to "$(t $((h2 + 3600)))" --window-size HOUR)" == "" ]]

# A meter created through the API works the same way.
om_api POST /api/v1/meters '{"slug": "api_calls", "eventType": "api_call", "aggregation": "COUNT"}' >/dev/null
om_ingest --type api_call --subject carol
om_ingest --type api_call --subject carol
om_wait_value 2 api_calls --subject carol

# Meters from the meters file are there, and an unknown one is a 404.
om_api GET /api/v1/meters/tokens_total >/dev/null
[[ "$(om_status GET /api/v1/meters/nope/query)" == 404 ]]
echo PASS
