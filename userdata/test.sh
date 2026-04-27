#!/bin/bash
# CVAT latency measurement script. Runs ON the EC2 in MNL Local Zone as
# user-data. 02-launch.sh substitutes these placeholders before upload:
#   __RUN_ID__       run identifier (also S3 key prefix)
#   __TARGET__       CVAT hostname (no scheme)
#   __JOB_ID__       CVAT job ID for the chunk endpoint probe
#   __RESULTS_URL__  presigned PUT URL for the results tarball
#   __LOG_URL__      presigned PUT URL for the script's bash trace
#   __DONE_URL__     presigned PUT URL for the marker (uploaded last)
#
# Every measurement is wrapped in `|| true` — one failed step shouldn't
# skip the rest. All output is mirrored to /var/log/cvat-test.log so a
# failed run is debuggable via `aws ec2 get-console-output`.

set -uo pipefail
exec > /var/log/cvat-test.log 2>&1
set -x

RUN_ID='__RUN_ID__'
TARGET='__TARGET__'
JOB_ID='__JOB_ID__'

# cloud-init has fully attached the network by now; small slack for DNS.
sleep 5

# AL2023 ships awscli but not mtr/jq.
dnf install -y mtr bind-utils jq tar gzip iputils nc || true

OUT=/tmp/cvat-mnl-results
mkdir -p "$OUT"

# IMDSv2 is required (HttpTokens=required on launch). Fetch a token first.
IMDS_TOKEN=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" \
  -H "X-aws-ec2-metadata-token-ttl-seconds: 60" 2>/dev/null || true)
imds() { curl -s -H "X-aws-ec2-metadata-token: $IMDS_TOKEN" \
  "http://169.254.169.254/latest/meta-data/$1" 2>/dev/null || echo unknown; }

{
  echo "RUN_ID=$RUN_ID"
  echo "TARGET=$TARGET"
  echo "STARTED_AT=$(date -u +%FT%TZ)"
  echo "INSTANCE_ID=$(imds instance-id)"
  echo "INSTANCE_TYPE=$(imds instance-type)"
  echo "AVAILABILITY_ZONE=$(imds placement/availability-zone)"
  echo "PUBLIC_IP=$(imds public-ipv4)"
} > "$OUT/meta.txt"

# Confirm the egress IP is actually in MNL — if AWS routes us elsewhere
# the whole run is invalid.
curl -sS https://ipapi.co/json/ > "$OUT/geo.json" || echo "geo failed" > "$OUT/geo.errors.txt"

# 100 pings at 0.5s = ~50s. Enough samples for a stable median + variance.
ping -c 100 -i 0.5 -W 5 "$TARGET" > "$OUT/ping.txt" 2>&1 || true

# Per-hop loss/latency. -r report, -w long names, -z AS#s, -c packet count.
mtr -rwzc 100 "$TARGET" > "$OUT/mtr.txt" 2>&1 || true

# 20 cold-connection TLS handshakes against an unauth health endpoint.
# The dns/tcp/tls/ttfb/total deltas show where transpacific RTT amplifies.
for i in $(seq 1 20); do
  curl -sS -o /dev/null --connect-timeout 30 --max-time 60 \
    -w '{"trial":'"$i"',"dns":%{time_namelookup},"tcp":%{time_connect},"tls":%{time_appconnect},"ttfb":%{time_starttransfer},"total":%{time_total},"http":%{http_code}}\n' \
    "https://$TARGET/api/server/about" >> "$OUT/handshakes.jsonl" \
    || echo "trial $i failed" >> "$OUT/handshakes.errors.txt"
done

# Same endpoint, single connection, 20 sequential requests via --next.
# Delta vs cold = what a long-lived proxy/CDN connection would save.
warm_args=("https://$TARGET/api/server/about")
for _ in $(seq 1 19); do warm_args+=(--next "https://$TARGET/api/server/about"); done
curl -sS -o /dev/null --connect-timeout 30 --max-time 120 \
  -w '{"reused":true,"total":%{time_total},"http":%{http_code}}\n' \
  "${warm_args[@]}" >> "$OUT/warm.jsonl" \
  || echo "warm failed" >> "$OUT/warm.errors.txt"

# Chunk endpoint pattern. Returns 401 without auth, but the 401 is sent
# only after TCP+TLS+request-header-parse — so the timing still measures
# the full round-trip cost a real chunk fetch would pay.
for chunk in 0 1 2 3 4; do
  for trial in 1 2 3; do
    curl -sS -o /dev/null --connect-timeout 30 --max-time 120 \
      -w '{"chunk":'"$chunk"',"trial":'"$trial"',"size":%{size_download},"total":%{time_total},"speed_bps":%{speed_download},"http":%{http_code}}\n' \
      "https://$TARGET/api/jobs/$JOB_ID/data?quality=compressed&type=chunk&number=$chunk" \
      >> "$OUT/chunk-fetches.jsonl" \
      || echo "chunk $chunk trial $trial failed" >> "$OUT/chunk.errors.txt"
  done
done

# Frontend root — body large enough to estimate steady-state throughput.
for i in 1 2 3; do
  curl -sS -o /dev/null --connect-timeout 30 --max-time 60 \
    -w '{"trial":'"$i"',"size":%{size_download},"total":%{time_total},"speed_bps":%{speed_download},"http":%{http_code}}\n' \
    "https://$TARGET/" >> "$OUT/static.jsonl" \
    || echo "static $i failed" >> "$OUT/static.errors.txt"
done

echo "FINISHED_AT=$(date -u +%FT%TZ)" >> "$OUT/meta.txt"

cd /tmp
tar czf cvat-mnl-results.tgz cvat-mnl-results/

# Upload via presigned PUTs (no IAM role on this instance).
# Marker last — 03-collect.sh polls for it and assumes results are ready.
curl -sS -X PUT --upload-file /tmp/cvat-mnl-results.tgz "__RESULTS_URL__"
curl -sS -X PUT --upload-file /var/log/cvat-test.log   "__LOG_URL__"
echo "$(date -u +%FT%TZ) done" > /tmp/done.txt
curl -sS -X PUT --upload-file /tmp/done.txt            "__DONE_URL__"

# instance-initiated-shutdown=terminate on launch makes this end billing.
shutdown -h now
