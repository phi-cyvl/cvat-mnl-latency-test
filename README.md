# cvat-mnl-latency-test

Spins up a t3.medium EC2 in the **AWS Manila Local Zone** (`ap-southeast-1-mnl-1a`),
measures the network profile from there to a CVAT instance, ships the results
to S3 via presigned PUT URLs, and tears everything down. ~$0.02 per run.

## What problem this answers

CVAT serves frames in big chunks (~7–10 MB each, one HTTP request per chunk).
If a user pages through a job from a long-RTT link (PH → us-east-1 ≈ 240 ms),
every chunk pays **~3 RTTs of setup cost** (TCP + TLS + first byte) before the
body even starts flowing — and at high RTT with any packet loss, single-TCP
throughput collapses (Mathis equation: `≈ MSS / (RTT × √loss)`). Result: a
chunk that takes 0.3 s in the US can take 10–30 s in Manila.

This test quantifies that experience from a real Manila vantage so we can
make the case for (or against) a regional CDN, validate proposed fixes, and
catch regressions later.

## Why **Manila** Local Zone

AWS has no PH region. A [Local Zone](https://aws.amazon.com/about-aws/global-infrastructure/localzones/)
in `ap-southeast-1-mnl-1a` is the only AWS compute physically in Manila —
the only honest vantage to reproduce a PH user's network experience. Testing
from Singapore would skip the PH last mile and undersell the latency.

## What gets measured

All from the MNL EC2 toward your CVAT host:

| File | Measurement | What it tells you |
|---|---|---|
| `geo.json` | ipapi.co geo lookup | Sanity check: confirms egress IP is in Manila |
| `ping.txt` | 100 pings @ 0.5 s | Baseline RTT and variance (ICMP often dropped — 0% reachability is OK if TLS works) |
| `mtr.txt` | Per-hop traceroute + ping × 100 | **Where** packet loss lives (PH ISP / transit / AWS edge) |
| `handshakes.jsonl` | 20 cold HTTPS requests, full timing breakdown | Cost of TCP / TLS / first-byte separately. The headline measurement. |
| `warm.jsonl` | 20 keep-alive reused connections | Per-request cost when TCP+TLS are already established. Delta vs cold = what a long-lived proxy/CDN would save. |
| `chunk-fetches.jsonl` | 15 cold hits on `/api/jobs/$JOB_ID/data?type=chunk&number=N` | Real CVAT chunk URL pattern. Returns 401 without auth, but the 401 is sent only after TCP+TLS+request-parse, so the timing reflects the same network cost a real fetch would pay. |
| `static.jsonl` | 3 hits on `/` | Cold-connection sanity sample (not very useful — body too small for throughput estimation) |

### How to read the handshake numbers

`handshakes.jsonl` lines look like `{"trial":1,"dns":...,"tcp":...,"tls":...,"ttfb":...,"total":...}`.
Each value is **cumulative from request start in seconds**. Subtract adjacent
pairs to get the cost of each phase:

```
TCP handshake = tcp  - dns      ≈ 1 RTT
TLS handshake = tls  - tcp      ≈ 1 RTT
Request RTT   = ttfb - tls      ≈ 1 RTT
Total setup   = ttfb            ≈ 3 RTTs (= time before any body byte arrives)
```

`03-collect.sh` prints P50/P95 across the 20 trials.

### Why 20 cold + 20 warm

20 samples gives a stable median (P50) and 95th-percentile tail (P95). Cold =
fresh connection per request (what every chunk URL the browser opens pays).
Warm = single long-lived connection (what a CDN / proxy in front of CVAT would
behave like). Delta tells you what reuse buys.

## Quick start

```bash
aws sso login

export CVAT_TARGET=cvat.example.com   # your CVAT hostname (no scheme)
export CVAT_JOB_ID=12345              # any valid job ID for chunk probing

./run.sh
```

`NO_TEARDOWN=1 ./run.sh` keeps the infra up for debugging.

Phase by phase:

```bash
./scripts/00-prereqs.sh     # opt in MNL Local Zone (one-time, persistent)
./scripts/01-provision.sh   # VPC + subnet + IGW + SG + S3 bucket
./scripts/02-launch.sh      # presigned URLs + EC2 launch
./scripts/03-collect.sh     # poll S3 for done.txt, download, summarize
./scripts/04-teardown.sh    # destroy infra (keeps results bucket)
```

## How the bundle gets back to you

The EC2 has **no IAM role**. Most AWS SSO sessions lack `iam:CreateRole` /
`iam:PassRole` so we can't attach a role even if we made one. Instead,
`02-launch.sh` uses the runner's existing creds to sign three short-lived
S3 PUT URLs (1 h expiry) and bakes them into the user-data; the EC2 just
`curl PUT`s into them. No instance credentials, no IAM permissions needed.

(Gotcha: boto3's default presigned URL targets the legacy global S3 endpoint
which 301-redirects for non-us-east-1 buckets, and `curl --upload-file`
doesn't follow PUT redirects. We force `endpoint_url=https://s3.<region>.amazonaws.com`
so the URL hits the regional endpoint directly.)

## Output

Results download to `results/<run-id>/`:

```
meta.txt              run timestamp + EC2 details
geo.json              ipapi.co response
ping.txt              raw ping output
mtr.txt               raw mtr output
handshakes.jsonl      cold-connection timing per trial
warm.jsonl            keep-alive timing
chunk-fetches.jsonl   chunk URL timing (HTTP code + size + duration)
static.jsonl          frontend root timing
test.log              full bash trace from the EC2
```

`03-collect.sh` prints a one-screen summary at the end.

## Requirements

- AWS CLI v2 (`aws sts get-caller-identity` works)
- `python3` with `boto3` (already installed by awscli)
- `jq`, `bash` 4+
- AWS perms: EC2 + VPC + S3 in `ap-southeast-1`. **No IAM perms needed.**

## Cost & cleanup

| Resource | Cost per run |
|---|---|
| t3.medium MNL Local Zone, ~5 min | ~$0.01 |
| S3 bucket + ~1 MB results | <$0.01 |
| VPC / IGW / SG | $0 |
| **Total** | **~$0.02** |

Results bucket has a 7-day lifecycle. `04-teardown.sh --include-bucket`
nukes it immediately. `scripts/teardown-everything.sh --confirm` is a
brute-force tag-based cleanup if state is lost.

## Files

```
run.sh                       all phases end-to-end
scripts/
  lib.sh                     logging / state / AWS auth helpers
  00-prereqs.sh              auth check + Local Zone opt-in
  01-provision.sh            VPC + subnet + IGW + SG + S3
  02-launch.sh               presigned URLs + EC2 launch (gp2 root, IMDSv2)
  03-collect.sh              poll S3, download, summarize
  04-teardown.sh             destroy infra (keeps bucket)
  teardown-everything.sh     brute-force tag-based cleanup
userdata/
  test.sh                    measurement script that runs ON the EC2
state/                       runtime IDs (gitignored)
results/                     downloaded bundles (gitignored)
```
