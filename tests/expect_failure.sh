#!/usr/bin/env bash
# Runs an executable that must fail (an openmeter_server, openmeter_stack or
# openmeter_test trampoline), and checks its exit code, its output, that no
# OpenMeter env file was left, and that no process it started (anything
# whose command line names its TEST_TMPDIR, or an OpenMeter binary) still
# runs.
#
# Argv: <executable (rootpath)> <exit code> <fixed string>... [-- <args for the executable>...]
set -uo pipefail
target="$1" want_rc="$2"; shift 2
strings=()
while (( $# )) && [[ "$1" != -- ]]; do strings+=("$1"); shift; done
[[ "${1:-}" == -- ]] && shift
inner_tmp="$TEST_TMPDIR/inner"; mkdir -p "$inner_tmp"
out=$(cd "$TEST_SRCDIR/_main" && env -u XML_OUTPUT_FILE -u TEST_UNDECLARED_OUTPUTS_DIR TEST_TMPDIR="$inner_tmp" \
  timeout 600 "$TEST_SRCDIR/_main/$target" "$@" 2>&1)
rc=$?
echo "$out"
echo "---- exit $rc"
status=0
if [[ "$rc" != "$want_rc" ]]; then echo "FAIL: exit $rc, want $want_rc" >&2; status=1; fi
for s in "${strings[@]}"; do
  if grep -qF -- "$s" <<<"$out"; then echo "ok: $s"; else echo "FAIL: not in the output: $s" >&2; status=1; fi
done
if grep -q "TEST BODY FINISHED" <<<"$out"; then echo "FAIL: the test body ran to the end" >&2; status=1; fi
envs=$(find "$inner_tmp" -maxdepth 1 -name '*openmeter*.env' -o -maxdepth 1 -name '*_stack.env')
if [[ -n "$envs" ]]; then echo "FAIL: env file left: $envs" >&2; status=1; fi
sleep 1
# Processes (not this script or its ancestors: the sandbox's own
# command line names $TEST_TMPDIR) whose command line names the test's
# temp dir or an OpenMeter binary.
ancestors=" "; a=$$
while [[ -n "$a" && "$a" != 0 ]]; do ancestors+="$a "; a=$(awk '/^PPid:/{print $2}' /proc/$a/status 2>/dev/null); done
left=$(ls /proc | grep -E '^[0-9]+$' | while read -r p; do
  [[ "$ancestors" == *" $p "* ]] && continue
  c=$( { tr '\0' ' ' < /proc/$p/cmdline; } 2>/dev/null) || continue
  [[ -n "$c" && "$c" != *linux-sandbox* ]] || continue
  case "$c" in *"$inner_tmp"*|*usr/local/bin/openmeter*) echo "$p $c";; esac
done || true)
if [[ -n "$left" ]]; then echo "FAIL: processes still running: $left" >&2; status=1; else echo "ok: nothing it started is running"; fi
[[ $status == 0 ]] && echo PASS
exit $status
