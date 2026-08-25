#!/usr/bin/env bash
# push-bot-branch.sh — force-push a bot-owned branch without destroying human work.
#
# Usage:  push-bot-branch.sh <branch> <base-ref> <bot-author>
#           branch      the bot branch, e.g. chore/onboard-reusable-workflows
#           base-ref    what the branch was built from, e.g. origin/main
#           bot-author  git author name the bot commits under
#
# onboard.yml rebuilt these branches from the default branch and pushed with a
# bare `git push -f`. That is correct exactly as long as nobody ever touches
# the branch. The moment a reviewer pushes a fixup onto the onboarding PR — the
# obvious thing to do when the render is 95% right — the next run throws it
# away silently, and the PR simply shows different content than the reviewer
# left there.
#
# Two changes: the push carries a lease, so a branch that moved under us is
# refused rather than overwritten; and any commit on the branch that the bot
# did not author aborts the push with the author named. The lease alone would
# not be enough — the bot re-fetches, so the lease would be satisfied and the
# human commit would still be gone.
set -euo pipefail

BRANCH="${1:-}"
BASE="${2:-}"
BOT="${3:-}"

if [[ -z "$BRANCH" || -z "$BASE" || -z "$BOT" ]]; then
  echo "usage: $0 <branch> <base-ref> <bot-author>" >&2
  exit 1
fi

# Explicit refspec: actions/checkout narrows remote.origin.fetch, so a bare
# `git fetch origin <branch>` is not guaranteed to update the tracking ref
# that --force-with-lease reads.
git fetch origin "+refs/heads/${BRANCH}:refs/remotes/origin/${BRANCH}" 2>/dev/null || true

if git rev-parse --verify -q "refs/remotes/origin/${BRANCH}" >/dev/null; then
  foreign=$(git log --format='%an' "${BASE}..refs/remotes/origin/${BRANCH}" \
            | grep -vxF "$BOT" | sort -u || true)
  if [[ -n "$foreign" ]]; then
    echo "::error::${BRANCH} carries commits not authored by ${BOT}:" >&2
    # Zeilenweise, nicht per Word-Splitting: Autorennamen enthalten Leerzeichen.
    while IFS= read -r who; do printf '  %s\n' "$who" >&2; done <<< "$foreign"
    echo "Refusing to force-push over them. Merge or drop that work, then re-run." >&2
    exit 1
  fi
  git push --force-with-lease="${BRANCH}:$(git rev-parse "refs/remotes/origin/${BRANCH}")" \
    origin "$BRANCH"
else
  # Branch does not exist remotely — nothing to lease against.
  git push origin "$BRANCH"
fi
