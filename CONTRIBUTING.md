# Contributing

## Local validation

Before pushing a PR, run the static checks the CI will run:

```bash
# Lint workflows
docker run --rm -v "$PWD:/repo" -w /repo rhysd/actionlint:latest

# Lint YAML
pipx run yamllint .github/ actions/ tests/
```

For the integration tests, use `act`:

```bash
act pull_request -W .github/workflows/integration.yml --container-architecture linux/amd64
```

## Commit messages

This repo uses [Conventional Commits](https://www.conventionalcommits.org/). release-please reads the log to decide the next version:

- `feat: …` → minor bump (or major if `feat!:`)
- `fix: …` → patch bump
- `chore: …`, `docs: …`, `test: …`, `ci: …` → no version bump
- `feat!:` or `BREAKING CHANGE:` in body → major bump

## Backwards compatibility contract

The `inputs:` / `outputs:` / `secrets:` of every reusable workflow are the public API. Any change to those shapes — adding required inputs, removing inputs, renaming outputs — is a **breaking change** and requires `feat!:` or `BREAKING CHANGE:`.

Adding optional inputs (with safe defaults), adding outputs, or changing internal step ordering is **non-breaking**.

## Onboarding workflow — acceptance procedure

Whenever `onboard.yml`, `actions/onboard-*`, or `scripts/onboard-*` change:

1. Bats unit tests pass: `bats tests/shell/`.
2. Static lint passes: the `validate` workflow on PR.
3. Self dry-run passes: the `test-onboard-dry-run` job inside `integration` runs the workflow against the catalog itself with `dry_run: true`.
4. Manual smoke: from a release of the catalog, dispatch `onboard.yml` against one low-risk repo with `dry_run: true`. Verify the rendered diff in the step summary. Re-run with `dry_run: false` and merge PR A. Push a `feat:` commit. Verify `release.yml` end-to-end runs green. Merge PR B.

Document any new gotcha in `CLAUDE-troubleshooting.md` so the next session benefits.
