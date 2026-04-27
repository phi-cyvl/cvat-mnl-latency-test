#!/usr/bin/env bash
# Launch a t3.medium in the MNL subnet with the test script as user-data.
# The instance runs the test, uploads results via presigned S3 URLs, and
# self-terminates (the launch flag turns `shutdown -h now` into terminate).
#
# Why presigned URLs instead of an instance IAM role: this script's caller
# typically lacks iam:CreateRole / iam:PassRole. Presigned URLs are signed
# locally with the caller's existing credentials — no IAM permissions
# needed on the instance. 1-hour expiry is far longer than the ~5 min test.

set -euo pipefail
source "$(dirname "$0")/lib.sh"

info "phase 2 — launch test EC2"

state_load
require_auth

: "${CVAT_TARGET:?Set CVAT_TARGET to your CVAT hostname (e.g. export CVAT_TARGET=cvat.example.com)}"
: "${CVAT_JOB_ID:?Set CVAT_JOB_ID to a valid CVAT job ID (e.g. export CVAT_JOB_ID=12345)}"
: "${RUN_ID:?missing RUN_ID — re-run 01-provision.sh}"
: "${SUBNET_ID:?missing SUBNET_ID — re-run 01-provision.sh}"
: "${SG_ID:?}"
: "${BUCKET:?}"

# AL2023 — has dnf, openssl 3, recent curl, python in default repos.
info "looking up latest AL2023 x86_64 AMI in $REGION"
AMI_ID=$(aws ec2 describe-images --region "$REGION" --owners amazon \
  --filters \
    'Name=name,Values=al2023-ami-2023.*-x86_64' \
    'Name=state,Values=available' \
    'Name=architecture,Values=x86_64' \
    'Name=virtualization-type,Values=hvm' \
  --query 'Images | sort_by(@,&CreationDate) | [-1].ImageId' --output text)
[[ -n "$AMI_ID" && "$AMI_ID" != "None" ]] || die "no AL2023 AMI found"
state_set AMI_ID "$AMI_ID"
ok "AMI: $AMI_ID"

# AWS CLI has no built-in PUT-presign — boto3 (already a dep of awscli) does.
# Force the regional path-style endpoint: boto3's default virtual-hosted URL
# (`bucket.s3.amazonaws.com`) returns a 301 to the regional endpoint, and
# curl --upload-file doesn't follow PUT redirects → silent upload failure.
info "generating presigned S3 PUT URLs (1-hour expiry)"
gen_presigned_put() {
  python3 - "$BUCKET" "$1" "$REGION" <<'PY'
import sys, boto3
from botocore.config import Config
bucket, key, region = sys.argv[1], sys.argv[2], sys.argv[3]
s3 = boto3.client("s3", region_name=region,
    endpoint_url=f"https://s3.{region}.amazonaws.com",
    config=Config(signature_version="s3v4"))
print(s3.generate_presigned_url("put_object",
    Params={"Bucket": bucket, "Key": key}, ExpiresIn=3600, HttpMethod="PUT"))
PY
}
RESULTS_URL=$(gen_presigned_put "$RUN_ID/results.tgz")
LOG_URL=$(gen_presigned_put "$RUN_ID/test.log")
DONE_URL=$(gen_presigned_put "$RUN_ID/done.txt")
[[ -n "$RESULTS_URL" && -n "$LOG_URL" && -n "$DONE_URL" ]] || die "presigned URL gen failed"
ok "presigned URLs ready"

# Render user-data via Python (sed `s|...|...|` would break on `|` in URLs).
USERDATA_SRC="$PROJECT_ROOT/userdata/test.sh"
USERDATA_FILE="$STATE_DIR/userdata-${RUN_ID}.sh"
python3 - "$USERDATA_SRC" "$USERDATA_FILE" \
  "__RUN_ID__"      "$RUN_ID" \
  "__TARGET__"      "$CVAT_TARGET" \
  "__JOB_ID__"      "$CVAT_JOB_ID" \
  "__RESULTS_URL__" "$RESULTS_URL" \
  "__LOG_URL__"     "$LOG_URL" \
  "__DONE_URL__"    "$DONE_URL" <<'PY'
import sys
src, dst, *kvs = sys.argv[1:]
text = open(src).read()
for i in range(0, len(kvs), 2):
    text = text.replace(kvs[i], kvs[i+1])
open(dst, "w").write(text)
PY
ok "user-data rendered → $(basename "$USERDATA_FILE")"

# MNL Local Zone doesn't support gp3 (the AL2023 default). Override to gp2.
# IMDSv2 required — instance has no role, but blocking IMDSv1 is still hygiene.
# instance-initiated-shutdown=terminate so the test's `shutdown` ends billing.
info "launching t3.medium in $ZONE"
INSTANCE_ID=$(aws ec2 run-instances --region "$REGION" \
  --image-id "$AMI_ID" --instance-type t3.medium \
  --subnet-id "$SUBNET_ID" --security-group-ids "$SG_ID" \
  --instance-initiated-shutdown-behavior terminate \
  --user-data "file://$USERDATA_FILE" \
  --metadata-options 'HttpTokens=required,HttpEndpoint=enabled' \
  --block-device-mappings 'DeviceName=/dev/xvda,Ebs={VolumeSize=8,VolumeType=gp2,DeleteOnTermination=true}' \
  --tag-specifications "$(tag_spec instance)" \
  --query 'Instances[0].InstanceId' --output text)
state_set INSTANCE_ID "$INSTANCE_ID"
ok "launched: $INSTANCE_ID"

log "waiting for instance to be running..."
aws ec2 wait instance-running --region "$REGION" --instance-ids "$INSTANCE_ID"
PUBLIC_IP=$(aws ec2 describe-instances --region "$REGION" \
  --instance-ids "$INSTANCE_ID" \
  --query 'Reservations[0].Instances[0].PublicIpAddress' --output text)
state_set PUBLIC_IP "$PUBLIC_IP"
ok "instance running. public IP: $PUBLIC_IP"
