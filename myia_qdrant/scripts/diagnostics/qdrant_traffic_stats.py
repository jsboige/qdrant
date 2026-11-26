#!/usr/bin/env python3
"""Real client traffic on a Qdrant collection, read from the container access log.

The access log (lines of ``actix_web::middleware::logger``) is the truth instrument for the
read path: synthetic probes (random vectors, healthz) do not see what clients actually get.

    docker logs qdrant_production --since 180m 2>&1 | python qdrant_traffic_stats.py
        one line per 10 minutes (n, 5xx, responses > 5 s, max OK latency) and a per-endpoint
        summary (last 60 minutes / before)
    ... | python qdrant_traffic_stats.py --minute 18:05
        one line per minute from 18:05Z
    ... | python qdrant_traffic_stats.py --hourly 03:00
        one line per hour from 03:00Z
    optional: --collection <name>   (default roo_tasks_semantic_index)
    optional: --include-probes      count the lane's own probes too (excluded by default)

Closure criterion used for the 2026-11-23 incident: 0 5xx AND 0 response > 5 s for >= 60 min.
Timestamps in the log are UTC. Python 3.7+, standard library only.
Founding measurement (2026-11-23): a sweep probe read "all 200" while the access log showed
100 % of the ``points`` requests failing for 20 minutes.

Probe discipline (measured 2026-11-26): the lane tags its own requests with
``Referer: lane-sweep-probe/<name>``. They are NOT client traffic and are skipped by default:
during the binary-quantization switch 300 probe queries made a 4-minute window read
"326 requests, 0 defect". In the actix access log the first quoted field is the Referer and
the second the User-Agent — the opposite of what a regex author tends to assume.
"""
import argparse
import collections
import re
import sys
from datetime import datetime, timedelta

PROBE_REFERER_PREFIX = 'lane-sweep-probe'

ACTIX = re.compile(
    r'^(\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d)\.\d+Z\s+INFO\s+actix_web::middleware::logger:\s+'
    r'(\S+)\s+"(\w+)\s+(\S+)\s+HTTP/[\d.]+"\s+(\d{3})\s+(\d+)\s+"([^"]*)"\s+"[^"]*"\s+([\d.]+)\s*$')


def read_rows(coll, include_probes=False):
    rows = []
    for line in sys.stdin.buffer.read().decode('utf-8', 'replace').splitlines():
        m = ACTIX.match(line)
        if not m:
            continue
        ts, _ip, _meth, path, status, _size, referer, dur = m.groups()
        if not include_probes and referer.startswith(PROBE_REFERER_PREFIX):
            continue
        parts = path.split('?')[0].split('/')
        if len(parts) < 3 or parts[1] != 'collections' or parts[2] != coll:
            continue
        endpoint = '/'.join(parts[3:]) if len(parts) > 3 else '(info)'
        rows.append((datetime.strptime(ts, '%Y-%m-%dT%H:%M:%S'), endpoint, int(status), float(dur)))
    return rows


def pct(values, p):
    values = sorted(values)
    return values[min(len(values) - 1, int(round(p / 100.0 * (len(values) - 1))))]


def bucket_table(rows, key_of, suffix, span):
    print('--- per %s (UTC):  n   5xx  >5s    max_OK_s' % span)
    buckets = collections.defaultdict(list)
    for r in rows:
        buckets[key_of(r[0])].append(r)
    for key in sorted(buckets):
        rs = buckets[key]
        ok = [r[3] for r in rs if r[2] < 500]
        n5 = sum(1 for r in rs if r[2] >= 500)
        slow = sum(1 for x in ok if x > 5)
        print('  %s%s %6d %5d %4d   %8.2f' % (key, suffix, len(rs), n5, slow, max(ok) if ok else 0))


def endpoint_table(rows, title):
    print('--- %s' % title)
    per = collections.defaultdict(list)
    for r in rows:
        per[r[1]].append(r)
    for name, rs in sorted(per.items(), key=lambda kv: -len(kv[1])):
        ok = [r[3] for r in rs if r[2] < 500]
        n5 = sum(1 for r in rs if r[2] >= 500)
        if not ok:
            print('  %-22s n=%6d 5xx=%5d  (no OK response)' % (name, len(rs), n5))
            continue
        print('  %-22s n=%6d 5xx=%5d  p50=%7.2f p90=%7.2f max=%8.2f  >5s=%d'
              % (name, len(rs), n5, pct(ok, 50), pct(ok, 90), max(ok), sum(1 for x in ok if x > 5)))


def main():
    ap = argparse.ArgumentParser(description='Qdrant real client traffic from the access log (stdin).')
    ap.add_argument('--collection', default='roo_tasks_semantic_index')
    ap.add_argument('--include-probes', action='store_true',
                    help='count the lane\'s own tagged probes (Referer %s/*) as traffic' % PROBE_REFERER_PREFIX)
    ap.add_argument('--minute', metavar='HH:MM', help='one line per minute from this UTC time')
    ap.add_argument('--hourly', metavar='HH:MM', help='one line per hour from this UTC time')
    args = ap.parse_args()
    rows = read_rows(args.collection, args.include_probes)
    if not rows:
        sys.exit('no access-log line for collection %s' % args.collection)
    now = max(r[0] for r in rows)
    print('collection=%s  lines=%d  first=%sZ  last=%sZ'
          % (args.collection, len(rows), min(r[0] for r in rows).strftime('%H:%M:%S'), now.strftime('%H:%M:%S')))
    day = now.strftime('%Y-%m-%dT')
    if args.minute:
        since = datetime.strptime(day + args.minute, '%Y-%m-%dT%H:%M')
        bucket_table([r for r in rows if r[0] >= since], lambda d: d.strftime('%H:%M'), 'Z', 'minute')
    elif args.hourly:
        since = datetime.strptime(day + args.hourly, '%Y-%m-%dT%H:%M')
        bucket_table([r for r in rows if r[0] >= since], lambda d: d.strftime('%Hh'), '', 'hour')
    else:
        bucket_table(rows, lambda d: d.strftime('%H:%M')[:-1] + '0', 'Z', '10 minutes')
        endpoint_table([r for r in rows if r[0] >= now - timedelta(minutes=60)],
                       'endpoints, last 60 minutes')
        endpoint_table([r for r in rows if r[0] < now - timedelta(minutes=60)],
                       'endpoints, before the last 60 minutes')


if __name__ == '__main__':
    main()
