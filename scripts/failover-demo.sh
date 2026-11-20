#!/usr/bin/env bash

# Script for demo purposes of cluster failover operation.
set -euo pipefail
NS=${NS:-postgres}
CL=${CL:-pg-main}
LOG=$(mktemp)

kubectl -n "$NS" delete pod pg-writer --ignore-not-found --wait=true
kubectl apply -f "$(dirname "$0")/../demo/writer-pod.yaml"
kubectl -n "$NS" wait --for=condition=Ready pod/pg-writer --timeout=120s

PRIMARY=$(kubectl -n "$NS" get cluster "$CL" -o jsonpath='{.status.currentPrimary}')
echo ">>> Current primary: $PRIMARY"
kubectl -n "$NS" logs -f pg-writer | tee "$LOG" & LOGS_PID=$!
sleep 8
echo ">>> Killing primary: $PRIMARY"
kubectl -n "$NS" delete pod "$PRIMARY" --grace-period=0 --force
sleep 45
kill $LOGS_PID 2>/dev/null || true

echo ">>> New primary: $(kubectl -n "$NS" get cluster "$CL" -o jsonpath='{.status.currentPrimary}')"
kubectl -n "$NS" get pods -l cnpg.io/cluster="$CL"

grep -E '^OK [0-9]+$' "$LOG" | awk '{print $2}' | sort -n > /tmp/acked.txt
kubectl -n "$NS" exec pg-writer -- psql -tAc "SELECT msg FROM demo WHERE msg ~ '^[0-9]+\$'" | sort -n > /tmp/indb.txt
MISSING=$(comm -23 /tmp/acked.txt /tmp/indb.txt | wc -l)
echo ">>> Confirmed entries: $(wc -l < /tmp/acked.txt), w bazie: $(wc -l < /tmp/indb.txt), MISSING confirmed: $MISSING"
echo ">>> Rejected during switchover (FAIL): $(grep -c '^FAIL' "$LOG" || true)"
