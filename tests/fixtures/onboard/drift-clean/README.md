# drift-clean fixture

Pre-rendered v3 onboarding output. Used by `.github/workflows/caller-onboard-drift-happy.yml`
to verify the `actions/onboard-drift` composite-action wrapper layer
(env passthrough, GITHUB_OUTPUT capture, GITHUB_ACTION_PATH resolution).

Script-level drift logic is covered by `tests/shell/onboard-drift.bats`; this
fixture exercises only the GHA wrapper.

## Regenerating

When the catalog cuts a new major (v4+), this fixture's lock will point at the
old major and drift will report `behind`, breaking the wrapper test. Refresh:

    rm -rf tests/fixtures/onboard/drift-clean
    mkdir -p tests/fixtures/onboard/drift-clean
    profile=$(scripts/onboard-detect.sh --profile-json tests/fixtures/onboard/go-repo)
    printf '%s\n' "$profile" > /tmp/profile.json
    scripts/onboard-render.sh "$PWD" tests/fixtures/onboard/drift-clean /tmp/profile.json v4
    rm /tmp/profile.json

Then restore this README and update the `current_version:` input in the caller.

The same regeneration is needed whenever the render-and-compare detection
(added 2026-05-24) reports `stale-lock` against this fixture, which happens
when templates evolve within the same major.
