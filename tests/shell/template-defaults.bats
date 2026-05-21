#!/usr/bin/env bats
# template-defaults.bats — catch template-default ↔ atom-default desync.
#
# For each SK_* override pattern in ci.yml.tmpl / prerelease.yml.tmpl,
# extract the template default (the literal between `||` and `}}`) and
# compare against the atom's `default:` field. They must match exactly,
# otherwise an adopter who never sets the var would get a different
# value than what the atom would have defaulted to on its own.

setup() {
  REPO_ROOT="$BATS_TEST_DIRNAME/../.."
  CI_TMPL="$REPO_ROOT/docs/adopter-templates/skeletons/ci.yml.tmpl"
  PRE_TMPL="$REPO_ROOT/docs/adopter-templates/skeletons/prerelease.yml.tmpl"
  RELEASE_TMPL="$REPO_ROOT/docs/adopter-templates/skeletons/release.yml.tmpl"
}

# Args: <template-file> <SK_VAR_NAME>
# Echoes the literal string between `||` and the expression close.
# Supports both bare:    ${{ vars.SK_FOO || '<DEFAULT>' }}
# and fromJSON-wrapped:  ${{ fromJSON(vars.SK_FOO || '<DEFAULT>') }}
# In the wrapped form the literal is followed by `)` instead of ` }}`.
template_default() {
  local file="$1" var="$2"
  grep -oE "vars\\.${var} \\|\\| '[^']*'" "$file" \
    | head -1 \
    | sed -E "s/.*\\|\\| '([^']*)'/\\1/"
}

# Args: <atom-yaml> <input-name>
# Echoes the `default:` value (string, with quotes stripped).
atom_default() {
  local file="$1" input="$2"
  # Find the input block, capture next `default:` line within 8 lines.
  awk -v input="$input" '
    $0 ~ "^      " input ":" { in_block = 1; lines = 0; next }
    in_block { lines++; if (lines > 8) { in_block = 0 } }
    in_block && /^        default:/ {
      sub(/^        default: ?/, "")
      gsub(/^["'\'']|["'\'']$/, "")
      print
      exit
    }
  ' "$file"
}

@test "SK_COVERAGE_THRESHOLD template default matches test-go atom default" {
  t=$(template_default "$CI_TMPL" "SK_COVERAGE_THRESHOLD")
  a=$(atom_default "$REPO_ROOT/.github/workflows/test-go.yml" "coverage_threshold")
  [ "$t" = "$a" ] || { echo "tmpl=$t atom=$a"; false; }
}

@test "SK_COVERAGE_THRESHOLD also matches test-python atom default" {
  a=$(atom_default "$REPO_ROOT/.github/workflows/test-python.yml" "coverage_threshold")
  t=$(template_default "$CI_TMPL" "SK_COVERAGE_THRESHOLD")
  [ "$t" = "$a" ] || { echo "tmpl=$t python-atom=$a"; false; }
}

@test "SK_COVERAGE_THRESHOLD also matches test-rust atom default" {
  a=$(atom_default "$REPO_ROOT/.github/workflows/test-rust.yml" "coverage_threshold")
  t=$(template_default "$CI_TMPL" "SK_COVERAGE_THRESHOLD")
  [ "$t" = "$a" ] || { echo "tmpl=$t rust-atom=$a"; false; }
}

@test "SK_GOLANGCI_LINT_VERSION matches lint-go atom default" {
  t=$(template_default "$CI_TMPL" "SK_GOLANGCI_LINT_VERSION")
  a=$(atom_default "$REPO_ROOT/.github/workflows/lint-go.yml" "golangci_lint_version")
  [ "$t" = "$a" ] || { echo "tmpl=$t atom=$a"; false; }
}

@test "SK_CARGO_LLVM_COV_VERSION matches test-rust atom default" {
  t=$(template_default "$CI_TMPL" "SK_CARGO_LLVM_COV_VERSION")
  a=$(atom_default "$REPO_ROOT/.github/workflows/test-rust.yml" "cargo_llvm_cov_version")
  [ "$t" = "$a" ] || { echo "tmpl=$t atom=$a"; false; }
}

@test "SK_CLIPPY_ARGS matches lint-rust atom default" {
  t=$(template_default "$CI_TMPL" "SK_CLIPPY_ARGS")
  a=$(atom_default "$REPO_ROOT/.github/workflows/lint-rust.yml" "clippy_args")
  [ "$t" = "$a" ] || { echo "tmpl=$t atom=$a"; false; }
}

@test "SK_TRIVY_SEVERITY in ci.yml matches trivy-fs atom default" {
  t=$(template_default "$CI_TMPL" "SK_TRIVY_SEVERITY")
  a=$(atom_default "$REPO_ROOT/.github/workflows/trivy-fs.yml" "severity")
  [ "$t" = "$a" ] || { echo "tmpl=$t atom=$a"; false; }
}

@test "SK_TRIVY_SEVERITY in prerelease.yml matches trivy-image atom default" {
  t=$(template_default "$PRE_TMPL" "SK_TRIVY_SEVERITY")
  a=$(atom_default "$REPO_ROOT/.github/workflows/trivy-image.yml" "severity")
  [ "$t" = "$a" ] || { echo "tmpl=$t atom=$a"; false; }
}

@test "all empty-default knobs use ''" {
  for var in SK_GO_VERSION SK_PYTHON_VERSION SK_RUST_TOOLCHAIN SK_TRIVY_VERSION; do
    t=$(template_default "$CI_TMPL" "$var")
    [ "$t" = "" ] || { echo "$var in CI_TMPL has non-empty template default '$t'"; false; }
  done
  for var in SK_TRIVY_VERSION; do
    t=$(template_default "$PRE_TMPL" "$var")
    [ "$t" = "" ] || { echo "$var in PRE_TMPL has non-empty template default '$t'"; false; }
  done
}

@test "SK_SIGN template default matches docker-build atom default" {
  t=$(template_default "$RELEASE_TMPL" "SK_SIGN")
  a=$(atom_default "$REPO_ROOT/.github/workflows/docker-build.yml" "sign")
  [ "$t" = "$a" ] || { echo "tmpl=$t atom=$a"; false; }
}

@test "SK_ATTEST template default matches docker-build atom default" {
  t=$(template_default "$RELEASE_TMPL" "SK_ATTEST")
  a=$(atom_default "$REPO_ROOT/.github/workflows/docker-build.yml" "attest")
  [ "$t" = "$a" ] || { echo "tmpl=$t atom=$a"; false; }
}

@test "SK_SBOM template default matches docker-build atom default" {
  t=$(template_default "$RELEASE_TMPL" "SK_SBOM")
  a=$(atom_default "$REPO_ROOT/.github/workflows/docker-build.yml" "sbom")
  [ "$t" = "$a" ] || { echo "tmpl=$t atom=$a"; false; }
}
