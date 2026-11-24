# -*- coding: utf-8 -*-
"""Disk latency of the WSL VM devices, read from /proc/diskstats through the Qdrant container.

    python qdrant_disk_latency.py [seconds=12] [container=qdrant_production] [device=sdd,sdc,sde]

Read-only. Two snapshots of /proc/diskstats, then the mean time per read and per
write, the in-flight queue, and the read/write throughput. Field 11 of diskstats
(the weighted in-flight time) measures latency, unlike "I/O busy".

Founding measurement (2026-11-24 05:31Z, after a read-path block of
roo_tasks_semantic_index): 0.1 ms per read on /dev/sdd (the qdrant VHDX,
4873 reads/s) and 0.2 ms on /dev/sde — the disk is NOT a measured
serialization point of the blocks. Standard library only.

Pitfall (a wrong reading was published then retracted on 2026-11-24): the
mean time per read is field 4 (ms reading) / field 1 (reads), NOT the
device "I/O busy" time (field 10) divided by the reads.
"""
import base64
import subprocess
import sys

SECONDS = float(sys.argv[1]) if len(sys.argv) > 1 else 12
CONTAINER = sys.argv[2] if len(sys.argv) > 2 else 'qdrant_production'
DEVICES = sys.argv[3].split(',') if len(sys.argv) > 3 else ['sdd', 'sdc', 'sde']

PAYLOAD = '\n'.join(['echo SNAP ' + d + ' $(grep -E " ' + d + ' " /proc/diskstats)' for d in DEVICES]) + '\necho ==END\n'


def snapshot():
    b64 = base64.b64encode(PAYLOAD.encode()).decode()
    out = subprocess.run(['docker', 'exec', CONTAINER, 'sh', '-c', 'echo %s | base64 -d | sh' % b64],
                         capture_output=True, text=True, timeout=90)
    data = {}
    for line in out.stdout.splitlines():
        if not line.startswith('SNAP '):
            continue
        parts = line.split()
        # SNAP dev major minor name reads merges sectors ms writes merges sectors ms inflight ios_ms weighted_ms ...
        if len(parts) < 17:
            sys.exit('unexpected diskstats line: %s' % line)
        data[parts[1]] = [int(x) for x in parts[5:16]]
    if not data:
        sys.exit('no device found (output: %s)' % (out.stderr.strip()[:200] or out.stdout[:200]))
    return data


a = snapshot()
subprocess.run(['sleep', str(SECONDS)])
b = snapshot()

print('VM disk latency over %.0fs (container %s)' % (SECONDS, CONTAINER))
print('  device  reads/s   ms/read   writes/s  ms/write   read MB/s  in-flight  weighted_queue_s')
for dev in sorted(b):
    fa = a.get(dev)
    if not fa:
        continue
    fb = b[dev]
    reads, w_reads = fb[0] - fa[0], fb[3] - fa[3]
    writes, w_writes = fb[4] - fa[4], fb[7] - fa[7]
    rbytes = (fb[2] - fa[2]) * 512 / 1e6
    wbytes = (fb[6] - fa[6]) * 512 / 1e6
    weighted = fb[10] - fa[10]
    print('  %-6s %8.1f %9.1f %10.1f %10.1f %10.1f %10d %15.1f'
          % (dev, reads / SECONDS, w_reads / max(reads, 1), writes / SECONDS, w_writes / max(writes, 1),
             rbytes / SECONDS, fb[8], weighted / 1000.0))
