# Runbook

Step-by-step operator guide.

## Prereqs

- AWS SSO authenticated with EC2 + VPC + S3 + IAM permissions in `ap-southeast-1`:
  ```bash
  aws sso login
  aws sts get-caller-identity   # confirms identity
  ```
- `aws` CLI v2, `jq`, `curl`, `bash` 4+.
- Required env vars:
  ```bash
  export CVAT_TARGET=cvat.example.com   # your CVAT hostname, no https://
  export CVAT_JOB_ID=12345              # valid job ID for chunk probing
  ```

## End-to-end run

```bash
./run.sh
```

Runs phases 00 → 04 in order, prompting before teardown so you can inspect
the results. Set `NO_TEARDOWN=1` to skip the prompt.

## Per-phase

### `00-prereqs.sh`

Idempotent. Verifies auth and opts in the MNL Local Zone. Opt-in is
account-level and persists.

```bash
./scripts/00-prereqs.sh
```

What it does:
1. `aws sts get-caller-identity` — bail if expired.
2. Reads `ap-southeast-1-mnl-1a` opt-in status.
3. If `not-opted-in`, calls `modify-availability-zone-group` and polls until ready (~30 s).

### `01-provision.sh`

Creates throwaway infrastructure for one run. Each invocation gets a fresh
`RUN_ID` (timestamp) and tags every resource with `Project=cvat-mnl-test,
RunId=<RUN_ID>`. Saves IDs to `state/infra.env`.

```bash
./scripts/01-provision.sh
```

Resources created:
- VPC `10.42.0.0/16`
- Internet Gateway, attached
- Subnet `10.42.1.0/24` in `ap-southeast-1-mnl-1a`, auto-assign public IP
- Route table with default route → IGW
- Security Group — egress 0.0.0.0/0, no ingress
- S3 bucket with SSE-S3 + 7-day lifecycle expiration
- IAM role with inline policy granting `s3:PutObject` to the results bucket only
- Instance profile wrapping the role

### `02-launch.sh`

Launches t3.medium in the MNL subnet with the test script as user-data.
The instance runs the test, uploads results to S3, and terminates itself.

```bash
./scripts/02-launch.sh
```

What it does:
1. Looks up the latest Amazon Linux 2023 AMI in `ap-southeast-1`.
2. Renders `userdata/test.sh` substituting `__BUCKET__`, `__RUN_ID__`,
   `__TARGET__`, `__JOB_ID__`.
3. Launches with `--instance-initiated-shutdown-behavior terminate` so
   `shutdown -h now` inside the test also terminates the instance.

### `03-collect.sh`

Polls S3 for the `done.txt` marker (written by the test script at the end).
Up to 10 min wait, 15 s poll interval. Downloads the bundle and prints a summary.

```bash
./scripts/03-collect.sh
```

Summary: geo confirmation, median ping RTT, mtr final-hop, TLS handshake
P50/P95, chunk fetch timings.

### `04-teardown.sh`

Destroys infra in dependency-safe order. Keeps the S3 results bucket by default.

```bash
./scripts/04-teardown.sh                    # keep bucket
./scripts/04-teardown.sh --include-bucket   # nuke bucket too
```

### `teardown-everything.sh`

Brute-force cleanup — finds and destroys every resource tagged
`Project=cvat-mnl-test`, regardless of run ID. Use when state is lost.

```bash
./scripts/teardown-everything.sh --confirm
```

## Troubleshooting

### EC2 launches but never writes to S3

SSH isn't available (no inbound rules). Debug via console output:

```bash
aws ec2 get-console-output --region ap-southeast-1 \
  --instance-id <INSTANCE_ID> --query Output --output text
```

Common causes:
- IAM role propagation race — wait 30 s and retry.
- `mtr` package missing — the script falls back to ping/curl only and still uploads.

### "InvalidSubnet.Range" or VPC limit error

Default VPC limit is 5. Clean up old runs with `teardown-everything.sh --confirm`.

### Local Zone opt-in not propagating

Re-run `00-prereqs.sh` — it's idempotent. Propagation typically takes < 60 s.
