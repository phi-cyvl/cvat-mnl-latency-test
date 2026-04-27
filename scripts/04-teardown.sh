#!/usr/bin/env bash
# Destroy infra in dependency-safe order. Bucket kept by default (results
# survive teardown; lifecycle expires in 7 days). --include-bucket nukes it.
#
# Order matters: instance must terminate before SG can delete; subnet must
# be empty before RT disassociates; IGW must detach before VPC deletes.

set -euo pipefail
source "$(dirname "$0")/lib.sh"

INCLUDE_BUCKET=""
for arg in "$@"; do
  case "$arg" in
    --include-bucket) INCLUDE_BUCKET=1 ;;
    *) die "unknown arg: $arg" ;;
  esac
done

info "phase 4 — teardown"
state_load
require_auth
: "${RUN_ID:?missing state — nothing to tear down here}"

aws_silent() { aws "$@" >/dev/null 2>&1 || true; }

# Terminate instance first; SG delete fails while ENIs still attached.
if [[ -n "${INSTANCE_ID:-}" ]]; then
  state=$(aws ec2 describe-instances --region "$REGION" \
    --instance-ids "$INSTANCE_ID" \
    --query 'Reservations[0].Instances[0].State.Name' \
    --output text 2>/dev/null || echo missing)
  if [[ "$state" == "terminated" || "$state" == "missing" ]]; then
    ok "instance $INSTANCE_ID already $state"
  else
    info "terminating instance $INSTANCE_ID"
    aws_silent ec2 terminate-instances --region "$REGION" --instance-ids "$INSTANCE_ID"
    log "waiting for terminated state..."
    aws ec2 wait instance-terminated --region "$REGION" --instance-ids "$INSTANCE_ID"
    ok "terminated"
  fi
fi

if [[ -n "${SG_ID:-}" ]]; then
  info "deleting SG $SG_ID"
  aws_silent ec2 delete-security-group --region "$REGION" --group-id "$SG_ID"
  ok "SG gone"
fi

if [[ -n "${RTA_ID:-}" ]]; then
  info "disassociating route table"
  aws_silent ec2 disassociate-route-table --region "$REGION" --association-id "$RTA_ID"
fi
if [[ -n "${RT_ID:-}" ]]; then
  info "deleting route table $RT_ID"
  aws_silent ec2 delete-route-table --region "$REGION" --route-table-id "$RT_ID"
  ok "route table gone"
fi

if [[ -n "${SUBNET_ID:-}" ]]; then
  info "deleting subnet $SUBNET_ID"
  aws_silent ec2 delete-subnet --region "$REGION" --subnet-id "$SUBNET_ID"
  ok "subnet gone"
fi

if [[ -n "${IGW_ID:-}" && -n "${VPC_ID:-}" ]]; then
  info "detaching + deleting IGW $IGW_ID"
  aws_silent ec2 detach-internet-gateway --region "$REGION" \
    --internet-gateway-id "$IGW_ID" --vpc-id "$VPC_ID"
  aws_silent ec2 delete-internet-gateway --region "$REGION" --internet-gateway-id "$IGW_ID"
  ok "IGW gone"
fi

if [[ -n "${VPC_ID:-}" ]]; then
  info "deleting VPC $VPC_ID"
  aws_silent ec2 delete-vpc --region "$REGION" --vpc-id "$VPC_ID"
  ok "VPC gone"
fi

if [[ -n "${BUCKET:-}" && -n "$INCLUDE_BUCKET" ]]; then
  info "emptying + deleting bucket $BUCKET"
  aws_silent s3 rm "s3://$BUCKET" --recursive
  aws_silent s3api delete-bucket --bucket "$BUCKET" --region "$REGION"
  ok "bucket gone"
elif [[ -n "${BUCKET:-}" ]]; then
  log "keeping s3://$BUCKET (lifecycle expires in 7 days). --include-bucket to nuke now."
fi

# Archive (don't delete) state — useful for re-collect or audit.
if [[ -f "$STATE_DIR/infra.env" ]]; then
  mv "$STATE_DIR/infra.env" "$STATE_DIR/infra-${RUN_ID}.env.archived"
  ok "state archived → state/infra-${RUN_ID}.env.archived"
fi

ok "teardown complete"
