#!/usr/bin/env bash
# 00-prereqs.sh — verify auth and opt in the Manila Local Zone.
#
# Why this exists:
#   AWS Local Zones are gated behind an account-level opt-in
#   (`aws ec2 modify-availability-zone-group --opt-in-status opted-in`).
#   It's a one-time, persistent setting — but if no one has ever run a
#   workload in `ap-southeast-1-mnl-1` in this account, opt-in is required
#   before subnets can be created in it. Enabling is free and reversible.
#
# What it does:
#   1. Confirms AWS SSO is current.
#   2. Reads the Local Zone's current opt-in status.
#   3. If not opted-in, opts in and waits up to 90 s for it to propagate.
#
# Idempotent — safe to run repeatedly. No state is written.

set -euo pipefail
source "$(dirname "$0")/lib.sh"

info "phase 0 — prereqs"

require_auth
identity=$(aws sts get-caller-identity --query '[Account, Arn]' --output text)
ok "auth ok: $identity"

# --- Local Zone opt-in -------------------------------------------------------
status=$(aws ec2 describe-availability-zones \
  --region "$REGION" \
  --all-availability-zones \
  --filters "Name=zone-name,Values=$ZONE" \
  --query 'AvailabilityZones[0].OptInStatus' \
  --output text)

case "$status" in
  opted-in)
    ok "Local Zone $ZONE_GROUP already opted-in"
    ;;
  not-opted-in)
    info "opting in Local Zone $ZONE_GROUP (one-time, persistent)"
    aws ec2 modify-availability-zone-group \
      --region "$REGION" \
      --group-name "$ZONE_GROUP" \
      --opt-in-status opted-in >/dev/null
    log "polling for opt-in to propagate (up to 90 s)..."
    for _ in $(seq 1 18); do
      sleep 5
      s=$(aws ec2 describe-availability-zones \
        --region "$REGION" --all-availability-zones \
        --filters "Name=zone-name,Values=$ZONE" \
        --query 'AvailabilityZones[0].OptInStatus' \
        --output text)
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
