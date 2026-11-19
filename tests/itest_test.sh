#!/usr/bin/env bash
# rules_itest: two OpenMeter stacks (openmeter_stack) as two itest_services
# in one service_test. Each has its own Kafka, ClickHouse, Postgres and
# OpenMeter; events sent to one are not in the other.
set -euo pipefail
source "$OPENMETER_TESTLIB_PATH"
load() { (set -a; source "$TEST_TMPDIR/$1.env"; set +a; printf '%s' "$OPENMETER_URL"); }
a="$(load stack_a)"; b="$(load stack_b)"
[[ "$a" != "$b" ]]
echo "stack_a: $a  stack_b: $b"

OPENMETER_URL="$a" om_ingest --type prompt --subject s --data '{"tokens": 1, "model": "a"}'
OPENMETER_URL="$b" om_ingest --type prompt --subject s --data '{"tokens": 20, "model": "a"}'
OPENMETER_URL="$b" om_ingest --type prompt --subject s --data '{"tokens": 300, "model": "a"}'
OPENMETER_URL="$a" om_wait_value 1 tokens_total --subject s
OPENMETER_URL="$b" om_wait_value 320 tokens_total --subject s
OPENMETER_URL="$a" om_wait_value 1 prompts --subject s
OPENMETER_URL="$b" om_wait_value 2 prompts --subject s
echo PASS
