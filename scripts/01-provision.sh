#!/usr/bin/env bash
# Provision throwaway infra for one run: VPC + subnet (in MNL Local Zone) +
# IGW + route table + security group + S3 bucket. No IAM — see 02-launch.sh.
#
# Every resource is tagged Project=cvat-mnl-test + RunId=<run> so teardown
# can find them. Each run gets a fresh RUN_ID so parallel runs can't collide.

set -euo pipefail
source "$(dirname "$0")/lib.sh"

info "phase 1 — provision throwaway infra"

RUN_ID="$(gen_run_id)"
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
: > "$STATE_DIR/infra.env"
state_set RUN_ID "$RUN_ID"
state_set REGION "$REGION"
state_set ACCOUNT_ID "$ACCOUNT_ID"
ok "RUN_ID=$RUN_ID  ACCOUNT=$ACCOUNT_ID"

# S3 bucket first: if naming/quota fails, bail before creating compute.
# 7-day lifecycle is the safety net if teardown is skipped.
BUCKET="cvat-mnl-test-${ACCOUNT_ID}-${RUN_ID}"
info "creating S3 bucket s3://$BUCKET"
aws s3api create-bucket --bucket "$BUCKET" --region "$REGION" \
  --create-bucket-configuration "LocationConstraint=$REGION" >/dev/null
aws s3api put-bucket-encryption --bucket "$BUCKET" \
  --server-side-encryption-configuration \
    '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}' >/dev/null
aws s3api put-public-access-block --bucket "$BUCKET" \
  --public-access-block-configuration \
    'BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true' >/dev/null
aws s3api put-bucket-lifecycle-configuration --bucket "$BUCKET" \
  --lifecycle-configuration '{"Rules":[{"ID":"expire-7d","Status":"Enabled","Filter":{},"Expiration":{"Days":7}}]}' >/dev/null
aws s3api put-bucket-tagging --bucket "$BUCKET" \
  --tagging "TagSet=[{Key=Project,Value=$PROJECT_TAG},{Key=RunId,Value=$RUN_ID}]" >/dev/null
state_set BUCKET "$BUCKET"
ok "bucket created"

# Dedicated VPC so we can never accidentally touch a prod-adjacent network.
info "creating VPC 10.42.0.0/16 in $REGION"
VPC_ID=$(aws ec2 create-vpc --region "$REGION" --cidr-block 10.42.0.0/16 \
  --tag-specifications "$(tag_spec vpc)" --query Vpc.VpcId --output text)
aws ec2 modify-vpc-attribute --region "$REGION" --vpc-id "$VPC_ID" --enable-dns-hostnames >/dev/null
aws ec2 modify-vpc-attribute --region "$REGION" --vpc-id "$VPC_ID" --enable-dns-support >/dev/null
state_set VPC_ID "$VPC_ID"
ok "VPC: $VPC_ID"

# IGW lives in the parent region; Local Zone subnets reach the internet
# through it via the route table below.
info "creating + attaching IGW"
IGW_ID=$(aws ec2 create-internet-gateway --region "$REGION" \
  --tag-specifications "$(tag_spec internet-gateway)" \
  --query InternetGateway.InternetGatewayId --output text)
aws ec2 attach-internet-gateway --region "$REGION" \
  --vpc-id "$VPC_ID" --internet-gateway-id "$IGW_ID" >/dev/null
state_set IGW_ID "$IGW_ID"
ok "IGW: $IGW_ID"

# Subnet must be in the MNL Local Zone — the whole point of this test.
# Auto-assign public IP so the EC2 can reach the internet without a NAT.
info "creating subnet 10.42.1.0/24 in $ZONE"
SUBNET_ID=$(aws ec2 create-subnet --region "$REGION" \
  --vpc-id "$VPC_ID" --availability-zone "$ZONE" --cidr-block 10.42.1.0/24 \
  --tag-specifications "$(tag_spec subnet)" --query Subnet.SubnetId --output text)
aws ec2 modify-subnet-attribute --region "$REGION" \
  --subnet-id "$SUBNET_ID" --map-public-ip-on-launch >/dev/null
state_set SUBNET_ID "$SUBNET_ID"
ok "subnet: $SUBNET_ID"

# Custom RT (don't touch the VPC's main RT) with default route → IGW.
info "creating route table with default route → IGW"
RT_ID=$(aws ec2 create-route-table --region "$REGION" --vpc-id "$VPC_ID" \
  --tag-specifications "$(tag_spec route-table)" --query RouteTable.RouteTableId --output text)
aws ec2 create-route --region "$REGION" --route-table-id "$RT_ID" \
  --destination-cidr-block 0.0.0.0/0 --gateway-id "$IGW_ID" >/dev/null
RTA_ID=$(aws ec2 associate-route-table --region "$REGION" \
  --subnet-id "$SUBNET_ID" --route-table-id "$RT_ID" --query AssociationId --output text)
state_set RT_ID "$RT_ID"
state_set RTA_ID "$RTA_ID"
ok "route table: $RT_ID (assoc $RTA_ID)"

# No ingress — nothing should reach this instance. AWS adds default egress
# 0.0.0.0/0 on creation, which is what we need (curl out to CVAT + S3).
info "creating security group (egress-only, no ingress)"
SG_ID=$(aws ec2 create-security-group --region "$REGION" --vpc-id "$VPC_ID" \
  --group-name "cvat-mnl-test-${RUN_ID}" \
  --description "CVAT MNL latency test ${RUN_ID}" \
  --tag-specifications "$(tag_spec security-group)" --query GroupId --output text)
state_set SG_ID "$SG_ID"
ok "SG: $SG_ID"

ok "phase 1 done. state file: $STATE_DIR/infra.env"
