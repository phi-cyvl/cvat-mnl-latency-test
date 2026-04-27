#!/usr/bin/env bash
# Verify AWS auth and opt in the MNL Local Zone.
#
# Local Zones are gated behind a one-time, account-level opt-in. Without it,
# subnets in ap-southeast-1-mnl-1a can't be created. Opt-in is free, reversible,
# and persistent — re-running this script is a no-op once opted in.

set -euo pipefail
source "$(dirname "$0")/lib.sh"

info "phase 0 — prereqs"

require_auth
ok "auth ok: $(aws sts get-caller-identity --query '[Account, Arn]' --output text)"

status=$(aws ec2 describe-availability-zones --region "$REGION" \
  --all-availability-zones --filters "Name=zone-name,Values=$ZONE" \
  --query 'AvailabilityZones[0].OptInStatus' --output text)

case "$status" in
  opted-in)
    ok "Local Zone $ZONE_GROUP already opted-in"
    ;;
  not-opted-in)
    info "opting in Local Zone $ZONE_GROUP (one-time, persistent)"
    aws ec2 modify-availability-zone-group --region "$REGION" \
      --group-name "$ZONE_GROUP" --opt-in-status opted-in >/dev/null
    log "polling for opt-in to propagate (up to 90 s)..."
    for _ in $(seq 1 18); do
      sleep 5
      s=$(aws ec2 describe-availability-zones --region "$REGION" \
        --all-availability-zones --filters "Name=zone-name,Values=$ZONE" \
        --query 'AvailabilityZones[0].OptInStatus' --output text)
      if [[ "$s" == "opted-in" ]]; then
        ok "Local Zone $ZONE_GROUP opted-in"
        exit 0
      fi
    done
    die "Local Zone did not transition to opted-in within 90 s (last: $s)"
    ;;
  *)
    die "unexpected OptInStatus for $ZONE: $status"
    ;;
esac
