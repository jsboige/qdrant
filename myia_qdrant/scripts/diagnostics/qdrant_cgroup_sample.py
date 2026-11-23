#!/usr/bin/env python3
"""Memory and I/O state of the production Qdrant container, inside its cgroup (read-only).

    python qdrant_cgroup_sample.py [seconds=30] [container=qdrant_production]

Prints, through ``docker exec``:
  - cgroup v2 limits and usage: memory.max, memory.swap.max, memory.current, memory.swap.current
  - the qdrant process: VmRSS / VmSwap  (how much of the "always_ram" cache is really in swap)
  - the WSL VM: MemTotal, MemAvailable, SwapTotal, SwapFree  (SwapFree = 0 => VM swap is full)
  - rates over <seconds>: block I/O per device (byte resolution, unlike ``docker stats`` which
    rounds to GB) and average CPU in cores
  - VM-wide pages swapped in / out during the window

Founding measurement (2026-11-23 18:49Z): VmSwap 23.7 GB and VM SwapFree 0 while 100 % of the
reads of roo_tasks_semantic_index timed out. Standard library only.
"""
import base64
import subprocess
import sys
import time

SECONDS = int(sys.argv[1]) if len(sys.argv) > 1 else 30
CONTAINER = sys.argv[2] if len(sys.argv) > 2 else 'qdrant_production'

PAYLOAD = r'''
C=/sys/fs/cgroup
echo ==CG
for f in memory.max memory.swap.max memory.current memory.swap.current memory.peak; do
  echo "$f $(cat $C/$f 2>/dev/null)"
done
echo ==IO
cat $C/io.stat
echo ==CPU
cat $C/cpu.stat
echo ==PROC
P=""
for d in /proc/[0-9]*; do
  if grep -q '^Name:[[:space:]]*qdrant' $d/status 2>/dev/null; then P=$d; break; fi
done
echo "pid ${P#/proc/}"
grep -E '^(VmRSS|VmSwap|RssAnon|RssFile|Threads)' $P/status 2>/dev/null
echo ==VM
grep -E '^(MemTotal|MemFree|MemAvailable|SwapTotal|SwapFree):' /proc/meminfo
grep -E '^(pswpin|pswpout|oom_kill) ' /proc/vmstat
echo ==END
'''


def snapshot():
    b64 = base64.b64encode(PAYLOAD.encode()).decode()
    out = subprocess.run(['docker', 'exec', CONTAINER, 'sh', '-c', 'echo %s | base64 -d | sh' % b64],
                         capture_output=True, text=True, timeout=120)
    text = out.stdout
    if '==END' not in text:
        sys.exit('docker exec failed: %s' % (out.stderr.strip()[:300] or 'incomplete output'))
    sections, name = {}, None
    for line in text.splitlines():
        if line.startswith('=='):
            name = line[2:]
            sections[name] = {}
        elif name and ' ' in line:
            k, v = line.split(None, 1)
            sections[name][k.strip(':')] = v
    return sections


def kv(s):
    """'<key> <int> ...' lines -> {key: int}"""
    return {k: int(v.split()[0]) for k, v in s.items()}


def iokv(s):
    """cgroup io.stat line 'rbytes=1 wbytes=2 ...' -> {rbytes: 1, ...}"""
    out = {}
    for item in s.split():
        k, v = item.split('=')
        out[k] = int(v)
    return out


a = snapshot()
time.sleep(SECONDS)
b = snapshot()
dt = SECONDS

cg, cb = kv(a['CG']), kv(b['CG'])
gib = float(1 << 30)
print('container %s - window %ds' % (CONTAINER, dt))
print('  memory.max         = %6.2f Gio' % (cb['memory.max'] / gib if cb['memory.max'] < (1 << 60) else -1))
print('  memory.current     = %6.2f Gio' % (cb['memory.current'] / gib))
print('  memory.swap.max    = %6.2f Gio' % (cb['memory.swap.max'] / gib if cb['memory.swap.max'] < (1 << 60) else -1))
print('  memory.swap.current= %6.2f Gio   (delta %+0.2f Gio)' % (cb['memory.swap.current'] / gib,
      (cb['memory.swap.current'] - cg['memory.swap.current']) / gib))
print('  memory.peak        = %6.2f Gio' % (cb.get('memory.peak', 0) / gib))
proc = {k: int(v.split()[0]) * 1024 for k, v in b['PROC'].items() if k != 'pid'}  # /proc values are in kB
print('  qdrant pid %s: %s' % (b['PROC'].get('pid', '?'), '  '.join(
    '%s=%.2f Gio' % (k, proc[k] / gib) for k in ('VmRSS', 'VmSwap') if k in proc)))

cpu_a, cpu_b = kv(a['CPU']), kv(b['CPU'])
print('  CPU average        = %.2f core(s)' % ((cpu_b['usage_usec'] - cpu_a['usage_usec']) / 1e6 / dt))

io_a, io_b = a['IO'], b['IO']
print('  block I/O rates:')
for dev in sorted(io_b):
    ia = iokv(io_a[dev]) if dev in io_a else {}
    ib = iokv(io_b[dev])
    deltas = []
    for k in ('rbytes', 'wbytes'):
        d = ib.get(k, 0) - ia.get(k, 0)
        deltas.append('%s %+0.1f Mo (%0.2f Mo/s)' % (k[0], d / 1e6, d / 1e6 / dt))
    n = ib.get('rios', 0) - ia.get('rios', 0)
    deltas.append('reads=%d (avg %0.1f Ko)' % (n, (ib.get('rbytes', 0) - ia.get('rbytes', 0)) / max(n, 1) / 1e3))
    if any(ib.get(k, 0) for k in ('rbytes', 'wbytes')):
        print('    %s  %s' % (dev, '  '.join(deltas)))

vm_a, vm_b = kv(a['VM']), kv(b['VM'])
print('WSL VM:')
print('  MemTotal = %.1f Gio   MemAvailable = %.1f Gio   MemFree = %.1f Gio'
      % (vm_b['MemTotal'] / 1048576.0, vm_b['MemAvailable'] / 1048576.0, vm_b['MemFree'] / 1048576.0))
print('  SwapTotal = %.1f Gio  SwapFree = %.2f Gio %s'
      % (vm_b['SwapTotal'] / 1048576.0, vm_b['SwapFree'] / 1048576.0,
         '<== VM SWAP FULL' if vm_b['SwapFree'] <= 4096 else ''))
print('  window: swapped in %0.1f Mo, swapped out %0.1f Mo, oom_kill total %d'
      % ((vm_b['pswpin'] - vm_a['pswpin']) * 4096 / 1e6, (vm_b['pswpout'] - vm_a['pswpout']) * 4096 / 1e6,
         vm_b['oom_kill']))
