#!/usr/bin/env bash
# An openmeter_test body that kills OpenMeter's API server under itself:
# the stack must notice, and the trampoline must stop this test and fail.
set -euo pipefail
echo "killing the OpenMeter API server ($OPENMETER_SERVER_PID)"
kill -KILL "$OPENMETER_SERVER_PID"
sleep 120
echo "TEST BODY FINISHED"
