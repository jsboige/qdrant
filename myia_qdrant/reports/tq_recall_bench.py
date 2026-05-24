#!/usr/bin/env python3
"""Recall@10 benchmark for TurboQuant migration of roo_tasks_semantic_index.

Methodology (self-contained, robust to lost ground-truth files):
  TurboQuant keeps the original float vectors (needed for rescoring), so we can
  obtain EXACT search results at query time with params.quantization.ignore=true.
  For N random query points:
    - exact   = query-by-id, top-10 (excl. self), quantization.ignore=true
    - quant   = query-by-id, top-10 (excl. self), quantized + rescore (default)
  recall@10 = mean(|exact ∩ quant| / 10)
Run: QKEY=<api-key> python3 tq_recall_bench.py [N]
"""
import os, sys, json, urllib.request

BASE = "http://localhost:6333"
COLL = "roo_tasks_semantic_index"
KEY = os.environ["QKEY"]
N = int(sys.argv[1]) if len(sys.argv) > 1 else 50


def post(path, body):
    req = urllib.request.Request(
        BASE + path,
        data=json.dumps(body).encode(),
        headers={"api-key": KEY, "Content-Type": "application/json"},
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=120) as r:
        return json.load(r)


def query_ids(point_id, ignore_quant):
    body = {
        "query": point_id,
        "limit": 11,  # +1 to drop self
        "with_payload": False,
        "with_vector": False,
    }
    if ignore_quant:
        body["params"] = {"quantization": {"ignore": True}}
    else:
        body["params"] = {"quantization": {"rescore": True, "oversampling": 2.0}}
    res = post(f"/collections/{COLL}/points/query", body)["result"]["points"]
    return [p["id"] for p in res if p["id"] != point_id][:10]


# 1. Random sample of N query points
sample = post(
    f"/collections/{COLL}/points/query",
    {"query": {"sample": "random"}, "limit": N, "with_payload": False, "with_vector": False},
)["result"]["points"]
ids = [p["id"] for p in sample]
print(f"sampled {len(ids)} query points")

overlaps = []
empties = 0
for i, pid in enumerate(ids):
    exact = set(query_ids(pid, ignore_quant=True))
    quant = set(query_ids(pid, ignore_quant=False))
    if not exact:
        empties += 1
        continue
    ov = len(exact & quant) / len(exact)
    overlaps.append(ov)

mean = sum(overlaps) / len(overlaps) if overlaps else 0.0
perfect = sum(1 for o in overlaps if o == 1.0)
print(json.dumps({
    "queries_measured": len(overlaps),
    "empty_skipped": empties,
    "recall_at_10_mean": round(mean, 4),
    "perfect_10of10": perfect,
    "min_overlap": round(min(overlaps), 3) if overlaps else None,
}, indent=2))
