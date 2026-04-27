#!/usr/bin/env bash
# 04-teardown.sh — destroy infrastructure for one run.
#
# Order matters because AWS dependencies block deletion:
#   instance must terminate before SG can delete
#   subnet must be empty before route table can disassociate cleanly
#   IGW must detach before VPC can delete
#   role must be removed from instance profile before either deletes
#
# Default keeps the S3 results bucket so you can re-pull the data even
# after teardown. Pass --include-bucket to also nuke S3.

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

# ---- 1. terminate instance --------------------------------------------------
if [[ -n "${INSTANCE_ID:-}" ]]; then
  state=$(aws ec2 describe-instances --region "$REGION" \
    --instance-ids "$INSTANCE_ID" \
    --query 'Reservations[0].Instances[0].State.Name' \
    --output text 2>/dev/null || echo missing)
  case "$state" in
    terminated|missing)
      ok "instance $INSTANCE_ID already $state"
      ;;
    *)
      info "terminating instance $INSTANCE_ID"
      aws_silent ec2 terminate-instances --region "$REGION" --instance-ids "$INSTANCE_ID"
      log "waiting for terminated state..."
      aws ec2 wait instance-terminated --region "$REGION" --instance-ids "$INSTANCE_ID"
      ok "terminated"
      ;;
  esac
fi

# ---- 2. instance profile + role --------------------------------------------
if [[ -n "${PROFILE_NAME:-}" ]]; then
  info "removing IAM instance profile $PROFILE_NAME"
  aws_silent iam remove-role-from-instance-profile \
    --instance-profile-name "$PROFILE_NAME" --role-name "$ROLE_NAME"
  aws_silent iam delete-instance-profile --instance-profile-name "$PROFILE_NAME"
  ok "instance profile gone"
fi
if [[ -n "${ROLE_NAME:-}" ]]; then
  info "removing IAM role $ROLE_NAME"
  aws_silent iam delete-role-policy --role-name "$ROLE_NAME" --policy-name s3-write-results
  aws_silent iam delete-role --role-name "$ROLE_NAME"
  ok "role gone"
fi

# ---- 3. security group ------------------------------------------------------
if [[ -n "${SG_ID:-}" ]]; then
  info "deleting SG $SG_ID"
  aws_silent ec2 delete-security-group --region "$REGION" --group-id "$SG_ID"
  ok "SG gone"
fi

# ---- 4. route table ---------------------------------------------------------
if [[ -n "${RTA_ID:-}" ]]; then
  info "disassociating route table"
  aws_silent ec2 disassociate-route-table --region "$REGION" --association-id "$RTA_ID"
fi
if [[ -n "${RT_ID:-}" ]]; then
  info "deleting route table $RT_ID"
  aws_silent ec2 delete-route-table --region "$REGION" --route-table-id "$RT_ID"
  ok "route table gone"
fi

# ---- 5. subnet --------------------------------------------------------------
if [[ -n "${SUBNET_ID:-}" ]]; then
  info "deleting subnet $SUBNET_ID"
  aws_silent ec2 delete-subnet --region "$REGION" --subnet-id "$SUBNET_ID"
  ok "subnet gone"
fi

# ---- 6. IGW -----------------------------------------------------------------
if [[ -n "${IGW_ID:-}" && -n "${VPC_ID:-}" ]]; then
  info "detaching + deleting IGW $IGW_ID"
  aws_silent ec2 detach-internet-gateway --region "$REGION" \
    --internet-gateway-id "$IGW_ID" --vpc-id "$VPC_ID"
  aws_silent ec2 delete-internet-gateway --region "$REGION" \
    --internet-gateway-id "$IGW_ID"
  ok "IGW gone"
fi

# ---- 7. VPC -----------------------------------------------------------------
if [[ -n "${VPC_ID:-}" ]]; then
  info "deleting VPC $VPC_ID"
  aws_silent ec2 delete-vpc --region "$REGION" --vpc-id "$VPC_ID"
  ok "VPC gone"
fi

# ---- 8. S3 (optional) ------------------------------------------------------
if [[ -n "${BUCKET:-}" ]]; then
  if [[ -n "$INCLUDE_BUCKET" ]]; then
    info "emptying + deleting bucket $BUCKET"
    aws_silent s3 rm "s3://$BUCKET" --recursive
    aws_silent s3api delete-bucket --bucket "$BUCKET" --region "$REGION"
    ok "bucket gone"
  else
    log "keeping s3://$BUCKET (lifecycle expires in 7 days). --include-bucket to nuke now."
  fi
fi

# Archive the state file rather than delete — useful for audit / re-collect.
if [[ -f "$STATE_DIR/infra.env" ]]; then
  mv "$STATE_DIR/infra.env" "$STATE_DIR/infra-${RUN_ID}.env.archived"
  ok "state archived → state/infra-${RUN_ID}.env.archived"
fi

ok "teardown complete"
