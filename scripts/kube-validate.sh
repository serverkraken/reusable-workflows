#!/usr/bin/env bash
# Validate Kubernetes manifests under each root in MANIFESTS_PATHS:
#   - kubeconform every standalone top-level *.yaml (maxdepth 1)
#   - `kustomize build <dir> | kubeconform` for every discovered
#     kustomization.yaml tree
# Collects all failures, then exits non-zero if any occurred.
#
# Generalizes serverkraken/homelab-study scripts/kubeconform.sh. Two fixes
# vs. the original: (1) honour BOTH pipe stages (pipefail), not just
# PIPESTATUS[0]=kustomize; (2) run the find-loop in the current shell
# (`done < <(...)`) so failures actually abort instead of dying in a pipe
# subshell.
#
# Env contract (set by .github/workflows/kube-validate.yml):
#   MANIFESTS_PATHS        newline-separated roots (required)
#   KUSTOMIZE_ARGS         args passed verbatim to `kustomize build`
#   SCHEMA_LOCATIONS       newline-separated kubeconform -schema-location values
#   SKIP_KINDS             comma-separated kinds → kubeconform -skip
#   STRICT                 "true"|"false" → kubeconform -strict
#   IGNORE_MISSING_SCHEMAS "true"|"false" → kubeconform -ignore-missing-schemas
set -o errexit
set -o nounset
set -o pipefail

: "${MANIFESTS_PATHS:?MANIFESTS_PATHS is required (newline-separated roots)}"
KUSTOMIZE_ARGS="${KUSTOMIZE_ARGS:-}"
SCHEMA_LOCATIONS="${SCHEMA_LOCATIONS:-default}"
SKIP_KINDS="${SKIP_KINDS:-}"
STRICT="${STRICT:-true}"
IGNORE_MISSING_SCHEMAS="${IGNORE_MISSING_SCHEMAS:-true}"

kubeconform_args=(-verbose)
if [[ "$STRICT" == "true" ]]; then
  kubeconform_args+=(-strict)
fi
if [[ "$IGNORE_MISSING_SCHEMAS" == "true" ]]; then
  kubeconform_args+=(-ignore-missing-schemas)
fi
if [[ -n "$SKIP_KINDS" ]]; then
  kubeconform_args+=(-skip "$SKIP_KINDS")
fi
while IFS= read -r loc; do
  [[ -z "$loc" ]] && continue
  kubeconform_args+=(-schema-location "$loc")
done <<< "$SCHEMA_LOCATIONS"

# Intentional word-splitting of the verbatim kustomize args string.
read -r -a kustomize_args <<< "$KUSTOMIZE_ARGS" || true

fail=0

validate_root() {
  local root="$1"
  if [[ ! -d "$root" ]]; then
    echo "::warning::kube-validate: manifests root not found: ${root} (skipping)"
    return 0
  fi

  echo "=== Standalone manifests in ${root} ==="
  local file
  while IFS= read -r -d '' file; do
    echo "--- kubeconform ${file}"
    if ! kubeconform "${kubeconform_args[@]}" "$file"; then
      echo "::error::kubeconform failed: ${file}"
      fail=1
    fi
  done < <(find "$root" -maxdepth 1 -type f -name '*.yaml' -print0)

  echo "=== Kustomizations in ${root} ==="
  local kfile dir
  while IFS= read -r -d '' kfile; do
    dir="$(dirname "$kfile")"
    echo "--- kustomize build ${dir}"
    if ! kustomize build "$dir" "${kustomize_args[@]}" | kubeconform "${kubeconform_args[@]}"; then
      echo "::error::validation failed: ${dir}"
      fail=1
    fi
  done < <(find "$root" -type f -name 'kustomization.yaml' -print0)
}

while IFS= read -r root; do
  [[ -z "$root" ]] && continue
  validate_root "$root"
done <<< "$MANIFESTS_PATHS"

if [[ "$fail" -ne 0 ]]; then
  echo "::error::kube-validate: one or more manifests failed validation"
  exit 1
fi
echo "kube-validate: all manifests valid"
