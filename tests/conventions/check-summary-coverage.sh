#!/usr/bin/env bash
# CI gate: every job in a required workflow must be reachable from its
# `summary` job.
#
# Branch protection requires exactly two checks — `integration / summary` and
# `self-ci / summary` — and both are aggregator jobs that fail when any job in
# their `needs:` graph failed. A job NOT in that graph therefore cannot turn a
# pull request red no matter what it does. It looks like a test in the run log
# and is decorative in fact.
#
# That is not hypothetical. `test-cleanup-images-missing-package` sat outside
# the graph, and its own comment says "the job passing IS the assertion" — the
# one property nobody was checking. The `needs:` list is hand-maintained, so a
# new job joins the run but not the gate unless someone remembers both places.
# This check removes the remembering.
#
# A job may opt out with a comment on the line directly above it:
#
#     # summary-exempt: <reason>
#     my-cleanup-job:
#
# The reason is mandatory, and a marker on a job that IS reachable fails too —
# an exemption list nobody prunes drifts back into the blindness it was meant
# to make visible.

set -euo pipefail

if [[ -n "${REPO_ROOT:-}" ]]; then
  cd "$REPO_ROOT"
else
  cd "$(git rev-parse --show-toplevel)"
fi

# Workflows with an aggregating job, as `<file>:<aggregator-job>`.
#
# Kept explicit rather than derived: the branch-protection API is not reachable
# from every context this gate runs in, and a check that silently degrades to
# "nothing to do" would be worse than one that has to be edited when the list
# changes.
#
# The first two are the required status checks — a job outside their graph
# cannot fail a pull request. The rest are scheduled runs whose aggregator
# writes the report a human actually reads; a job outside THAT graph turns the
# run red but never appears in the report, which is how it gets ignored. The
# aggregator is not always called `summary`, so the root is part of the entry:
# nightly-runner-parity's assert-parity covered only half its own jobs, and
# that is exactly the kind of gap this list exists to surface.
WORKFLOW_ROOTS=(
  ".github/workflows/integration.yml:summary"
  ".github/workflows/self-ci.yml:summary"
  ".github/workflows/failure-paths-nightly.yml:report-regressions"
  ".github/workflows/nightly-runner-parity.yml:assert-parity"
  ".github/workflows/drift-check.yml:publish"
)
if [[ $# -gt 0 ]]; then
  WORKFLOW_ROOTS=("$@")
fi

FAILED=0
tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

parse_jobs() {
  awk '
    function flush_pending() { exempt_pending = 0; exempt_reason = "" }
    /^jobs:[[:space:]]*$/ { in_jobs = 1; next }
    !in_jobs { next }
    # A key at column 0 ends the jobs: block.
    /^[^[:space:]#]/ { in_jobs = 0; next }
    /^[[:space:]]*$/ { next }
    /^[[:space:]]*#/ {
      if (match($0, /#[[:space:]]*summary-exempt:/)) {
        exempt_reason = substr($0, RSTART + RLENGTH)
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", exempt_reason)
        exempt_pending = 1
      }
      next
    }
    /^  [A-Za-z0-9_-]+:[[:space:]]*$/ {
      job = $0; sub(/^  /, "", job); sub(/:.*/, "", job)
      print "JOB\t" job
      if (exempt_pending) { print "EXEMPT\t" job "\t" exempt_reason }
      flush_pending()
      in_needs = 0
      next
    }
    job != "" && /^    needs:/ {
      rest = $0
      sub(/^    needs:[[:space:]]*/, "", rest)
      if (rest ~ /^\[/) {
        n = split(rest, parts, /[^A-Za-z0-9_-]+/)
        for (i = 1; i <= n; i++) if (parts[i] != "") print "EDGE\t" job "\t" parts[i]
      } else if (rest != "") {
        print "EDGE\t" job "\t" rest
      } else {
        in_needs = 1
      }
      flush_pending()
      next
    }
    in_needs && /^      - [A-Za-z0-9_-]+[[:space:]]*$/ {
      dep = $0; sub(/^      - /, "", dep); sub(/[[:space:]]*$/, "", dep)
      print "EDGE\t" job "\t" dep
      next
    }
    { in_needs = 0; flush_pending() }
  ' "$1"
}

for entry in "${WORKFLOW_ROOTS[@]}"; do
  workflow="${entry%:*}"
  root="${entry##*:}"
  if [[ ! -f "$workflow" ]]; then
    echo "FAIL: $workflow not found."
    FAILED=1
    continue
  fi

  parsed="$tmpdir/parsed.tsv"
  parse_jobs "$workflow" > "$parsed"

  awk -F '\t' '$1 == "JOB"    { print $2 }' "$parsed" | sort -u > "$tmpdir/jobs.txt"
  awk -F '\t' '$1 == "EDGE"   { print $2 "\t" $3 }' "$parsed" | sort -u > "$tmpdir/edges.tsv"
  awk -F '\t' '$1 == "EXEMPT" { print $2 "\t" $3 }' "$parsed" | sort -u > "$tmpdir/exempt.tsv"

  if ! grep -qxF "$root" "$tmpdir/jobs.txt"; then
    echo "FAIL: $workflow has no '$root' job, but is listed with that aggregator."
    FAILED=1
    continue
  fi

  # Reachability from `summary`, walked backwards along needs edges: a job is
  # covered when something already covered lists it in its needs.
  echo "$root" > "$tmpdir/reached.txt"
  while :; do
    join -t "$(printf '\t')" -1 1 -2 1 -o 2.2 \
      <(sort -u "$tmpdir/reached.txt") <(sort -k1,1 "$tmpdir/edges.tsv") \
      2>/dev/null | cat "$tmpdir/reached.txt" - | sort -u > "$tmpdir/next.txt"
    if cmp -s "$tmpdir/reached.txt" "$tmpdir/next.txt"; then break; fi
    mv "$tmpdir/next.txt" "$tmpdir/reached.txt"
  done
  sort -u "$tmpdir/reached.txt" -o "$tmpdir/reached.txt"

  cut -f1 "$tmpdir/exempt.tsv" | sort -u > "$tmpdir/exempt-names.txt"

  while IFS= read -r job; do
    [[ -n "$job" ]] || continue
    if grep -qxF "$job" "$tmpdir/exempt-names.txt"; then
      continue
    fi
    echo "FAIL: $workflow job '$job' is not reachable from '$root' — it is outside the aggregator."
    echo "      Add it to ${root}'s needs:, or mark it '# summary-exempt: <reason>'."
    FAILED=1
  done < <(comm -23 "$tmpdir/jobs.txt" "$tmpdir/reached.txt")

  # A stale exemption is its own failure: the marker claims a job is outside
  # the gate while it is in fact inside, which misleads the next reader.
  while IFS=$'\t' read -r job reason; do
    [[ -n "$job" ]] || continue
    if [[ -z "$reason" ]]; then
      echo "FAIL: $workflow job '$job' has a summary-exempt marker with no reason."
      FAILED=1
    fi
    if grep -qxF "$job" "$tmpdir/reached.txt"; then
      echo "FAIL: $workflow job '$job' is marked summary-exempt but IS reachable from '$root'. Drop the marker."
      FAILED=1
    fi
  done < "$tmpdir/exempt.tsv"

  if [[ $FAILED -eq 0 ]]; then
    echo "OK: $workflow — $(wc -l < "$tmpdir/jobs.txt" | tr -d ' ') jobs, $(wc -l < "$tmpdir/exempt-names.txt" | tr -d ' ') exempt, rest reachable from '$root'."
  fi
done

if [[ $FAILED -ne 0 ]]; then
  echo ""
  echo "Jobs outside their workflow's aggregator found."
  exit 1
fi
