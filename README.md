# cvat-mnl-latency-test

Spins up a t3.medium EC2 in the **AWS Manila Local Zone** (`ap-southeast-1-mnl-1a`),
measures the network profile from there to a CVAT instance, ships the results
to S3 via presigned PUT URLs, and tears everything down. ~$0.02 per run.

## Why Manila Local Zone

AWS has a [Local Zone](https://aws.amazon.com/about-aws/global-infrastructure/localzones/)
physically in Manila, parented to the Singapore region. It's the only honest
vantage for reproducing what a Philippines-based CVAT user experiences.

| Vantage | Distance to Manila user | What it measures |
|---|---|---|
| `ap-southeast-1-mnl-1a` **(this test)** | ~5 ms | What Manila users actually experience |
| `ap-southeast-1` (Singapore) | ~50–70 ms | AWS backbone only |
| `us-east-1` (Virginia) | n/a | Origin baseline |

## What gets measured

All measurements from the MNL EC2 toward your CVAT host:

| Measurement | Why |
|---|---|
| `ping -c 100` RTT | Baseline RTT and variance |
| `mtr -rwzc 100` per-hop | Locates packet loss (PH ISP / transit / AWS edge) |
| TLS handshake × 20 cold | Per-connection setup cost — multiplied by every chunk the browser opens |
| Connection-reuse warm × 20 | What a CDN / long-lived proxy would save |
| Chunk endpoint × 5 chunks × 3 trials | Real timing on the CVAT chunk URL pattern (401 without auth, but TCP+TLS+RTT cost is the same) |
| Static asset (`/`) | Bandwidth ceiling on the link |
| Geo verification | Confirms the EC2 actually presents a Manila IP |

## Quick start

```bash
aws sso login

export CVAT_TARGET=cvat.example.com   # your CVAT hostname (no scheme)
export CVAT_JOB_ID=12345              # any valid job ID for chunk probing

./run.sh
```

`NO_TEARDOWN=1 ./run.sh` keeps the infra up after the run for debugging.

Or phase by phase:

```bash
./scripts/00-prereqs.sh     # opt in MNL Local Zone (one-time, persistent)
./scripts/01-provision.sh   # VPC + subnet + IGW + SG + S3 bucket
./scripts/02-launch.sh      # presigned URLs + launch EC2
./scripts/03-collect.sh     # poll S3 for done.txt, download, summarize
./scripts/04-teardown.sh    # destroy infra (keeps results bucket)
```

## How it ships results back

The EC2 has **no IAM role**. 02-launch.sh signs three S3 PUT URLs with the
caller's credentials (1-hour expiry) and embeds them in the user-data; the
test script `curl PUT`s `results.tgz`, `test.log`, then `done.txt`. This
avoids requiring `iam:CreateRole` / `iam:PassRole` on the runner.

## Output

Results download to `results/<run-id>/`:

```
meta.txt              run timestamp + instance details
geo.json              ipapi.co response confirming Manila vantage
ping.txt              raw ping output
mtr.txt               raw mtr output
handshakes.jsonl      TLS handshake timing per cold trial
warm.jsonl            connection-reuse timings
chunk-fetches.jsonl   chunk-endpoint timings (HTTP code + size + duration)
static.jsonl          static asset timings
test.log              full bash trace from the EC2
```

`03-collect.sh` prints a one-screen summary at the end.

## Requirements

- AWS CLI v2 (`aws sts get-caller-identity` works)
- `python3` with `boto3` (already a dep of awscli)
- `jq`, `bash` 4+
- AWS perms: EC2 + VPC + S3 in `ap-southeast-1`. **No IAM perms needed.**

## Cost & cleanup

| Resource | Cost per run |
|---|---|
| t3.medium MNL Local Zone, ~5 min | ~$0.01 |
| S3 bucket + ~1 MB results | <$0.01 |
| VPC / IGW / SG | $0 |
| **Total** | **~$0.02** |

Bucket has a 7-day lifecycle. `04-teardown.sh --include-bucket` nukes it
immediately. `scripts/teardown-everything.sh --confirm` brute-forces a
cleanup of all tagged resources if state is lost.

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
