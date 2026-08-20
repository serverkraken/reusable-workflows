#!/usr/bin/env bash
# Failure-path fixture for e2e-kind.yml — creates a cluster and then
# fails WITHOUT deleting it. Exercises both the atom's failure
# diagnostics (artifact must appear) and its always()-cleanup of leaked
# clusters (the follow-up leak check inside the atom must pass).
set -euo pipefail
kind create cluster --name kind-smoke-fail --config "$(dirname "$0")/kind-config.yaml" --wait 180s
echo "fixture now fails deliberately, leaving the cluster behind"
exit 1
