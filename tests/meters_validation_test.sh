#!/usr/bin/env bash
# The build-time meters check (validate_meters.py with the pinned
# `openmeter --validate`): each bad file fails with the file, the meter and
# the reason; the good one passes and is copied.
#
# Argv: <validate_meters.py> <openmeter binary> <good meters.yaml> <bad dir>
set -uo pipefail
V="$TEST_SRCDIR/_main/$1"
B="$(cd "$TEST_SRCDIR/_main" && realpath "$2")"
GOOD="$TEST_SRCDIR/_main/$3"
BAD="$TEST_SRCDIR/_main/$4"
status=0

expect() {  # <file> <fixed string>...
  local f="$1"; shift
  local out rc
  out=$(python3 -I "$V" //t:server "$BAD/$f" "$B" "$TEST_TMPDIR/out.yaml" 2>&1); rc=$?
  if [[ $rc == 0 ]]; then echo "FAIL: $f passed" >&2; status=1; return; fi
  for s in "$@"; do
    if grep -qF -- "$s" <<<"$out"; then :; else echo "FAIL: $f: not in the output: $s"$'\n'"$out" >&2; status=1; return; fi
  done
  echo "ok: $f:"; sed 's/^/    /' <<<"$out"
}

expect no_value_property.yaml "//t:server: bad meters file" "meter #1 (line 2, slug 'tokens'): meter value property is required when the aggregation is not count"
expect duplicate_slug.yaml "meter #2 (line 5, slug 'a'): duplicate slug; meter #1 has it too"
expect bad_aggregation.yaml "aggregation 'MEDIAN': expected one of SUM, COUNT, AVG, MIN, MAX, UNIQUE_COUNT, LATEST"
expect bad_slug.yaml "slug 'Tokens-Total'): slug must match"
expect extra_key.yaml "line 5: top-level key 'sink': the meters file may only hold \`meters:\`"
expect not_yaml.yaml "meter #1 (line 2, slug 'a'): YAML:"
expect no_event_type.yaml "meter #1 (line 2, slug 'a'): meter event type is required"
expect bad_group_by.yaml "meter #1 (line 2, slug 'a'): meter group by value must start with \$ for key model"
expect no_meters_key.yaml "line 2: top-level key 'slug'"
expect no_slug.yaml "meter #1 (line 2): no \`slug\`"

if python3 -I "$V" //t:server "$GOOD" "$B" "$TEST_TMPDIR/good.yaml"; then
  cmp -s "$GOOD" "$TEST_TMPDIR/good.yaml" && echo "ok: the good file passes and is copied" || { echo "FAIL: copy differs" >&2; status=1; }
else
  echo "FAIL: the good file fails" >&2; status=1
fi
[[ $status == 0 ]] && echo PASS
exit $status
