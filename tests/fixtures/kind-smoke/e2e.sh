#!/usr/bin/env bash
# Happy-path fixture for e2e-kind.yml — the smallest possible consumer
# script. Creates a 1-node kind cluster WITH the default CNI (kindnet):
# Cilium coverage belongs to real consumers; keeping it out holds the
# PR-time integration job at ~3 minutes. Asserts the node reaches Ready,
# then deletes the cluster (lifecycle belongs to the script, per the
# atom's contract).
set -euo pipefail
CLUSTER=kind-smoke
trap 'kind delete cluster --name "$CLUSTER" >/dev/null 2>&1 || true' EXIT
kind create cluster --name "$CLUSTER" --config "$(dirname "$0")/kind-config.yaml" --wait 180s
kubectl --context "kind-$CLUSTER" get nodes -o wide
kubectl --context "kind-$CLUSTER" wait --for=condition=Ready node --all --timeout=60s
echo "OK: kind-smoke happy path"
