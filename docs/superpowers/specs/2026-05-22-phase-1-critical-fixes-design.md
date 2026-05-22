# Phase 1 — Critical Fixes (Design Spec)

**Datum:** 2026-05-22
**Quelle:** `REVIEW-2026-05-22.md` § A + Teile von § B
**Scope:** CRIT-1, CRIT-2, CRIT-3, HIGH-3, HIGH-4 + OPT-1
**Konsumiert von:** Implementation Plan (writing-plans next)

---

## 1. Goal

Die fünf Critical/High-Findings aus dem Phase-1-Block des Reviews schließen ohne Schnittstellen-Brüche. Drei voneinander unabhängige Concerns werden als drei separate PRs umgesetzt.

## 2. Scope

### In Scope

| Concern | Findings | Outcome |
|---|---|---|
| **A. Onboard-Action Hardening** | CRIT-1, CRIT-2, CRIT-3 | `actions/onboard-detect/action.yml` und `actions/onboard-render/action.yml` verarbeiten Inputs ohne Shell-Interpolation; `GITHUB_OUTPUT`-Multiline-Block kann nicht durch Profile-Content früh terminiert werden. |
| **B. Empty-Release Detection Fix** | HIGH-3 | Adopter-Repos ohne Releases bekommen `current_version=0.0.0` (statt korrumpiertem String `"null"`) im Profile und in der gerenderten `.release-please-manifest.json`. |
| **C. Hash-Helper Extraktion** | HIGH-4, OPT-1 | `sha256_of()` lebt in `scripts/lib/hash-lib.sh`; `onboard-render.sh` und `onboard-drift.sh` sourcen es; Bats-Tests bleiben auf macOS und Linux grün. |

### Out of Scope (explizit nach Phase 2+ verschoben)

- HIGH-1 (Cross-Repo-Ref `v2`→`v3` an 7 Stellen)
- HIGH-2 (`release.yml` `permissions:`-Block)
- HIGH-5 (`pin_version: v1` Default)
- HIGH-6 / HIGH-7 (Test-Coverage `onboard.yml` + `semantic-release.yml`)
- HIGH-8 / HIGH-9 (Adopter-Template-Cleanup, Contracts-Doku)
- `actions/setup-python-deps/action.yml` Injection-Audit — die `working-directory: ${{ inputs.X }}`-Form wird von GHA korrekt quoted; kein Shell-Interpolations-Vektor. Vereinzelte `echo "::error:: … $(pwd)"`-Pattern sind read-only und nicht beeinflussbar.

## 3. Background

### 3.1 Threat Model für Concern A

`actions/onboard-detect/action.yml` und `actions/onboard-render/action.yml` werden im Workflow `onboard.yml` aufgerufen, der via `workflow_dispatch` mit benutzerdefinierten `target_repos` (kommagetrennt) und `language_override` (frei) gestartet wird. Die Inputs landen heute über `"${{ inputs.X }}"`-Interpolation direkt im `run:`-Shell-Text. GHA quoted diese Interpolation **nicht** automatisch — ein Wert mit einem Single-Quote-Zeichen terminiert die quoted Section, der Rest wird als Shell-Code interpretiert. Aktueller Caller ist nur unser eigener `onboard.yml`, der die Inputs derzeit nicht aus untrusted Sources weiterreicht; dennoch ist das eine Composite-Action mit `workflow_call`-Erreichbarkeit, und die Hardening-Maßnahme ist defensiv für Future-Reuse.

CRIT-3 ist eine separate Klasse: `profile_json` wird als GHA-Multiline-Output mit literalem `EOF`-Delimiter emittiert. Erzeugt das Detection-Script jemals eine Zeile, die exakt `EOF` enthält (Pfad, Errormessage, Future-Tool-Output), schließt der Multiline-Block früh und der Rest des JSON wird als neue Output-Assignments geparst. Niedrige Wahrscheinlichkeit, hohe Schadenswirkung (stille Datenkorruption).

### 3.2 Bug-Mechanik HIGH-3

`gh release list --json tagName -q '.[0].tagName'` gibt bei einem Repo ohne Releases den String `"null"` (exit 0), nicht leeren Output. Der bestehende Guard `[[ -n "$raw_tag" ]]` ist `true` für `"null"`, daher wird `current_version="null"` gesetzt. Dieser String fließt in das Profile-JSON und über `onboard-render.sh` in die gerenderte `.release-please-manifest.json` ("." = "null"). Release-please akzeptiert das nicht und failt beim ersten Release-Run.

Identisches Pattern an zwei Stellen:
- `scripts/onboard-detect.sh:92–95` (Legacy-key=value-Output)
- `scripts/lib/onboard-detect-lib.sh:39–40` (Profile-JSON-Output)

### 3.3 Bug-Mechanik HIGH-4

`onboard-render.sh` hat bereits einen `sha256_of()`-Helper (Zeilen 127–133), der auf macOS auf `shasum -a 256` fallback. `onboard-drift.sh:51` ruft `sha256sum` direkt ohne Fallback. Resultat: `tests/shell/onboard-drift.bats` failt auf macOS-Devmaschinen, läuft aber auf Ubuntu-CI grün. Strukturlösung: Helper in eine gemeinsame Lib extrahieren.

## 4. Design per Concern

### 4.1 Concern A — Onboard-Action Hardening

#### A.1 `actions/onboard-detect/action.yml`

**Vorher (Zeilen 41–58):**
```yaml
- id: detect
  shell: bash
  env:
    TARGET_REPO: ${{ inputs.target_repo }}
    GH_TOKEN: ${{ inputs.github_token }}
  run: |
    set -euo pipefail
    "$GITHUB_ACTION_PATH/../../scripts/onboard-detect.sh" \
      "${{ inputs.repo_path }}" \
      "${{ inputs.language_override }}" \
      >> "$GITHUB_OUTPUT"
    profile=$("$GITHUB_ACTION_PATH/../../scripts/onboard-detect.sh" --profile-json "${{ inputs.repo_path }}")
    {
      echo "profile_json<<EOF"
      echo "$profile"
      echo "EOF"
    } >> "$GITHUB_OUTPUT"
```

**Nachher:**
```yaml
- id: detect
  shell: bash
  env:
    TARGET_REPO: ${{ inputs.target_repo }}
    GH_TOKEN: ${{ inputs.github_token }}
    REPO_PATH: ${{ inputs.repo_path }}
    LANG_OVERRIDE: ${{ inputs.language_override }}
  run: |
    set -euo pipefail
    # Inputs are passed via env to avoid GHA expression interpolation into
    # shell text. Multi-line GITHUB_OUTPUT uses a random delimiter to prevent
    # collision with any line literally equal to a fixed marker.
    "$GITHUB_ACTION_PATH/../../scripts/onboard-detect.sh" \
      "$REPO_PATH" "$LANG_OVERRIDE" >> "$GITHUB_OUTPUT"
    profile=$("$GITHUB_ACTION_PATH/../../scripts/onboard-detect.sh" --profile-json "$REPO_PATH")
    delim="EOF_$(head -c 16 /dev/urandom | base64 | tr -dc A-Za-z0-9 | head -c 16)"
    { echo "profile_json<<${delim}"; echo "$profile"; echo "${delim}"; } >> "$GITHUB_OUTPUT"
```

Schnittstelle (`inputs:`, `outputs:`) unverändert.

#### A.2 `actions/onboard-render/action.yml`

**Vorher (Zeilen 25–35):**
```yaml
- shell: bash
  run: |
    set -euo pipefail
    tmp=$(mktemp -d)
    echo '${{ inputs.profile_json }}' > "$tmp/profile.json"
    "${{ inputs.catalog_path }}/scripts/onboard-render.sh" \
      "${{ inputs.catalog_path }}" \
      "${{ inputs.target_path }}" \
      "$tmp/profile.json" \
      "${{ inputs.pin_version }}"
    rm -rf "$tmp"
```

**Nachher:**
```yaml
- id: render
  shell: bash
  env:
    CATALOG_PATH: ${{ inputs.catalog_path }}
    TARGET_PATH: ${{ inputs.target_path }}
    PROFILE_JSON: ${{ inputs.profile_json }}
    PIN_VERSION: ${{ inputs.pin_version }}
  run: |
    set -euo pipefail
    # Inputs are passed via env so they are never re-parsed by the shell.
    # printf '%s' avoids echo's backslash-interpretation surprises on bash.
    tmp=$(mktemp -d)
    trap 'rm -rf "$tmp"' EXIT
    printf '%s' "$PROFILE_JSON" > "$tmp/profile.json"
    "$CATALOG_PATH/scripts/onboard-render.sh" \
      "$CATALOG_PATH" "$TARGET_PATH" "$tmp/profile.json" "$PIN_VERSION"
```

Bonus-Aufräumung: `trap` statt manuellem `rm -rf` (exception-safe). Step erhält `id: render` für Konsistenz mit den anderen onboard-Actions (`id: detect`, `id: drift`).

#### A.3 Tests

- Existierende `tests/shell/onboard-detect.bats` und `onboard-render.bats` müssen weiter grün laufen → bestätigt Verhaltens-Äquivalenz auf Script-Ebene.
- Neuer Bats-Test in `onboard-detect.bats` für CRIT-3: Der Delimiter-Emit-Snippet aus der action.yml wird inline in einem Test ausgeführt mit einer payload, die eine Zeile `EOF` enthält. Test parsed das resultierende `GITHUB_OUTPUT`-Fragment via `awk` zwischen den Delimiter-Markern und prüft, dass die Payload byte-genau erhalten bleibt:
  ```bats
  @test "GITHUB_OUTPUT multiline block survives payload containing literal EOF" {
    payload=$'{"a":"line1"\nEOF\n"b":"line3"}'
    out=$(mktemp)
    delim="EOF_$(head -c 16 /dev/urandom | base64 | tr -dc A-Za-z0-9 | head -c 16)"
    { echo "profile_json<<${delim}"; echo "$payload"; echo "${delim}"; } > "$out"
    extracted=$(awk -v d="$delim" '$0==("profile_json<<"d){f=1;next} $0==d{f=0} f' "$out")
    [ "$extracted" = "$payload" ]
  }
  ```
- Pure-defensive Refactor — keine bestehenden Tests sollten brechen.

#### A.4 Risiken

- `printf '%s' "$PROFILE_JSON"` mit sehr großem JSON (>~128 KB) könnte ARG_MAX treffen. Akzeptiert: Detection-Profile sind typisch ~2 KB. Workaround wäre `cat <<<"$PROFILE_JSON"` (uses heredoc, no argv limit), aber subtilere semantics.
- Random-Delimiter via `/dev/urandom`: portabel auf GHA-Runner (Linux + self-hosted Linux). Kein Windows-Risk im Katalog.

### 4.2 Concern B — Empty-Release Detection Fix

#### B.1 `scripts/onboard-detect.sh` Zeilen 92–95

**Vorher:**
```bash
raw_tag=$(gh release list --repo "$TARGET_REPO" --exclude-pre-releases --limit 1 --json tagName -q '.[0].tagName' 2>/dev/null || echo "")
if [[ -n "$raw_tag" ]]; then
  current_version="${raw_tag#v}"
fi
```

**Nachher:**
```bash
raw_tag=$(gh release list --repo "$TARGET_REPO" --exclude-pre-releases --limit 1 --json tagName -q '.[0].tagName' 2>/dev/null || echo "")
# jq -q '.[0].tagName' returns the literal string "null" (exit 0) when the release
# list is empty. Treat "null" as no-release-found and keep current_version=0.0.0.
if [[ -n "$raw_tag" && "$raw_tag" != "null" ]]; then
  current_version="${raw_tag#v}"
fi
```

#### B.2 `scripts/lib/onboard-detect-lib.sh` Zeilen 38–40

**Vorher:**
```bash
local tag
tag=$(gh release list --repo "$target_repo" --exclude-pre-releases --limit 1 --json tagName -q '.[0].tagName' 2>/dev/null || echo "")
[[ -n "$tag" ]] && current_version="${tag#v}"
```

**Nachher:**
```bash
local tag
tag=$(gh release list --repo "$target_repo" --exclude-pre-releases --limit 1 --json tagName -q '.[0].tagName' 2>/dev/null || echo "")
# See onboard-detect.sh: "null" sentinel guard against empty release list.
[[ -n "$tag" && "$tag" != "null" ]] && current_version="${tag#v}"
```

#### B.3 Tests

Neue Bats-Tests in `tests/shell/onboard-detect.bats`:

```bats
@test "current_version=0.0.0 when target_repo has no releases (gh returns \"null\")" {
  # Mock gh to simulate empty release list (jq -q .[0].tagName on [] returns "null")
  GH_MOCK=$(mktemp -d)
  cat > "$GH_MOCK/gh" <<'EOF'
#!/usr/bin/env bash
case "$1 $2" in
  "api /repos/owner/repo") echo "main" ;;
  "release list")          echo "null" ;;
  *) echo "::error::unexpected gh call: $*" >&2; exit 1 ;;
esac
EOF
  chmod +x "$GH_MOCK/gh"
  PATH="$GH_MOCK:$PATH" TARGET_REPO=owner/repo run "$DETECT" "$FIX/go-repo"
  [ "$status" -eq 0 ]
  [[ "$output" == *"current_version=0.0.0"* ]]
}

@test "profile_json: current_version=0.0.0 for repo with no releases" {
  # Same mock; assert against --profile-json output via jq
  GH_MOCK=$(mktemp -d)
  cat > "$GH_MOCK/gh" <<'EOF'
#!/usr/bin/env bash
case "$1 $2" in
  "api /repos/owner/repo") echo "main" ;;
  "release list")          echo "null" ;;
  *) exit 1 ;;
esac
EOF
  chmod +x "$GH_MOCK/gh"
  PATH="$GH_MOCK:$PATH" TARGET_REPO=owner/repo run "$DETECT" --profile-json "$FIX/go-repo"
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.current_version')" = "0.0.0" ]
}
```

Mock-Pattern via `PATH`-Override ist im Repo etabliert (vgl. fehlende Bats-Setup in `seed-onboarding-status` ist genau dieser Mock-Pattern, MED-15).

#### B.4 Risiken

Keine. Reine Bug-Korrektur, additive Guard-Bedingung, kein API-Change.

### 4.3 Concern C — Hash-Helper Extraktion

#### C.1 Neue Datei `scripts/lib/hash-lib.sh`

```bash
#!/usr/bin/env bash
# Portable sha256 helper used by onboard-render.sh and onboard-drift.sh.
# Linux has sha256sum; macOS only ships shasum -a 256. Both emit
# "<hex> <filename>" — we take the first field.

sha256_of() {
  local file="$1"
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$file" | cut -d' ' -f1
  else
    shasum -a 256 "$file" | cut -d' ' -f1
  fi
}
```

Keine Top-Level-Statements — pure source-able. Kein eigener `set -euo pipefail` (das setzt der sourcende Caller).

#### C.2 `scripts/onboard-render.sh`

- Zeilen 126–133 (`sha256_of()`-Definition) entfernen.
- Direkt nach `SCRIPT_DIR`-Anchor (etwa Zeile 8–10) sourcen: `source "$SCRIPT_DIR/lib/hash-lib.sh"`.

#### C.3 `scripts/onboard-drift.sh`

- Vor Verwendung (vor Zeile 51) `source "$SCRIPT_DIR/lib/hash-lib.sh"` ergänzen.
- Zeile 51 ändern:
  ```bash
  # Vorher: actual="sha256:$(sha256sum "$TARGET/$f" | cut -d' ' -f1)"
  actual="sha256:$(sha256_of "$TARGET/$f")"
  ```

#### C.4 Tests

Neue Datei `tests/shell/hash-lib.bats`:

```bats
@test "sha256_of computes correct hash" {
  src="$(mktemp)"
  printf 'hello\n' > "$src"
  source "$REPO_ROOT/scripts/lib/hash-lib.sh"
  got=$(sha256_of "$src")
  [ "$got" = "5891b5b522d5df086d0ff0b110fbd9d21bb4fc7163af34d08286a2e846f6be03" ]
}

@test "sha256_of handles paths with spaces" {
  src="$(mktemp -d)/file with spaces.txt"
  printf 'hello\n' > "$src"
  source "$REPO_ROOT/scripts/lib/hash-lib.sh"
  got=$(sha256_of "$src")
  [ "$got" = "5891b5b522d5df086d0ff0b110fbd9d21bb4fc7163af34d08286a2e846f6be03" ]
}
```

Bestehende `onboard-drift.bats` läuft danach auf beiden OS-Plattformen grün — verifizieren auf macOS lokal.

#### C.5 Risiken

- Sourcing-Reihenfolge: muss vor `set -e`/`set -u` Toleranz prüfen (Lib hat keine `local` außerhalb von Funktionen, kein State-Touch). Akzeptiert.
- Falls Konsumenten beider Scripts `hash-lib.sh` doppelt sourcen, ist `sha256_of()`-Redefinition harmlos (bash erlaubt es).

## 5. Interface Contracts (unverändert)

- `actions/onboard-detect/action.yml` — Inputs, Outputs, behavior unverändert. Nur `env:`-Block erweitert.
- `actions/onboard-render/action.yml` — Inputs, behavior unverändert. Step erhält neuen `id: render` (kein Breaking Change, niemand referenziert ihn heute).
- `scripts/onboard-detect.sh` — CLI-Interface unverändert. Verhalten bei leerer Release-Liste korrigiert.
- `scripts/lib/onboard-detect-lib.sh` — Library-Funktionsverhalten gleich, korrigierter null-Pfad.
- `scripts/onboard-render.sh` und `scripts/onboard-drift.sh` — CLI unverändert; sourcen jetzt zusätzlich `lib/hash-lib.sh`.
- `scripts/lib/hash-lib.sh` — NEU, internes Asset (kein public contract).

Kein Major-Bump nötig. Drei `fix:` / `refactor:` Conventional-Commits → release-please ergibt Patch-Bumps.

## 6. Test Strategy

| Test | Existiert | Wird ergänzt? |
|---|---|---|
| `tests/shell/onboard-detect.bats` — 32 Tests grün heute | ✓ | + 2 Tests für `current_version=0.0.0` bei leerer Release-Liste (gh-Mock); + 1 Test für EOF-Delimiter-Roundtrip |
| `tests/shell/onboard-render.bats` — Golden-Tests grün heute | ✓ | Bleibt unverändert |
| `tests/shell/onboard-drift.bats` — failt heute auf macOS | ✓ | Wird ohne Test-Änderung grün durch Concern C |
| `tests/shell/hash-lib.bats` (neu) | ✗ | 2 Unit-Tests für `sha256_of()` |

CI-Validation: alle Tests in `tests/shell/` müssen grün laufen. Lokal: einmal auf macOS, einmal in CI (Ubuntu).

## 7. PR Plan

Drei separate Branches, jeweils in eigenem Worktree, parallel offen:

### PR-A: `fix/onboard-actions-injection-hardening`
- **Worktree:** `.worktrees/onboard-actions-hardening`
- **Files:** `actions/onboard-detect/action.yml`, `actions/onboard-render/action.yml`, ggf. `tests/shell/onboard-detect.bats` (Delimiter-Test)
- **Commit:** `fix(onboard): harden composite-action inputs and GITHUB_OUTPUT delimiter`
- **Body:** Verweist auf CRIT-1, CRIT-2, CRIT-3 (ohne Review-Internas)

### PR-B: `fix/onboard-detect-null-current-version`
- **Worktree:** `.worktrees/onboard-null-version`
- **Files:** `scripts/onboard-detect.sh`, `scripts/lib/onboard-detect-lib.sh`, `tests/shell/onboard-detect.bats`
- **Commit:** `fix(onboard): treat empty gh-release-list "null" as no-release-found`

### PR-C: `refactor/extract-sha256-helper`
- **Worktree:** `.worktrees/hash-helper-extract`
- **Files:** `scripts/lib/hash-lib.sh` (neu), `scripts/onboard-render.sh`, `scripts/onboard-drift.sh`, `tests/shell/hash-lib.bats` (neu)
- **Commit:** `refactor(onboard): extract sha256_of() helper, fix drift on macOS`

Reihenfolge: PR-A → PR-B → PR-C (Sequenz nach Severity). Bei Bedarf parallel.

PR-Beschreibung folgt dem Repo-Stil ohne Claude-Attribution-Footer (Memory: `feedback_pr_style`).

## 8. Out-of-Scope-Observation (für spätere Phasen)

Bei der Action-Hardening-Arbeit wurde geprüft:
- `actions/setup-python-deps/action.yml` — `working-directory: ${{ inputs.working_directory }}` ist GHA-YAML-Level, kein Shell-Text-Interpolations-Vektor. Keine Hardening nötig.
- Andere `actions/*/action.yml` (`ghcr-login`, `install-trivy`, `compute-prerelease-tag`, `post-prerelease-comment`, `onboard-drift`) wurden im Review nicht als injection-anfällig geflaggt — sollten in Phase 6 (LOW + Refactor) noch einmal mit explizitem Audit überprüft werden.

## 9. Open Questions

Keine. Alle Entscheidungspunkte aus dem Brainstorming sind im Design fixiert:

1. ✓ Ein Spec / ein Plan / drei PRs
2. ✓ Drei Worktrees, sequenziell coden, gleichzeitig publishen
3. ✓ `setup-python-deps` nicht in Phase 1 (keine Injection-Klasse)
4. ✓ `printf '%s'`-Größenlimit akzeptiert für realistische Profile

## 10. Acceptance Criteria

Phase 1 ist abgeschlossen, wenn:

- [ ] PR-A merged: Beide onboard-Composite-Actions verarbeiten Inputs ohne Shell-Interpolation, `GITHUB_OUTPUT`-Delimiter ist random.
- [ ] PR-B merged: `tests/shell/onboard-detect.bats` enthält Tests für "no release found", die ohne Fix failen würden.
- [ ] PR-C merged: `scripts/lib/hash-lib.sh` existiert, beide Konsumenten sourcen es, `tests/shell/onboard-drift.bats` läuft auf macOS grün.
- [ ] `actionlint` und `yamllint` weiterhin grün auf allen geänderten Workflows / Actions.
- [ ] CI Integration-Test `test-onboard-dry-run` weiterhin grün.
- [ ] Drei Conventional-Commits produzieren erwartete release-please Version-Bumps (3× patch).
