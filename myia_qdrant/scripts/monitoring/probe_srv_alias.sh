#!/bin/bash
# Probe: does the /srv/qdrant-e alias resolve the anti-split-brain sentinel
# INSIDE the Docker Desktop proxy mount namespace?
#
# Why this file exists (measured 03/11/2026): the pathfix overlay binds
# \\wsl.localhost\Ubuntu\srv\qdrant-e\... and it is the DD proxy -- not PID-1 --
# that resolves that path. The proxy lives in a PRIVATE COPY of the mount
# namespace, so PID-1 propagation does not reach it: the alias can be alive in
# PID-1 (sentinel 285) and dead in the proxy (pointing at a stale rootfs dir).
#
# Run from the Windows side:
#   MSYS_NO_PATHCONV=1 wsl -u root -- bash /mnt/d/qdrant/myia_qdrant/scripts/monitoring/probe_srv_alias.sh
#
# Expected output: one line per docker-desktop-* proxy process, each "285".
# Any other value (or no line) = the alias is dead in the proxy namespace.
set -u
expected=285
found=0
for f in /proc/[0-9]*/comm; do
  grep -q docker-desktop "$f" 2>/dev/null || continue
  p="${f#/proc/}"; p="${p%/comm}"
  sz=$(nsenter -t "$p" -m -- stat -c %s /srv/qdrant-e/qdrant_data/storage/.qdrant_vhdx_sentinel 2>/dev/null)
  if [ "$sz" = "$expected" ]; then
    echo "proxy-alias-ok:pid=$p sentinel=$sz"
    found=1
  else
    echo "proxy-alias-DEAD:pid=$p sentinel='${sz}' (expected $expected)"
  fi
done
if [ "$found" -eq 0 ]; then
  echo "NO-PROXY-NS-FOUND (Docker Desktop proxy not running, or alias absent everywhere)"
fi
