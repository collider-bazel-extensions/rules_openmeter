#!/usr/bin/env bash
# Helpers for openmeter_test scripts:  source "$OPENMETER_TESTLIB"
# (or source it in any test that has the OPENMETER_* variables).
#
#   om_ingest JSON | -               send a CloudEvent (a JSON object) or a
#                                    batch (a JSON array) to the ingest
#                                    endpoint; `-` or no argument: stdin
#   om_ingest --type T --subject S [--id ID] [--time RFC3339] [--source SRC] [--data JSON]
#                                    build the CloudEvent (specversion 1.0,
#                                    random id, source rules_openmeter)
#                                    Both fail unless OpenMeter answers 2xx;
#                                    add --status to print the status instead.
#   om_query METER [--subject S]... [--from T] [--to T] [--window-size W]
#            [--window-time-zone TZ] [--group-by KEY]... [--filter-group-by K=V]...
#            [--json | --tsv]
#                                    GET /api/v1/meters/METER/query; prints
#                                    one value per row (rows sorted by
#                                    window, subject, group), or TSV rows
#                                    (windowStart windowEnd subject groupBy
#                                    value), or the raw JSON
#   om_wait_value EXPECTED METER [om_query options...]
#                                    poll om_query until it prints EXPECTED
#                                    ($OM_WAIT_TIMEOUT seconds, default 60);
#                                    reports how long it took on stderr
#   om_api METHOD PATH [BODY|-] [CONTENT_TYPE]
#                                    any API call; prints the body, fails
#                                    unless 2xx
#   om_status METHOD PATH [BODY|-] [CONTENT_TYPE]
#                                    the same, printing only the HTTP status
#
# Values print as JSON numbers do, integers without a decimal point (3, 2.5).

_OM_PY="$(dirname "${BASH_SOURCE[0]}")/om.py"

om_ingest()     { python3 -I "$_OM_PY" ingest "$@"; }
om_query()      { python3 -I "$_OM_PY" query "$@"; }
om_wait_value() { python3 -I "$_OM_PY" wait "$@"; }
om_api()        { python3 -I "$_OM_PY" api "$@"; }
om_status()     { python3 -I "$_OM_PY" status "$@"; }
