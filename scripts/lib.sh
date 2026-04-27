# shellcheck shell=bash
# Shared helpers — sourced by every script. Logging, state file, AWS auth.

# Region/zone — single source of truth. Override via env if needed.
: "${REGION:=ap-southeast-1}"
: "${ZONE:=ap-southeast-1-mnl-1a}"
: "${ZONE_GROUP:=ap-southeast-1-mnl-1}"
: "${PROJECT_TAG:=cvat-mnl-test}"

# Required at run time, validated where used (02-launch.sh).
: "${CVAT_TARGET:=}"
: "${CVAT_JOB_ID:=}"

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STATE_DIR="$PROJECT_ROOT/state"
RESULTS_DIR="$PROJECT_ROOT/results"
mkdir -p "$STATE_DIR" "$RESULTS_DIR"

if [[ -t 1 ]]; then
  C_RED=$'\033[31m' C_GRN=$'\033[32m' C_YEL=$'\033[33m'
  C_BLU=$'\033[34m' C_DIM=$'\033[2m' C_RST=$'\033[0m'
else
  C_RED='' C_GRN='' C_YEL='' C_BLU='' C_DIM='' C_RST=''
fi
log()  { printf '%s[%s]%s %s\n' "$C_DIM" "$(date +%H:%M:%S)" "$C_RST" "$*"; }
info() { printf '%s[%s]%s %s%s%s\n' "$C_DIM" "$(date +%H:%M:%S)" "$C_RST" "$C_BLU" "$*" "$C_RST"; }
ok()   { printf '%s[%s]%s %s%s%s\n' "$C_DIM" "$(date +%H:%M:%S)" "$C_RST" "$C_GRN" "$*" "$C_RST"; }
warn() { printf '%s[%s]%s %s%s%s\n' "$C_DIM" "$(date +%H:%M:%S)" "$C_RST" "$C_YEL" "$*" "$C_RST" >&2; }
err()  { printf '%s[%s]%s %s%s%s\n' "$C_DIM" "$(date +%H:%M:%S)" "$C_RST" "$C_RED" "$*" "$C_RST" >&2; }
die()  { err "$*"; exit 1; }

# state/infra.env — KEY=value pairs, sourced by later phases.
state_set() {
  local key="$1" value="$2" file="${3:-$STATE_DIR/infra.env}"
  touch "$file"
  if grep -q "^${key}=" "$file" 2>/dev/null; then
    sed -i "s|^${key}=.*|${key}=${value}|" "$file"
  else
    echo "${key}=${value}" >> "$file"
  fi
}
state_get() {
  local key="$1" file="${2:-$STATE_DIR/infra.env}"
  [[ -f "$file" ]] || return 1
  grep "^${key}=" "$file" | tail -1 | cut -d= -f2-
}
state_load() {
  local file="${1:-$STATE_DIR/infra.env}"
  [[ -f "$file" ]] || die "missing state file $file — run 01-provision.sh first"
  # shellcheck disable=SC1090
  set -a; source "$file"; set +a
}

require_auth() {
  aws sts get-caller-identity >/dev/null 2>&1 || die "AWS not authenticated. Run: aws sso login"
}

gen_run_id() { date -u +%Y%m%d-%H%M%S; }

# Tag block for `aws ec2 create-* --tag-specifications`.
tag_spec() {
  local resource_type="$1"
  local run_id="${RUN_ID:-$(state_get RUN_ID || echo unknown)}"
  printf 'ResourceType=%s,Tags=[{Key=Project,Value=%s},{Key=RunId,Value=%s},{Key=ManagedBy,Value=cvat-mnl-test-script}]' \
    "$resource_type" "$PROJECT_TAG" "$run_id"
}
