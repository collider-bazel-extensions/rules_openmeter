"""Prints the TCP ports a process listens on, one per line, from /proc
(no ss/netstat needed). Usage: python3 listeners.py PID"""
import os
import sys

pid = sys.argv[1]
inodes = set()
for fd in os.listdir(f"/proc/{pid}/fd"):
    try:
        target = os.readlink(f"/proc/{pid}/fd/{fd}")
    except OSError:
        continue
    if target.startswith("socket:["):
        inodes.add(target[8:-1])
ports = set()
for table in ("tcp", "tcp6"):
    try:
        lines = open(f"/proc/{pid}/net/{table}").read().splitlines()[1:]
    except OSError:
        continue
    for line in lines:
        f = line.split()
        local, state, inode = f[1], f[3], f[9]
        if state == "0A" and inode in inodes:  # 0A = LISTEN
            addr, port = local.rsplit(":", 1)
            ports.add((table, addr, int(port, 16)))
for table, addr, port in sorted(ports, key=lambda x: x[2]):
    print(f"{port} {table} {addr}")
