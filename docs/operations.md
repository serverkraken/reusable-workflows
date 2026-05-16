# Operations Runbook

Operational setup and maintenance procedures for the `serverkraken/reusable-workflows` catalog.

---

## 1. One-time GitHub App Setup

The catalog uses the `serverkraken-release-bot` GitHub App for release authentication. No PAT required; ephemeral 1-hour tokens are minted at runtime.

### 1.1 Create the App

1. Navigate to `https://github.com/organizations/serverkraken/settings/apps` and click **New GitHub App**.
2. Set the following permissions:
   - Contents: Read and write
   - Pull requests: Read and write
   - Issues: Read and write
   - Metadata: Read-only
3. Disable webhooks.
4. Set installation scope to "Only on this account".
5. Note the numeric **App ID** from the app settings page.

### 1.2 Install the App

1. From the app settings page, click **Install App**.
2. Install on the `serverkraken` org with access to **All repositories**.

### 1.3 Configure Org Secrets

Add both secrets as org-level secrets with **Repository access = All private repositories**, so downstream consumers reach them via `secrets: inherit`:

| Secret name                    | Value |
|--------------------------------|-------|
| `RELEASE_PLEASE_APP_ID`        | Numeric App ID (e.g. `123456`) |
| `RELEASE_PLEASE_APP_PRIVATE_KEY` | Full PEM contents (including `-----BEGIN RSA PRIVATE KEY-----` header/footer) |

---

## 2. Actions Access Policy

The catalog repo must allow other private repos in the org to call its reusable workflows:

```bash
gh api -X PUT \
  /repos/serverkraken/reusable-workflows/actions/permissions/access \
  -f access_level=organization
```

Equivalent UI path: **Settings → Actions → General → Access → "Accessible from repositories in the 'serverkraken' organization"**.

---

## 3. Private-Key Rotation

Private keys are rotated **on suspicion of compromise**, not on a fixed schedule. Multiple keys can coexist on a GitHub App, enabling zero-downtime rotation.

### Rotation procedure

1. Go to the App settings page → **Private keys** → **Generate a private key**.
2. Download the new PEM file.
3. Update the `RELEASE_PLEASE_APP_PRIVATE_KEY` org secret with the new PEM contents.
4. Trigger a release run (or wait for the next natural push to main) and confirm it succeeds.
5. Once one successful run is confirmed, return to **Private keys** and delete the old key.

No PAT-style 90-day calendar reminder is needed — key material doesn't weaken with elapsed time.

---

## 4. Renovate Dashboard

The catalog uses Renovate for dependency updates. Expect:

- **Weekly PRs** (before 6 AM Monday, Europe/Berlin): minor + patch updates for GitHub Actions, grouped.
- **Auto-merge**: minor and patch action updates auto-merge when the integration workflow passes.
- **Major updates**: never auto-merged; require manual review.
- **Fixture paths excluded**: `tests/fixtures/**` is excluded so intentionally outdated CVE/secret fixtures are not updated by Renovate.
- **Trivy CLI**: bumped via a `# renovate: datasource=...` annotation in the workflow YAML; the `customManagers` block in `.github/renovate.json5` handles this.

The Renovate Dependency Dashboard issue is created in this repo and lists pending/blocked updates.
