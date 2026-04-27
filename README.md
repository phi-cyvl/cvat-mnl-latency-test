# cvat-mnl-latency-test

Spins up a t3.medium EC2 in the **AWS Manila Local Zone** (`ap-southeast-1-mnl-1a`),
measures the network profile from there to a CVAT instance, ships the results to S3,
and tears everything down. Cost per run: ~$0.02.

## Why Manila Local Zone

AWS has a [Local Zone](https://aws.amazon.com/about-aws/global-infrastructure/localzones/)
physically in Manila, parented to the Singapore region. It's the only honest vantage
for reproducing what a Philippines-based CVAT annotator experiences.

| Vantage | Distance to Manila user | What it measures |
|---|---|---|
| `ap-southeast-1-mnl-1a` **(this test)** | ~5 ms | What Manila annotators actually experience |
| `ap-southeast-1` (Singapore) | ~50–70 ms | AWS backbone only |
| `us-east-1` (Virginia) | n/a | Origin baseline |

## What gets measured

All measurements from the MNL EC2 toward your CVAT host:

| Measurement | Why |
|---|---|
| `ping -c 100` RTT | Confirms the baseline latency assumption |
| `mtr -rwzc 100` per-hop loss | Locates where packet loss lives (ISP / transit / AWS edge) |
| TLS handshake × 20 cold connections | Quantifies per-connection setup cost (multiplied by every chunk the browser opens) |
| Connection-reuse warm timing × 20 | Shows what a CDN / long-lived proxy would buy |
| Chunk endpoint × 5 chunks × 3 trials | Real behavior on the CVAT chunk URL pattern (returns 401 without auth, but connection timing is still meaningful) |
| Static asset (`/`) timing | Bandwidth ceiling on the link |
| Geo verification | Confirms the EC2 presents a Manila IP |

## Quick start

```bash
# 1. Authenticate to AWS
aws sso login

# 2. Set required env vars
export CVAT_TARGET=cvat.example.com       # your CVAT hostname, no https://
export CVAT_JOB_ID=12345                  # any valid job ID for chunk probing

# 3. Run end-to-end (provision → measure → collect → tear down)
./run.sh
```

Or phase by phase:

```bash
./scripts/00-prereqs.sh      # opt in MNL Local Zone (one-time)
./scripts/01-provision.sh    # VPC + subnet + IGW + SG + S3 bucket + IAM
./scripts/02-launch.sh       # launch t3.medium with test script as user-data
./scripts/03-collect.sh      # poll S3 for results, download, print summary
./scripts/04-teardown.sh     # destroy all resources (keeps results bucket)
```

Set `NO_TEARDOWN=1` to skip the prompt and leave infra up for debugging.

## Output

Results download to `results/<run-id>/`:

```
meta.txt              run timestamp, instance details
geo.json              ipapi.co response confirming Manila vantage
ping.txt              raw ping output
mtr.txt               raw mtr output
handshakes.jsonl      TLS handshake timing per trial (JSON lines)
warm.jsonl            connection-reuse timings
chunk-fetches.jsonl   chunk-endpoint timings (HTTP code + size + duration)
static.jsonl          static asset timings
test.log              full bash trace from the EC2
```

`03-collect.sh` prints a one-screen summary: median RTT, TLS handshake P50/P95,
chunk fetch timings.

## Requirements

- AWS CLI v2, authenticated (`aws sts get-caller-identity`)
- `jq`, `bash` 4+
- EC2 + VPC + S3 + IAM permissions in `ap-southeast-1`

## Cost & cleanup

| Resource | Cost per run |
|---|---|
| t3.medium MNL Local Zone, ~5 min | ~$0.01 |
| S3 bucket + ~1 MB results | <$0.01 |
| VPC / IGW / SG / IAM | $0 |
| **Total** | **~$0.02** |

The results bucket has a 7-day lifecycle expiry. `04-teardown.sh --include-bucket`
nukes it immediately. `scripts/teardown-everything.sh --confirm` does a brute-force
cleanup of all tagged resources if something crashed mid-run.

## Files

```
run.sh                       orchestrator: all phases end-to-end
scripts/
  lib.sh                     shared logging / state helpers
  00-prereqs.sh              verify auth, opt in Local Zone
  01-provision.sh            create throwaway infra
  02-launch.sh               launch EC2 with test script
  03-collect.sh              poll S3, download, summarize
  04-teardown.sh             destroy infra (keeps results bucket)
  teardown-everything.sh     brute-force tag-based cleanup
userdata/
  test.sh                    measurement script that runs ON the EC2
state/                       runtime IDs (gitignored)
results/                     downloaded bundles (gitignored)
```
