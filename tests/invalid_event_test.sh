#!/usr/bin/env bash
# Invalid events are rejected with a 4xx, and nothing of them is stored.
set -euo pipefail
source "$OPENMETER_TESTLIB"

expect_4xx() {  # <what> <status>
  if [[ "$2" != 4?? ]]; then echo "FAIL: $1: HTTP $2, expected 4xx" >&2; exit 1; fi
  echo "ok: $1 -> HTTP $2"
}
expect_4xx "not JSON" "$(om_ingest --status 'not json')"
expect_4xx "no specversion/id/source" "$(om_ingest --status '{"type": "prompt", "subject": "x"}')"
expect_4xx "no subject" "$(om_ingest --status '{"specversion": "1.0", "id": "1", "source": "t", "type": "prompt"}')"
expect_4xx "no type" "$(om_ingest --status '{"specversion": "1.0", "id": "2", "source": "t", "subject": "x"}')"
expect_4xx "bad time" "$(om_ingest --status '{"specversion": "1.0", "id": "3", "source": "t", "type": "prompt", "subject": "x", "time": "yesterday"}')"
expect_4xx "wrong content type" "$(om_status POST /api/v1/events '{"specversion": "1.0"}' text/plain)"

# A valid one is accepted (204), and becomes queryable.
[[ "$(om_ingest --status --type prompt --subject x --data '{"tokens": 1}')" == 2?? ]]
om_wait_value 1 prompts --subject x
echo PASS
