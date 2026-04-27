#!/usr/bin/env bash
# Wait for the test EC2 to upload its done.txt marker, then download the
# results bundle and print a one-screen summary.
#
# Why poll: the EC2 has no SSH access (egress-only SG). The done.txt marker
# is the only signal that uploads finished — test.sh writes it last. If the
# marker never appears, fetch console output to diagnose.

set -euo pipefail
source "$(dirname "$0")/lib.sh"

info "phase 3 — collect results"

state_load
require_auth
: "${RUN_ID:?}"
: "${BUCKET:?}"
: "${INSTANCE_ID:?}"

DEST_DIR="$RESULTS_DIR/$RUN_ID"
mkdir -p "$DEST_DIR"

log "polling s3://$BUCKET/$RUN_ID/done.txt (up to 10 min, every 15 s)..."
SAW_DONE=""
for i in $(seq 1 40); do
  if aws s3api head-object --bucket "$BUCKET" --key "$RUN_ID/done.txt" >/dev/null 2>&1; then
    SAW_DONE=1
    ok "marker seen on attempt $i"
    break
  fi
  printf '.'
  sleep 15
done
echo

if [[ -z "$SAW_DONE" ]]; then
  warn "done.txt never appeared. Fetching console output for diagnosis."
  aws ec2 get-console-output --region "$REGION" --instance-id "$INSTANCE_ID" \
    --query Output --output text > "$DEST_DIR/console.txt" 2>&1 || true
  warn "console output saved to $DEST_DIR/console.txt"
  exit 2
fi

info "downloading bundle"
aws s3 sync "s3://$BUCKET/$RUN_ID/" "$DEST_DIR/" >/dev/null
[[ -f "$DEST_DIR/results.tgz" ]] || die "results.tgz missing"
tar xzf "$DEST_DIR/results.tgz" -C "$DEST_DIR" --strip-components=1
ok "extracted to $DEST_DIR"

echo
echo "===================================================================="
echo "  CVAT MNL latency test — summary  (run $RUN_ID)"
echo "===================================================================="

if [[ -f "$DEST_DIR/geo.json" ]] && command -v jq >/dev/null; then
  city=$(jq -r '.city // "?"' "$DEST_DIR/geo.json")
  region=$(jq -r '.region // "?"' "$DEST_DIR/geo.json")
  country=$(jq -r '.country_name // "?"' "$DEST_DIR/geo.json")
  ip=$(jq -r '.ip // "?"' "$DEST_DIR/geo.json")
  org=$(jq -r '.org // "?"' "$DEST_DIR/geo.json")
  printf "  Vantage: %s, %s, %s   (%s, %s)\n\n" "$city" "$region" "$country" "$ip" "$org"
fi

if [[ -f "$DEST_DIR/ping.txt" ]]; then
  echo "  Ping (ICMP RTT):"
  grep -E 'rtt|min/avg' "$DEST_DIR/ping.txt" | sed 's/^/    /' || true
  pct_loss=$(grep -oE '[0-9.]+% packet loss' "$DEST_DIR/ping.txt" | head -1)
  [[ -n "$pct_loss" ]] && echo "    loss: $pct_loss"
  echo
fi

if [[ -f "$DEST_DIR/mtr.txt" ]]; then
  echo "  MTR final hop (last 5 rows):"
  tail -5 "$DEST_DIR/mtr.txt" | sed 's/^/    /'
  echo
fi

if [[ -f "$DEST_DIR/handshakes.jsonl" ]] && command -v jq >/dev/null; then
  echo "  TLS handshake (cold connections, 20 trials, seconds):"
  for k in dns tcp tls ttfb total; do
    p50=$(jq -r ".$k" "$DEST_DIR/handshakes.jsonl" | sort -n | awk 'BEGIN{c=0}{a[c++]=$1}END{print a[int(c*0.5)]}')
    p95=$(jq -r ".$k" "$DEST_DIR/handshakes.jsonl" | sort -n | awk 'BEGIN{c=0}{a[c++]=$1}END{print a[int(c*0.95)]}')
    printf "    %-7s  p50=%-8s  p95=%s\n" "$k" "$p50" "$p95"
  done
  echo
fi

if [[ -f "$DEST_DIR/warm.jsonl" ]] && command -v jq >/dev/null; then
  echo "  Warm reuse (single connection, 20 requests):"
  jq -r '"    total=\(.total)s  http=\(.http)"' "$DEST_DIR/warm.jsonl"
  echo
fi

if [[ -f "$DEST_DIR/chunk-fetches.jsonl" ]] && command -v jq >/dev/null; then
  echo "  Chunk endpoint pattern (5 chunks × 3 trials):"
  jq -r '"    chunk=\(.chunk) trial=\(.trial) http=\(.http) size=\(.size)B time=\(.total)s speed=\(.speed_bps)B/s"' "$DEST_DIR/chunk-fetches.jsonl"
  echo
fi

if [[ -f "$DEST_DIR/static.jsonl" ]] && command -v jq >/dev/null; then
  echo "  Static / asset (3 trials):"
  jq -r '"    trial=\(.trial) http=\(.http) size=\(.size)B time=\(.total)s speed=\(.speed_bps)B/s"' "$DEST_DIR/static.jsonl"
  echo
fi

echo "===================================================================="
echo "  Full results: $DEST_DIR"
echo "===================================================================="
