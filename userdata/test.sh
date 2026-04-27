#!/bin/bash
# test.sh — CVAT latency measurement script.
# Runs ON the EC2 in the Manila Local Zone (passed as user-data).
# Two placeholders are substituted by 02-launch.sh before upload:
#   __BUCKET__  → S3 bucket for results
#   __RUN_ID__  → run identifier (also the S3 key prefix)
#
# What it does:
#   1. Installs measurement tools (mtr, jq, etc.)
#   2. Verifies geographic vantage via ipapi.co
#   3. Measures ping RTT and per-hop loss/latency (mtr)
#   4. Captures TLS handshake breakdown across 20 cold connections
#   5. Captures warm-connection (HTTP keep-alive) timings
#   6. Hits the /api/jobs/*/data?type=chunk endpoint without auth
#      to characterize how the chunk-pattern actually transfers
#   7. Times static asset transfer (/) for bandwidth ceiling
#   8. Tarballs results, uploads to S3, writes a `done.txt` marker
#   9. Shuts the instance down (which terminates it, by launch flag)
#
# Robustness notes:
#   - Every measurement is wrapped in `|| true` so a single failure doesn't
#     skip later ones. Errors are recorded in *.errors.txt files inside the
#     bundle.
#   - All output is mirrored to /var/log/cvat-test.log so a failed run can
#     still be debugged via `aws ec2 get-console-output`.

set -uo pipefail
exec > /var/log/cvat-test.log 2>&1
set -x

BUCKET='__BUCKET__'
RUN_ID='__RUN_ID__'
TARGET='__TARGET__'
JOB_ID='__JOB_ID__'

# Wait for cloud-init network to settle.
sleep 5

# AL2023 uses dnf. mtr lives in core repo as `mtr`.
dnf install -y mtr bind-utils jq tar gzip iputils nc || true

OUT=/tmp/cvat-mnl-results
mkdir -p "$OUT"

# ---- 0. Metadata ------------------------------------------------------------
# IMDSv2: fetch a short-lived session token first (required when HttpTokens=required).
IMDS_TOKEN=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" \
  -H "X-aws-ec2-metadata-token-ttl-seconds: 60" 2>/dev/null || true)
imds() { curl -s -H "X-aws-ec2-metadata-token: $IMDS_TOKEN" \
  "http://169.254.169.254/latest/meta-data/$1" 2>/dev/null || echo unknown; }

{
  echo "RUN_ID=$RUN_ID"
  echo "TARGET=$TARGET"
  echo "STARTED_AT=$(date -u +%FT%TZ)"
  echo "HOSTNAME=$(hostname)"
  echo "INSTANCE_ID=$(imds instance-id)"
  echo "INSTANCE_TYPE=$(imds instance-type)"
  echo "AVAILABILITY_ZONE=$(imds placement/availability-zone)"
  echo "PUBLIC_IP=$(imds public-ipv4)"
} > "$OUT/meta.txt"

# ---- 1. Geo verification ----------------------------------------------------
# Confirm the EC2's egress IP is actually in PH/Manila. If ipapi.co reports
# something else (e.g. AWS edge in another region), our results aren't
# representative and we should know.
curl -sS https://ipapi.co/json/ > "$OUT/geo.json" || echo "geo failed" > "$OUT/geo.errors.txt"

# ---- 2. ICMP RTT ------------------------------------------------------------
# 100 pings @ 0.5s spacing = ~50s total. Small enough sample for variance.
ping -c 100 -i 0.5 -W 5 "$TARGET" > "$OUT/ping.txt" 2>&1 || true

# ---- 3. mtr (per-hop loss + latency) ---------------------------------------
# -r report mode, -w long hostnames, -z print AS#s, -c packet count
mtr -rwzc 100 "$TARGET" > "$OUT/mtr.txt" 2>&1 || true

# ---- 4. TLS handshake breakdown × 20 cold connections ----------------------
# Each curl opens a fresh TCP+TLS connection to /api/server/about (an
# unauthenticated CVAT health-ish endpoint). curl's -w timing variables:
#   time_namelookup    DNS
#   time_connect       TCP handshake done
#   time_appconnect    TLS handshake done
#   time_starttransfer first byte received (TTFB)
#   time_total         response body fully read
# The deltas tell us where in the request flow the slowdown lives.
for i in $(seq 1 20); do
  curl -sS -o /dev/null --connect-timeout 30 --max-time 60 \
    -w '{"trial":'"$i"',"dns":%{time_namelookup},"tcp":%{time_connect},"tls":%{time_appconnect},"ttfb":%{time_starttransfer},"total":%{time_total},"http":%{http_code}}\n' \
    "https://$TARGET/api/server/about" >> "$OUT/handshakes.jsonl" \
    || echo "trial $i failed" >> "$OUT/handshakes.errors.txt"
done

# ---- 5. Warm connection (HTTP keep-alive) reuse × 20 ----------------------
# Single curl invocation with --next reuses the same connection across
# requests. Compares against (4) — the difference is what a long-lived
# proxy/CDN would buy us per request.
warm_args=("https://$TARGET/api/server/about")
for _ in $(seq 1 19); do
  warm_args+=(--next "https://$TARGET/api/server/about")
done
curl -sS -o /dev/null --connect-timeout 30 --max-time 120 \
  -w '{"reused":true,"total":%{time_total},"http":%{http_code}}\n' \
  "${warm_args[@]}" >> "$OUT/warm.jsonl" \
  || echo "warm failed" >> "$OUT/warm.errors.txt"

# ---- 6. Chunk endpoint pattern × 5 chunks × 3 trials -----------------------
# Hits the actual chunk URL pattern. Without auth, CVAT returns 401 with a
# small body. We're measuring connection setup + server response time.
for chunk in 0 1 2 3 4; do
  for trial in 1 2 3; do
    curl -sS -o /dev/null --connect-timeout 30 --max-time 120 \
      -w '{"chunk":'"$chunk"',"trial":'"$trial"',"size":%{size_download},"total":%{time_total},"speed_bps":%{speed_download},"http":%{http_code}}\n' \
      "https://$TARGET/api/jobs/$JOB_ID/data?org=geosolutions&quality=compressed&type=chunk&number=$chunk" \
      >> "$OUT/chunk-fetches.jsonl" \
      || echo "chunk $chunk trial $trial failed" >> "$OUT/chunk.errors.txt"
  done
done

# ---- 7. Static asset (/) ---------------------------------------------------
# Hits the CVAT frontend root. Gives us a body large enough to estimate
# steady-state throughput on the link.
for i in 1 2 3; do
  curl -sS -o /dev/null --connect-timeout 30 --max-time 60 \
    -w '{"trial":'"$i"',"size":%{size_download},"total":%{time_total},"speed_bps":%{speed_download},"http":%{http_code}}\n' \
    "https://$TARGET/" >> "$OUT/static.jsonl" \
    || echo "static $i failed" >> "$OUT/static.errors.txt"
done

# ---- 8. Pack + ship --------------------------------------------------------
echo "FINISHED_AT=$(date -u +%FT%TZ)" >> "$OUT/meta.txt"

cd /tmp
tar czf cvat-mnl-results.tgz cvat-mnl-results/

# Upload bundle, then write the marker. The collect script polls for done.txt.
aws s3 cp /tmp/cvat-mnl-results.tgz "s3://$BUCKET/$RUN_ID/results.tgz"
aws s3 cp /var/log/cvat-test.log "s3://$BUCKET/$RUN_ID/test.log"
echo "$(date -u +%FT%TZ) done" > /tmp/done.txt
aws s3 cp /tmp/done.txt "s3://$BUCKET/$RUN_ID/done.txt"

# ---- 9. Self-terminate -----------------------------------------------------
# `--instance-initiated-shutdown-behavior terminate` is set on launch, so
# `shutdown` here will terminate the instance. AWS will not bill further.
shutdown -h now
