#!/usr/bin/env bash
# 02-launch.sh — launch the EC2 in MNL with the test script as user-data.
#
# Why this exists:
#   The cleanest EC2 reproduction is "boot, run script, ship results,
#   self-destruct". This script (a) substitutes our bucket + run-id into
#   the user-data, (b) launches with `instance-initiated-shutdown-behavior
#   terminate` so `shutdown` from inside the test ends + bills out the
#   instance, and (c) records the instance ID for collection / teardown.
#
# Instance type choice:
#   t3.medium is general-purpose, available in MNL Local Zone, and gives
#   us 2 vCPU + 4 GiB which is more than enough for curl/mtr/jq.

set -euo pipefail
source "$(dirname "$0")/lib.sh"

info "phase 2 — launch test EC2"

state_load
require_auth

: "${CVAT_TARGET:?Set CVAT_TARGET to your CVAT hostname (e.g. export CVAT_TARGET=cvat.example.com)}"
: "${CVAT_JOB_ID:?Set CVAT_JOB_ID to a valid CVAT job ID (e.g. export CVAT_JOB_ID=12345)}"

# Sanity check the loaded state
: "${RUN_ID:?missing RUN_ID — re-run 01-provision.sh}"
: "${SUBNET_ID:?missing SUBNET_ID — re-run 01-provision.sh}"
: "${SG_ID:?}"
: "${PROFILE_NAME:?}"
: "${BUCKET:?}"

# ---- AMI lookup ------------------------------------------------------------
# Latest Amazon Linux 2023 x86_64 in this region. AL2023 has dnf, openssl 3,
# Python 3.9+, and recent curl — everything we need in default repos.
info "looking up latest AL2023 x86_64 AMI in $REGION"
AMI_ID=$(aws ec2 describe-images \
  --region "$REGION" \
  --owners amazon \
  --filters \
    'Name=name,Values=al2023-ami-2023.*-x86_64' \
    'Name=state,Values=available' \
    'Name=architecture,Values=x86_64' \
    'Name=virtualization-type,Values=hvm' \
  --query 'Images | sort_by(@,&CreationDate) | [-1].ImageId' \
  --output text)
[[ -n "$AMI_ID" && "$AMI_ID" != "None" ]] || die "no AL2023 AMI found"
state_set AMI_ID "$AMI_ID"
ok "AMI: $AMI_ID"

# ---- render user-data ------------------------------------------------------
# Substitute run-time values into the user-data template.
USERDATA_SRC="$PROJECT_ROOT/userdata/test.sh"
USERDATA_FILE="$STATE_DIR/userdata-${RUN_ID}.sh"
sed -e "s|__BUCKET__|$BUCKET|g" \
    -e "s|__RUN_ID__|$RUN_ID|g" \
    -e "s|__TARGET__|$CVAT_TARGET|g" \
    -e "s|__JOB_ID__|$CVAT_JOB_ID|g" \
    "$USERDATA_SRC" > "$USERDATA_FILE"
ok "user-data rendered → $(basename "$USERDATA_FILE")"

# ---- launch ----------------------------------------------------------------
info "launching t3.medium in $ZONE"
INSTANCE_ID=$(aws ec2 run-instances \
  --region "$REGION" \
  --image-id "$AMI_ID" \
  --instance-type t3.medium \
  --subnet-id "$SUBNET_ID" \
  --security-group-ids "$SG_ID" \
  --iam-instance-profile "Name=$PROFILE_NAME" \
  --instance-initiated-shutdown-behavior terminate \
  --user-data "file://$USERDATA_FILE" \
  --metadata-options 'HttpTokens=required,HttpEndpoint=enabled' \
  --tag-specifications "$(tag_spec instance)" \
  --query 'Instances[0].InstanceId' \
  --output text)
state_set INSTANCE_ID "$INSTANCE_ID"
ok "launched: $INSTANCE_ID"

log "waiting for instance to be running..."
aws ec2 wait instance-running --region "$REGION" --instance-ids "$INSTANCE_ID"

PUBLIC_IP=$(aws ec2 describe-instances --region "$REGION" \
  --instance-ids "$INSTANCE_ID" \
  --query 'Reservations[0].Instances[0].PublicIpAddress' \
  --output text)
state_set PUBLIC_IP "$PUBLIC_IP"
ok "instance running. public IP: $PUBLIC_IP"

cat <<EOF

  Instance is running. The user-data test script will:
    1. install mtr/jq
    2. measure ping/mtr/curl/chunk timings
    3. upload results.tgz to s3://$BUCKET/$RUN_ID/
    4. write a done.txt marker
    5. shutdown -h now (which terminates due to launch flag)

  Expected wall time: ~3-5 min from now.

  Next: ./scripts/03-collect.sh

EOF
