# Runbook

Operator guide. For *what* the test measures and *why*, read [README.md](./README.md).

## Prereqs

```bash
aws sso login
aws sts get-caller-identity   # confirm identity

export CVAT_TARGET=cvat.example.com   # your CVAT hostname (no scheme)
export CVAT_JOB_ID=12345              # valid job ID for chunk probing
```

Tools: `aws` CLI v2, `python3` (with `boto3` — installed by awscli), `jq`,
`bash` 4+. AWS perms: EC2 + VPC + S3 in `ap-southeast-1`. **No IAM perms needed.**

## End-to-end

```bash
./run.sh                # phases 00 → 04, prompts before teardown
NO_TEARDOWN=1 ./run.sh  # keep infra up after the run
```

## Per-phase

### `00-prereqs.sh`

Verifies auth and opts in the MNL Local Zone (one-time, persistent, free).
Idempotent.

### `01-provision.sh`

Creates: VPC `10.42.0.0/16`, IGW, subnet `10.42.1.0/24` in
`ap-southeast-1-mnl-1a`, route table → IGW, security group (egress-only,
no ingress), S3 bucket with SSE-S3 + 7-day lifecycle. Tags every resource
`Project=cvat-mnl-test, RunId=<RUN_ID>`. Saves IDs to `state/infra.env`.

No IAM resources — see 02-launch.sh.

### `02-launch.sh`

1. Looks up the latest AL2023 x86_64 AMI in `ap-southeast-1`.
2. Generates 3 presigned S3 PUT URLs (1-hour expiry) using boto3 — one each
   for `results.tgz`, `test.log`, `done.txt`. Forces the regional endpoint
   so curl PUTs don't hit the legacy 301-redirect.
3. Renders `userdata/test.sh` substituting RUN_ID, target, job ID, and the
   three presigned URLs.
4. Launches a t3.medium with:
   - `gp2` root volume (MNL Local Zone doesn't support `gp3`)
   - IMDSv2 required (`HttpTokens=required`)
   - `instance-initiated-shutdown=terminate` so `shutdown -h now` from inside
     the test ends billing

### `03-collect.sh`

Polls `s3://$BUCKET/$RUN_ID/done.txt` (15 s interval, 10 min cap). Once seen,
downloads the bundle, extracts to `results/<RUN_ID>/`, prints summary
(geo, ping P50/loss, mtr last hops, TLS handshake P50/P95, chunk timings).

If the marker doesn't appear in time, dumps EC2 console output to
`results/<RUN_ID>/console.txt` for debugging.

### `04-teardown.sh`

Destroys infra in dependency-safe order: instance → SG → RT → subnet → IGW →
VPC. Bucket kept by default (lifecycle expires in 7 days).

```bash
./scripts/04-teardown.sh                    # keep bucket
./scripts/04-teardown.sh --include-bucket   # nuke bucket too
```

### `teardown-everything.sh`

Brute-force cleanup of all `Project=cvat-mnl-test`-tagged resources.
Use when `state/infra.env` is missing or stale.

```bash
./scripts/teardown-everything.sh --confirm                     # keep buckets
./scripts/teardown-everything.sh --confirm --include-buckets   # nuke too
```

## Troubleshooting

**EC2 launches but `done.txt` never appears.** No SSH (egress-only SG).
03-collect.sh dumps console output to `results/<RUN_ID>/console.txt` on
timeout. Common causes:
- Presigned URL expired (>1 h elapsed). Rerun.
- `mtr` failed to install. Script falls back to ping/curl only and uploads
  partial results.
- Presigned URL hit the legacy global endpoint and silently 301-redirected.
  02-launch.sh forces the regional endpoint to prevent this; if you
  modify the URL generator, keep `endpoint_url=https://s3.<region>.amazonaws.com`.

**Local Zone opt-in stuck `not-opted-in`.** Re-run `00-prereqs.sh` —
propagation can take >60 s.

**`InvalidSubnet.Range` / VPC limit error.** Default VPC limit is 5. Run
`./scripts/teardown-everything.sh --confirm` to clean stale runs.

**`VolumeTypeNotAvailableInZone`.** MNL Local Zone doesn't support `gp3`.
02-launch.sh forces `gp2` — if you change the launch flags, keep that.

**`AccessDenied` on `iam:CreateRole` or `iam:PassRole`.** You shouldn't
hit this — the script doesn't create or pass roles. If you do, something
in your env is wrong; check that you ran `02-launch.sh` from this repo.
