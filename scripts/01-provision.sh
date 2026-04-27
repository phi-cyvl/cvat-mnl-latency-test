#!/usr/bin/env bash
# 01-provision.sh — create the throwaway infra needed to run one test.
#
# Why this exists:
#   The MNL Local Zone has no default VPC subnets. We need our own
#   VPC + subnet + IGW + route table + SG. We also need an S3 bucket
#   to receive the results bundle from the EC2 (cleanest exfil; no SSH
#   needed, no console-output size limits) and an IAM role that grants
#   the EC2 just enough to write to that bucket.
#
#   Everything is created with `RunId` and `Project=cvat-mnl-test` tags
#   so teardown can find/destroy it. Each run gets a fresh RUN_ID so
#   parallel runs don't collide.
#
# Idempotency: this script writes new resources every time. Running it
# twice creates two separate sets of infra (with different RUN_IDs).
# Use 04-teardown.sh between runs.

set -euo pipefail
source "$(dirname "$0")/lib.sh"

info "phase 1 — provision throwaway infra"

# Fresh state file for this run.
RUN_ID="$(gen_run_id)"
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
: > "$STATE_DIR/infra.env"
state_set RUN_ID "$RUN_ID"
state_set REGION "$REGION"
state_set ACCOUNT_ID "$ACCOUNT_ID"
ok "RUN_ID=$RUN_ID  ACCOUNT=$ACCOUNT_ID"

# ---- S3 results bucket ------------------------------------------------------
# Why first: if this fails (e.g. quota, naming collision) we want to bail
# before creating any compute infra.
BUCKET="cvat-mnl-test-${ACCOUNT_ID}-${RUN_ID}"
info "creating S3 bucket s3://$BUCKET"
aws s3api create-bucket \
  --bucket "$BUCKET" \
  --region "$REGION" \
  --create-bucket-configuration "LocationConstraint=$REGION" >/dev/null
aws s3api put-bucket-encryption \
  --bucket "$BUCKET" \
  --server-side-encryption-configuration \
    '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}' >/dev/null
aws s3api put-public-access-block \
  --bucket "$BUCKET" \
  --public-access-block-configuration \
    'BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true' >/dev/null
aws s3api put-bucket-lifecycle-configuration \
  --bucket "$BUCKET" \
  --lifecycle-configuration '{"Rules":[{"ID":"expire-7d","Status":"Enabled","Filter":{},"Expiration":{"Days":7}}]}' >/dev/null
aws s3api put-bucket-tagging --bucket "$BUCKET" \
  --tagging "TagSet=[{Key=Project,Value=$PROJECT_TAG},{Key=RunId,Value=$RUN_ID}]" >/dev/null
state_set BUCKET "$BUCKET"
ok "bucket created"

# ---- VPC --------------------------------------------------------------------
info "creating VPC 10.42.0.0/16 in $REGION"
VPC_ID=$(aws ec2 create-vpc \
  --region "$REGION" \
  --cidr-block 10.42.0.0/16 \
  --tag-specifications "$(tag_spec vpc)" \
  --query Vpc.VpcId --output text)
aws ec2 modify-vpc-attribute --region "$REGION" --vpc-id "$VPC_ID" --enable-dns-hostnames >/dev/null
aws ec2 modify-vpc-attribute --region "$REGION" --vpc-id "$VPC_ID" --enable-dns-support >/dev/null
state_set VPC_ID "$VPC_ID"
ok "VPC: $VPC_ID"

# ---- Internet Gateway -------------------------------------------------------
info "creating + attaching IGW"
IGW_ID=$(aws ec2 create-internet-gateway \
  --region "$REGION" \
  --tag-specifications "$(tag_spec internet-gateway)" \
  --query InternetGateway.InternetGatewayId --output text)
aws ec2 attach-internet-gateway --region "$REGION" \
  --vpc-id "$VPC_ID" --internet-gateway-id "$IGW_ID" >/dev/null
state_set IGW_ID "$IGW_ID"
ok "IGW: $IGW_ID"

# ---- Subnet in MNL Local Zone ----------------------------------------------
info "creating subnet 10.42.1.0/24 in $ZONE"
SUBNET_ID=$(aws ec2 create-subnet \
  --region "$REGION" \
  --vpc-id "$VPC_ID" \
  --availability-zone "$ZONE" \
  --cidr-block 10.42.1.0/24 \
  --tag-specifications "$(tag_spec subnet)" \
  --query Subnet.SubnetId --output text)
aws ec2 modify-subnet-attribute --region "$REGION" \
  --subnet-id "$SUBNET_ID" --map-public-ip-on-launch >/dev/null
state_set SUBNET_ID "$SUBNET_ID"
ok "subnet: $SUBNET_ID"

# ---- Route table ------------------------------------------------------------
# Local Zone subnets can reach the public internet via an IGW, but the
# IGW must be in the parent region's VPC (which it is here). We create a
# new route table so we don't touch the VPC's main RT.
info "creating route table with default route → IGW"
RT_ID=$(aws ec2 create-route-table \
  --region "$REGION" \
  --vpc-id "$VPC_ID" \
  --tag-specifications "$(tag_spec route-table)" \
  --query RouteTable.RouteTableId --output text)
aws ec2 create-route --region "$REGION" \
  --route-table-id "$RT_ID" \
  --destination-cidr-block 0.0.0.0/0 \
  --gateway-id "$IGW_ID" >/dev/null
RTA_ID=$(aws ec2 associate-route-table --region "$REGION" \
  --subnet-id "$SUBNET_ID" --route-table-id "$RT_ID" \
  --query AssociationId --output text)
state_set RT_ID "$RT_ID"
state_set RTA_ID "$RTA_ID"
ok "route table: $RT_ID (assoc $RTA_ID)"

# ---- Security group ---------------------------------------------------------
# No inbound rules (no SSH, no anything). The instance reaches out to S3
# and to the CVAT host; AWS SDK + curl initiate, so egress-only is fine.
info "creating security group (egress-only, no ingress)"
SG_ID=$(aws ec2 create-security-group \
  --region "$REGION" \
  --vpc-id "$VPC_ID" \
  --group-name "cvat-mnl-test-${RUN_ID}" \
  --description "CVAT MNL latency test ${RUN_ID}" \
  --tag-specifications "$(tag_spec security-group)" \
  --query GroupId --output text)
# Note: AWS adds a default egress 0.0.0.0/0 rule on creation. Nothing to add.
# Strip the default egress and re-add just what we need? Not worth it for a
# one-shot test. Leave egress-all-open.
state_set SG_ID "$SG_ID"
ok "SG: $SG_ID"

# ---- IAM role + instance profile -------------------------------------------
# Minimal role that lets the EC2 PutObject only into the results bucket.
# No SSM, no broad S3, no Secrets Manager — least-privilege.
ROLE_NAME="cvat-mnl-test-role-${RUN_ID}"
PROFILE_NAME="cvat-mnl-test-profile-${RUN_ID}"

info "creating IAM role $ROLE_NAME"
TRUST_POLICY='{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"ec2.amazonaws.com"},"Action":"sts:AssumeRole"}]}'
aws iam create-role \
  --role-name "$ROLE_NAME" \
  --assume-role-policy-document "$TRUST_POLICY" \
  --tags "Key=Project,Value=$PROJECT_TAG" "Key=RunId,Value=$RUN_ID" >/dev/null

aws iam put-role-policy \
  --role-name "$ROLE_NAME" \
  --policy-name s3-write-results \
  --policy-document "$(cat <<EOF
{"Version":"2012-10-17","Statement":[
  {"Effect":"Allow","Action":["s3:PutObject","s3:PutObjectAcl"],"Resource":"arn:aws:s3:::${BUCKET}/*"},
  {"Effect":"Allow","Action":["s3:ListBucket"],"Resource":"arn:aws:s3:::${BUCKET}"}
]}
EOF
)" >/dev/null

aws iam create-instance-profile --instance-profile-name "$PROFILE_NAME" >/dev/null
aws iam add-role-to-instance-profile \
  --instance-profile-name "$PROFILE_NAME" \
  --role-name "$ROLE_NAME" >/dev/null

state_set ROLE_NAME "$ROLE_NAME"
state_set PROFILE_NAME "$PROFILE_NAME"
ok "IAM role + instance profile created"

# IAM is eventually consistent; instance profile must be queryable before
# we can launch with it. Poll briefly so 02-launch.sh doesn't race.
log "waiting for instance profile to be visible..."
for _ in $(seq 1 20); do
  if aws iam get-instance-profile --instance-profile-name "$PROFILE_NAME" >/dev/null 2>&1; then
    break
  fi
  sleep 1
done

ok "phase 1 done. state file: $STATE_DIR/infra.env"
cat "$STATE_DIR/infra.env" | sed 's/^/    /'
