#!/usr/bin/env bash
# All phases end-to-end. Set NO_TEARDOWN=1 to inspect infra after the run.

set -euo pipefail
cd "$(dirname "$0")"

./scripts/00-prereqs.sh
./scripts/01-provision.sh
./scripts/02-launch.sh
./scripts/03-collect.sh

if [[ "${NO_TEARDOWN:-}" == "1" ]]; then
  echo
  echo "NO_TEARDOWN=1 — skipping. Run ./scripts/04-teardown.sh when done."
  exit 0
fi

echo
read -r -p "Run teardown now? [Y/n] " ans
case "${ans:-Y}" in
  [Nn]*) echo "Skipping. Run ./scripts/04-teardown.sh when ready." ;;
  *) ./scripts/04-teardown.sh ;;
esac
