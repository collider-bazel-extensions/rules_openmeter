#!/usr/bin/env bash
# An openmeter_test tagged block-network: the sandbox gives it (and the
# whole stack it starts: Kafka, ClickHouse, Postgres, OpenMeter) loopback
# only. This checks that holds (no interface but lo; connections to public
# addresses fail), that the stack works anyway, and that everything
# listening in the sandbox's network namespace is on 127.0.0.1. Fails if a
# connection gets through, e.g. when the spawn strategy isn't a sandbox that
# can block the network.
set -euo pipefail
source "$OPENMETER_TESTLIB"

ifaces="$(ls /sys/class/net)"
[[ "$ifaces" == lo ]] || { echo "FAIL: network interfaces: $ifaces (expected lo only)" >&2; exit 1; }
echo "ok: the only network interface is lo"

python3 -I - <<'PY'
import socket, sys
targets = [("8.8.8.8", 53), ("1.1.1.1", 443), ("140.82.112.3", 443)]
try:
    for info in socket.getaddrinfo("ghcr.io", 443, proto=socket.IPPROTO_TCP):
        targets.append((info[4][0], 443))
    print("note: ghcr.io resolves (host resolver); connecting must still fail")
except OSError as e:
    print("ok: name resolution blocked too (%s)" % e)
leaks = []
for host, port in targets:
    try:
        socket.create_connection((host, port), timeout=5).close()
        leaks.append("%s:%d" % (host, port))
    except OSError as e:
        print("ok: %s:%d unreachable (%s)" % (host, port, e))
if leaks:
    sys.exit("FAIL: connected from a block-network test to " + ", ".join(leaks))
PY

# The stack works offline.
om_ingest --type prompt --subject offline --data '{"tokens": 3, "model": "a"}'
om_wait_value 3 tokens_total --subject offline
echo "ok: ingest -> query works with the network blocked"

# Every TCP listener in this network namespace (the whole stack) is on
# 127.0.0.1. /proc/net/tcp6 must have none bound to a non-loopback address.
python3 -I - <<'PY'
import sys
bad, n = [], 0
for table in ("tcp", "tcp6"):
    for line in open(f"/proc/net/{table}").read().splitlines()[1:]:
        f = line.split()
        if f[3] != "0A":  # LISTEN
            continue
        n += 1
        addr, port = f[1].rsplit(":", 1)
        # 127.0.0.1, ::1, ::ffff:127.0.0.1 (an IPv4 loopback socket on a dual-stack JVM)
        if addr not in ("0100007F", "00000000000000000000000001000000", "0000000000000000FFFF00000100007F"):
            bad.append(f"{table} {addr}:{int(port, 16)}")
if bad:
    sys.exit("FAIL: listeners not on loopback: " + ", ".join(bad))
print(f"ok: all {n} TCP listeners are on loopback (127.0.0.1, or ::ffff:127.0.0.1 for the JVM)")
PY
echo PASS
