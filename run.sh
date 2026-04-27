#!/usr/bin/env bash
# run.sh — orchestrate all phases end-to-end.
#
# Runs:
#   00-prereqs.sh   (idempotent)
#   01-provision.sh (creates infra)
#   02-launch.sh    (starts EC2 + measurement)
#   03-collect.sh   (waits for results, summarizes)
#   pause           (lets you inspect)
#   04-teardown.sh  (destroys infra)
#
# Set NO_TEARDOWN=1 to skip the final teardown (e.g. for debugging an
# instance that misbehaved). Run scripts/04-teardown.sh manually after.

set -euo pipefail
cd "$(dirname "$0")"

./scripts/00-prereqs.sh
./scripts/01-provision.sh
./scripts/02-launch.sh
./scripts/03-collect.sh

if [[ "${NO_TEARDOWN:-}" == "1" ]]; then
  echo
  echo "NO_TEARDOWN=1 set. Skipping teardown."
  echo "Run ./scripts/04-teardown.sh when done."
  exit 0
fi

echo
read -r -p "Run teardown now? [Y/n] " ans
case "${ans:-Y}" in
  [Nn]*) echo "Skipping teardown. Run ./scripts/04-teardown.sh when ready." ;;
  *) ./scripts/04-teardown.sh ;;
esac
