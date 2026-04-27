#!/usr/bin/env bash
# teardown-everything.sh — brute-force cleanup of every resource tagged
# `Project=cvat-mnl-test`, regardless of RunId.
#
# Use when something crashed mid-run and state/infra.env is gone or stale.
# Requires --confirm to actually do anything (so it can't be triggered
# accidentally).

set -euo pipefail
source "$(dirname "$0")/lib.sh"

if [[ "${1:-}" != "--confirm" ]]; then
  cat <<'EOF'
Usage: teardown-everything.sh --confirm

This will destroy ALL AWS resources tagged Project=cvat-mnl-test in the
current account and the configured region. It will NOT touch S3 buckets
unless you also pass --include-buckets.

EOF
  exit 1
fi

INCLUDE_BUCKETS=""
[[ "${2:-}" == "--include-buckets" ]] && INCLUDE_BUCKETS=1

require_auth
warn "scanning for cvat-mnl-test resources in $REGION..."

# Use Resource Groups Tagging API for a single tag query across services.
ARNS=$(aws resourcegroupstaggingapi get-resources \
  --region "$REGION" \
  --tag-filters "Key=Project,Values=$PROJECT_TAG" \
  --query 'ResourceTagMappingList[].ResourceARN' \
  --output text 2>/dev/null || true)

if [[ -z "$ARNS" ]]; then
  ok "nothing tagged Project=$PROJECT_TAG found"
else
  echo "  Resources to destroy:"
  for arn in $ARNS; do echo "    $arn"; done
  echo
fi

# Walk in dependency-safe order. Pull each resource type by tag.
filter="Name=tag:Project,Values=$PROJECT_TAG"
silent() { aws "$@" >/dev/null 2>&1 || true; }

# Instances
for id in $(aws ec2 describe-instances --region "$REGION" \
  --filters "$filter" "Name=instance-state-name,Values=pending,running,stopping,stopped" \
  --query 'Reservations[].Instances[].InstanceId' --output text); do
  info "terminating $id"
  silent ec2 terminate-instances --region "$REGION" --instance-ids "$id"
done

# Wait for them all
for id in $(aws ec2 describe-instances --region "$REGION" \
  --filters "$filter" \
  --query 'Reservations[].Instances[].InstanceId' --output text); do
  aws ec2 wait instance-terminated --region "$REGION" --instance-ids "$id" 2>/dev/null || true
done

# Instance profiles + roles (no tag filter API for these via tagging API in older accounts;
# best-effort by name prefix)
for prof in $(aws iam list-instance-profiles \
  --query "InstanceProfiles[?starts_with(InstanceProfileName,'cvat-mnl-test-profile-')].InstanceProfileName" \
  --output text); do
  for role in $(aws iam get-instance-profile --instance-profile-name "$prof" \
    --query 'InstanceProfile.Roles[].RoleName' --output text); do
    info "removing role $role from profile $prof"
    silent iam remove-role-from-instance-profile --instance-profile-name "$prof" --role-name "$role"
  done
  silent iam delete-instance-profile --instance-profile-name "$prof"
done
for role in $(aws iam list-roles \
  --query "Roles[?starts_with(RoleName,'cvat-mnl-test-role-')].RoleName" \
  --output text); do
  info "deleting role $role"
  for p in $(aws iam list-role-policies --role-name "$role" --query 'PolicyNames' --output text); do
    silent iam delete-role-policy --role-name "$role" --policy-name "$p"
  done
  silent iam delete-role --role-name "$role"
done

# Security groups
for id in $(aws ec2 describe-security-groups --region "$REGION" \
  --filters "$filter" --query 'SecurityGroups[].GroupId' --output text); do
  info "deleting SG $id"
  silent ec2 delete-security-group --region "$REGION" --group-id "$id"
done

# Route tables — disassociate first, then delete (skip main RTs)
for id in $(aws ec2 describe-route-tables --region "$REGION" \
  --filters "$filter" --query 'RouteTables[].RouteTableId' --output text); do
  for assoc in $(aws ec2 describe-route-tables --region "$REGION" \
    --route-table-ids "$id" \
    --query 'RouteTables[0].Associations[?Main==`false`].RouteTableAssociationId' \
    --output text); do
    silent ec2 disassociate-route-table --region "$REGION" --association-id "$assoc"
  done
  info "deleting RT $id"
  silent ec2 delete-route-table --region "$REGION" --route-table-id "$id"
done

# Subnets
for id in $(aws ec2 describe-subnets --region "$REGION" \
  --filters "$filter" --query 'Subnets[].SubnetId' --output text); do
  info "deleting subnet $id"
  silent ec2 delete-subnet --region "$REGION" --subnet-id "$id"
done

# IGWs (must detach from VPC first)
for id in $(aws ec2 describe-internet-gateways --region "$REGION" \
  --filters "$filter" --query 'InternetGateways[].InternetGatewayId' --output text); do
  for vpc in $(aws ec2 describe-internet-gateways --region "$REGION" \
    --internet-gateway-ids "$id" \
    --query 'InternetGateways[0].Attachments[].VpcId' --output text); do
    silent ec2 detach-internet-gateway --region "$REGION" \
      --internet-gateway-id "$id" --vpc-id "$vpc"
  done
  info "deleting IGW $id"
  silent ec2 delete-internet-gateway --region "$REGION" --internet-gateway-id "$id"
done

# VPCs
for id in $(aws ec2 describe-vpcs --region "$REGION" \
  --filters "$filter" --query 'Vpcs[].VpcId' --output text); do
  info "deleting VPC $id"
  silent ec2 delete-vpc --region "$REGION" --vpc-id "$id"
done

# S3 buckets — only with --include-buckets
if [[ -n "$INCLUDE_BUCKETS" ]]; then
  for b in $(aws s3api list-buckets --query "Buckets[?starts_with(Name,'cvat-mnl-test-')].Name" --output text); do
    info "deleting bucket s3://$b"
    silent s3 rm "s3://$b" --recursive
    silent s3api delete-bucket --bucket "$b" --region "$REGION"
  done
else
  log "skipping S3 buckets (use --include-buckets to nuke them too)"
fi

ok "brute-force teardown complete"
