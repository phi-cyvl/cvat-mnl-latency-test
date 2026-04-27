#!/usr/bin/env bash
# Brute-force cleanup of every resource tagged Project=cvat-mnl-test,
# regardless of RunId. Use when state/infra.env is gone or stale and
# 04-teardown.sh can't find what to delete.
#
# Requires --confirm so it can't fire accidentally. S3 buckets are kept
# unless --include-buckets is also passed.

set -euo pipefail
source "$(dirname "$0")/lib.sh"

if [[ "${1:-}" != "--confirm" ]]; then
  cat <<'EOF'
Usage: teardown-everything.sh --confirm [--include-buckets]

Destroys ALL AWS resources tagged Project=cvat-mnl-test in the current
account and region. Buckets kept unless --include-buckets is passed.
EOF
  exit 1
fi

INCLUDE_BUCKETS=""
[[ "${2:-}" == "--include-buckets" ]] && INCLUDE_BUCKETS=1

require_auth
warn "scanning for cvat-mnl-test resources in $REGION..."

# Resource Groups Tagging API gives a single cross-service inventory.
ARNS=$(aws resourcegroupstaggingapi get-resources --region "$REGION" \
  --tag-filters "Key=Project,Values=$PROJECT_TAG" \
  --query 'ResourceTagMappingList[].ResourceARN' --output text 2>/dev/null || true)

if [[ -z "$ARNS" ]]; then
  ok "nothing tagged Project=$PROJECT_TAG found"
else
  echo "  Resources to destroy:"
  for arn in $ARNS; do echo "    $arn"; done
  echo
fi

filter="Name=tag:Project,Values=$PROJECT_TAG"
silent() { aws "$@" >/dev/null 2>&1 || true; }

# Walk in dependency-safe order — same as 04-teardown.sh.
for id in $(aws ec2 describe-instances --region "$REGION" \
  --filters "$filter" "Name=instance-state-name,Values=pending,running,stopping,stopped" \
  --query 'Reservations[].Instances[].InstanceId' --output text); do
  info "terminating $id"
  silent ec2 terminate-instances --region "$REGION" --instance-ids "$id"
done
for id in $(aws ec2 describe-instances --region "$REGION" --filters "$filter" \
  --query 'Reservations[].Instances[].InstanceId' --output text); do
  aws ec2 wait instance-terminated --region "$REGION" --instance-ids "$id" 2>/dev/null || true
done

for id in $(aws ec2 describe-security-groups --region "$REGION" \
  --filters "$filter" --query 'SecurityGroups[].GroupId' --output text); do
  info "deleting SG $id"
  silent ec2 delete-security-group --region "$REGION" --group-id "$id"
done

# Disassociate non-main route tables before deleting them.
for id in $(aws ec2 describe-route-tables --region "$REGION" \
  --filters "$filter" --query 'RouteTables[].RouteTableId' --output text); do
  for assoc in $(aws ec2 describe-route-tables --region "$REGION" --route-table-ids "$id" \
    --query 'RouteTables[0].Associations[?Main==`false`].RouteTableAssociationId' --output text); do
    silent ec2 disassociate-route-table --region "$REGION" --association-id "$assoc"
  done
  info "deleting RT $id"
  silent ec2 delete-route-table --region "$REGION" --route-table-id "$id"
done

for id in $(aws ec2 describe-subnets --region "$REGION" \
  --filters "$filter" --query 'Subnets[].SubnetId' --output text); do
  info "deleting subnet $id"
  silent ec2 delete-subnet --region "$REGION" --subnet-id "$id"
done

for id in $(aws ec2 describe-internet-gateways --region "$REGION" \
  --filters "$filter" --query 'InternetGateways[].InternetGatewayId' --output text); do
  for vpc in $(aws ec2 describe-internet-gateways --region "$REGION" \
    --internet-gateway-ids "$id" --query 'InternetGateways[0].Attachments[].VpcId' --output text); do
    silent ec2 detach-internet-gateway --region "$REGION" \
      --internet-gateway-id "$id" --vpc-id "$vpc"
  done
  info "deleting IGW $id"
  silent ec2 delete-internet-gateway --region "$REGION" --internet-gateway-id "$id"
done

for id in $(aws ec2 describe-vpcs --region "$REGION" \
  --filters "$filter" --query 'Vpcs[].VpcId' --output text); do
  info "deleting VPC $id"
  silent ec2 delete-vpc --region "$REGION" --vpc-id "$id"
done

if [[ -n "$INCLUDE_BUCKETS" ]]; then
  for b in $(aws s3api list-buckets \
    --query "Buckets[?starts_with(Name,'cvat-mnl-test-')].Name" --output text); do
    info "deleting bucket s3://$b"
    silent s3 rm "s3://$b" --recursive
    silent s3api delete-bucket --bucket "$b" --region "$REGION"
  done
else
  log "skipping S3 buckets (use --include-buckets to nuke them too)"
fi

ok "brute-force teardown complete"
