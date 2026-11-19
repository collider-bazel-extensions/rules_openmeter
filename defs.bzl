"""Public API for rules_openmeter.

  openmeter_server        OpenMeter's API server + sink worker on free
                          loopback ports, against a kafka_server, a
                          clickhouse_server and a pg_server (their env
                          files); writes $TEST_TMPDIR/<name>.env once ready
  openmeter_health_check  pairs with openmeter_server / openmeter_stack for
                          itest_service
  openmeter_stack         Kafka + ClickHouse + Postgres + OpenMeter as one
                          long-running executable
  openmeter_test          sh_test macro: an auto-launched stack + `om_*` helpers
"""

load("//private:binaries.bzl", _OpenMeterBinaryInfo = "OpenMeterBinaryInfo")
load("//private:server.bzl",
     _OpenMeterServerInfo = "OpenMeterServerInfo",
     _openmeter_health_check = "openmeter_health_check",
     _openmeter_server = "openmeter_server")
load("//private:stack.bzl", _openmeter_stack = "openmeter_stack")
load("//private:test.bzl", _openmeter_test = "openmeter_test")

openmeter_server = _openmeter_server
openmeter_health_check = _openmeter_health_check
openmeter_stack = _openmeter_stack
openmeter_test = _openmeter_test
OpenMeterBinaryInfo = _OpenMeterBinaryInfo
OpenMeterServerInfo = _OpenMeterServerInfo
