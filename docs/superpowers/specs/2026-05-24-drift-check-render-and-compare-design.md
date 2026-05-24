# Drift-Check Render-and-Compare (Design Spec)

**Datum:** 2026-05-24
**Quelle:** Discussion 2026-05-24 nach blupod-ui release startup_failure — drift-check meldete `clean` obwohl der Catalog-Renderer einen anderen `release.yml` produziert hätte als der im Adopter committed war.
**Scope:** Erweitert `actions/onboard-drift` und `scripts/onboard-drift.sh` um eine Render-and-Compare Detection. Neuer Status `stale-lock` signalisiert: Lock-Files matchen Working-Tree, aber Catalog-Renderer würde innerhalb desselben Majors andere Files produzieren.
**Konsumiert von:** Implementation Plan (writing-plans als Nachfolger). Spec ist Voraussetzung für den `onboard-sweep.yml` Auto-Update Workflow (Sweep braucht `stale-lock` als zweites Trigger-Signal neben `behind`).
**Vorgänger:** Phase 6 (PR-N #104 + PR-O #105 merged); kein direkter Vorgänger in dieser Linie.

---

## 1. Goal

Schließt eine Architektur-Lücke in `drift-check.yml`:

| Drift-Art | Heute erkannt? | Mit dem Spec? |
|---|---|---|
| Adopter hat hand-editiert (file-hash != lock-hash) | ✅ `modified` | ✅ unchanged |
| Adopter ist auf altem Catalog-Major (lock=v2, catalog=v3) | ✅ `behind` | ✅ unchanged |
| Lock + Files match, aber Catalog-Template hat sich innerhalb desselben Majors weiterentwickelt | ❌ `clean` (false negative) | ✅ **`stale-lock` (NEW)** |
| `.github/onboard.lock.json` fehlt komplett | ✅ `no-lock` | ✅ unchanged |

**Konkretes Beispiel (2026-05-24):** blupod-ui's `release.yml` matchte seinen Lock perfectly. Lock catalog_version=v3, current=v3 → drift-check sagt `clean`. **ABER:** Der Lock wurde gerendert vor PR #60 (2026-05-20), die `artifact-metadata: write` zu `docker-build-multi.yml` Top-Level-Permissions hinzufügte. Das Adopter `release.yml` hat das fehlende Permission nicht — beim ersten echten Release (0.14.3) → GHA strict-intersection-Check → `startup_failure`. **drift-check hätte das fangen müssen** und konnte es per Design nicht.

**Nicht Goal:**
- Auto-Fix der gefundenen `stale-lock` Adopter — das ist `onboard-sweep.yml`'s Aufgabe (eigener Spec)
- Lock-Schema-Migration auf Catalog-Commit-SHA-Tracking
- Adopter-Notification (Email, Slack, etc.) — drift-check's rolling Issue ist das einzige Signal

## 2. Scope

### In Scope

| Concern | Outcome |
|---|---|
| **C-1** Drift-Script Render-Block | `onboard-drift.sh` rendert templates frisch via `onboard-detect.sh --profile-json` + `onboard-render.sh`, vergleicht byte-für-byte gegen Adopter-Files |
| **C-2** Status-Detection | Wenn (und nur wenn) lock-comparison `clean` ergibt UND re-render abweicht: `status=stale-lock` |
| **C-3** Render-Error-Tolerance | Wenn der Re-Render selbst failed (gomplate missing, weird profile): status bleibt `clean`, neuer Output `render_error=<reason>` |
| **C-4** Composite Action Output | `actions/onboard-drift/action.yml` exponiert das neue `render_error` Output und updated die `status` Enum-Doku |
| **C-5** Drift-Check Workflow Publish-Job | `.github/workflows/drift-check.yml` rendert `stale-lock` distinct im rolling Issue + neue "Render error" Spalte |
| **C-6** Bats Coverage | 3 neue Tests in `tests/shell/onboard-drift.bats` |

### Out of Scope

- **Auto-Fix von `stale-lock` Adoptern** — `onboard-sweep.yml` (eigener Spec). Dieser Spec liefert nur das Signal.
- **Lock-Schema-Migration** auf Catalog-Commit-SHA. Render-and-compare subsumiert den Bedarf.
- **Notification-Mechanismen** über drift-check's Issue hinaus
- **Adopter-side rendering** (z.B. cron im Adopter selbst) — Catalog-zentralisiert bleiben

## 3. Background

### 3.1 Wie drift-check heute funktioniert

`scripts/onboard-drift.sh` (74 Zeilen):
1. Liest `<target>/.github/onboard.lock.json`
2. Vergleicht `lock_version` mit `$CATALOG_CURRENT_VERSION` env → `behind` flag
3. Für jeden File-Path in `.files[]`: vergleicht `sha256_of(<target>/<file>)` mit `lock.files[<file>]` → `modified_files` Liste
4. Kombiniert: `clean` | `modified` | `behind` | `behind+modified` | `no-lock`

Das Script-Header acknowledged die Limitation:
> Does NOT re-render templates — the reproducibility guarantee tested in bats means a clean target's hashes equal what a re-render **at the locked catalog_version** would emit.

Schlüsselwort: "at the locked catalog_version". Aber Catalog-Templates evolvieren *innerhalb* des Majors. Lock am Major-Pin (`v3`) ist nicht das gleiche wie Lock am Catalog-Commit (`cfd0b0b`).

### 3.2 Wieso die Lücke existiert

Lock-Format speichert `catalog_version: "v3"` — der floating Major. Aber innerhalb v3 hat es schon ≥12 Releases gegeben (3.0.0 bis 3.11.2 zum Zeitpunkt dieses Specs). Jedes Release kann Templates verändern (siehe PR #60: artifact-metadata permission added). Lock-vs-File comparison gibt `clean` zurück solange:
- Major stimmt
- Adopter files == was-renderer-bei-Lock-Erstellung-produzierte

Was der Adopter-File heute NICHT vergleicht: was-renderer-JETZT-produzieren-würde.

### 3.3 Wieso Render-and-Compare die richtige Antwort ist

Andere Optionen abgewogen:
- **Lock speichert Catalog Commit-SHA statt nur Major** — sensibilisiert auf jeden Commit, auch unbedeutende (e.g. docs-only changes touching templates). Zu noisy.
- **Lock speichert Templates-Hash** — sensitive auf Template-Änderung, ignoriert non-Template-Catalog-Änderungen. Aber: dann muss der Lock-Generator (`onboard-render.sh`) Template-Hashes berechnen, dazu Lock-Schema-Bump, dazu Migration aller bestehenden Locks.
- **Render-and-compare** — semantically perfect (catches anything that affects rendered output, ignores anything that doesn't). Costs ~1s per adopter per drift-check run. Acceptable.

### 3.4 Profile-Quelle für den Re-Render

`onboard-render.sh` braucht eine `profile.json` als Input. Optionen:
1. **Re-detect via `onboard-detect.sh --profile-json <target>`** ← gewählt
2. Profile im Lock-File speichern
3. Profile als `.github/onboard.profile.json` separat ablegen

Re-detect gewählt weil:
- Deterministisch für selben Adopter source state (verified via Phase 4 fixtures)
- Kein Lock-Schema-Change → keine Migration alter Locks
- Cost: ~1s pro Adopter (eine `gh api /repos/...` plus filesystem scan) — vernachlässigbar in einem 30min Drift-Check-Job

### 3.5 Wieso skip-render bei `behind`/`modified`/`no-lock`

- `behind` (lock_version != current) ist schon eindeutig drift. Re-render würde nur bestätigen → kein Mehrwert.
- `modified` (hand-edit) ist schon eindeutig drift. Re-render würde wahrscheinlich AUCH abweichen (weil hand-edits != renderer output), aber dieser Status soll Hand-Edit signalisieren, nicht stale-lock.
- `no-lock` — Adopter ist nicht onboarded, es gibt nichts zu rendern-und-vergleichen.

Nur `clean` führt zu `stale-lock` flip. Sauber, klares decision-tree.

## 4. Design per Concern

### 4.1 C-1 — `scripts/onboard-drift.sh` extended logic

Existing structure preserved. Add a render-and-compare block AFTER the lock-comparison block:

```bash
# ... (existing lock-comparison produces $status, $modified_files)

# NEW: render-and-compare check, only when status is currently 'clean'
render_error=""
if [[ "$status" == "clean" ]]; then
  scratch=$(mktemp -d)
  # Use a sub-trap so the existing script logic stays clean
  cleanup_scratch() { rm -rf "$scratch"; }
  trap cleanup_scratch EXIT

  # Step 1: re-detect profile from adopter source
  if ! "$CATALOG/scripts/onboard-detect.sh" --profile-json "$TARGET" \
       > "$scratch/profile.json" 2>"$scratch/detect.err"; then
    render_error="detect-failed:$(tr '\n' ' ' < "$scratch/detect.err" | cut -c1-80)"
  fi

  # Step 2: re-render templates against current catalog state
  if [[ -z "$render_error" ]]; then
    if ! "$CATALOG/scripts/onboard-render.sh" "$CATALOG" "$scratch/rendered" \
         "$scratch/profile.json" "$CURRENT" 2>"$scratch/render.err"; then
      render_error="render-failed:$(tr '\n' ' ' < "$scratch/render.err" | cut -c1-80)"
    fi
  fi

  # Step 3: byte-compare each lock-tracked file
  if [[ -z "$render_error" ]]; then
    stale_files=()
    while IFS= read -r f; do
      # Skip lock file itself if it's somehow self-tracked (defensive)
      [[ "$f" == ".github/onboard.lock.json" ]] && continue
      # Skip if the rendered tree doesn't contain this path (e.g. profile-conditional template)
      [[ -f "$scratch/rendered/$f" ]] || continue
      if ! cmp -s "$TARGET/$f" "$scratch/rendered/$f"; then
        stale_files+=("$f")
      fi
    done < <(jq -r '.files | keys[]' "$LOCK")

    if (( ${#stale_files[@]} > 0 )); then
      status="stale-lock"
      modified_files=("${stale_files[@]}")
    fi
  fi
fi

# ... (existing output emission, plus new line:)
echo "render_error=$render_error"
```

**Notes:**
- `render_error` value format: `<phase>:<first-80-chars-of-stderr>`. Compact enough for GHA-output single-line. Phases: `detect-failed` or `render-failed`.
- The error is truncated to 80 chars to keep the GHA output line bounded.
- Modified files are reused — the existing `modified=` output field carries the stale-divergent file list when `stale-lock` fires.
- The `cleanup_scratch` trap is registered after the existing setup; since `set -e` is in play, any failure in the new block triggers the trap.

**Lock-self-exclusion (Risk § 3.5):** verified — the existing render produces `onboard.lock.json` but the lock's `.files[]` object doesn't include itself (the lock tracks the rendered files, not its own hash). The defensive `[[ "$f" == ".github/onboard.lock.json" ]] && continue` in the loop is a belt-and-braces precaution.

### 4.2 C-4 — `actions/onboard-drift/action.yml`

Add to `outputs:`:
```yaml
  render_error:
    description: |
      Reason if the render-and-compare check could not run (empty when render
      succeeded or was skipped because status was already non-clean).
      Format: '<phase>:<truncated-stderr>' where phase ∈ {detect-failed, render-failed}.
    value: ${{ steps.drift.outputs.render_error }}
```

Update `outputs.status.description`:
```yaml
  status:
    description: |
      clean | modified | behind | behind+modified | no-lock | stale-lock

      stale-lock: lock hashes match working-tree files, but a fresh render of
      the catalog templates at the current catalog state would produce
      different output. Adopter needs re-onboarding to refresh the rendered
      files (and the lock).
    value: ${{ steps.drift.outputs.status }}
```

No changes to the `runs:` block — `onboard-drift.sh` does the new work.

### 4.3 C-5 — `.github/workflows/drift-check.yml` publish-job

Extend the per-target result JSON:

```yaml
      - name: Emit per-target result
        if: always()
        env:
          # ...existing env vars...
          RENDER_ERROR: ${{ steps.drift.outputs.render_error || '' }}
        run: |
          # ...existing setup...
          jq -n \
            --arg target "$TARGET" \
            --arg status "$STATUS" \
            --arg modified "$MODIFIED" \
            --arg lock_version "$LOCK_VERSION" \
            --arg render_error "$RENDER_ERROR" \
            --arg current "$CURRENT" \
            '{target:$target, status:$status, modified:$modified, lock_version:$lock_version, render_error:$render_error, current:$current}' \
            > "result/$safe.json"
```

In the `publish` job, extend the markdown table:

```bash
# Current header
echo "| Repo | Status | Catalog (lock → current) | Modified files |"
echo "|---|---|---|---|"

# Extended header
echo "| Repo | Status | Catalog (lock → current) | Modified files | Render error |"
echo "|---|---|---|---|---|"

# Per-target row generation: read render_error from JSON, render empty cell when no error
```

Status-icon map (in the publish-job bash):
```bash
case "$s" in
  clean) icon="✅" ;;
  modified) icon="✏️" ;;
  behind) icon="↩️" ;;
  behind+modified) icon="↩️✏️" ;;
  no-lock) icon="❓" ;;
  stale-lock) icon="⚠️" ;;        # NEW
  *) icon="🔥" ;;
esac
```

`stale-lock` gets ⚠️ to distinguish from `behind` ↩️ and `modified` ✏️.

### 4.4 C-6 — Bats Coverage

Three new tests at the end of `tests/shell/onboard-drift.bats`:

```bats
@test "drift: clean state stays clean when re-render matches lock files" {
  # Existing setup builds TARGET = rendered go-repo at v3 with matching lock.
  # The render block should run, produce identical output, status stays clean.
  CATALOG_CURRENT_VERSION=v3 run "$DRIFT" "$TARGET" "$REPO_ROOT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"status=clean"* ]]
  [[ "$output" == *"render_error="* ]]   # field present, value empty
}

@test "drift: clean state flips to stale-lock when catalog template evolves" {
  # Simulate template evolution: make a benign change to a template that
  # would surface in rendered output. Copy the catalog to scratch, edit
  # the copy, run drift against TARGET with the scratch-catalog as the
  # catalog source.
  scratch_catalog=$(mktemp -d)
  cp -R "$REPO_ROOT/." "$scratch_catalog/"
  # Append a benign change to ci.yml.tmpl
  echo "# stale-lock test marker $(date +%s%N)" \
    >> "$scratch_catalog/docs/adopter-templates/skeletons/ci.yml.tmpl"
  CATALOG_CURRENT_VERSION=v3 run "$DRIFT" "$TARGET" "$scratch_catalog"
  rm -rf "$scratch_catalog"
  [ "$status" -eq 0 ]
  [[ "$output" == *"status=stale-lock"* ]]
  # ci.yml should be in the modified list
  [[ "$output" == *"ci.yml"* ]]
}

@test "drift: render failure keeps status=clean and sets render_error" {
  # Strip gomplate from PATH → onboard-render.sh exits with "::error::gomplate not installed"
  fake_path=$(mktemp -d)
  # bare minimum: bash, jq, mktemp, sha256sum, cat — but NO gomplate
  for tool in bash jq mktemp sha256sum cat awk grep cut tr head find; do
    if cmd=$(command -v "$tool"); then
      ln -s "$cmd" "$fake_path/$tool"
    fi
  done
  CATALOG_CURRENT_VERSION=v3 PATH="$fake_path" run "$DRIFT" "$TARGET" "$REPO_ROOT"
  rm -rf "$fake_path"
  [ "$status" -eq 0 ]
  # status stays clean (no false positive)
  [[ "$output" == *"status=clean"* ]]
  # render_error captures the failure
  [[ "$output" =~ render_error=render-failed: ]]
}
```

After these additions: 11 tests total (8 existing + 3 new). All must pass on `bats tests/shell/onboard-drift.bats`.

## 5. Interface Contracts

| File | Change-class | Caller-Breaking? |
|---|---|---|
| `scripts/onboard-drift.sh` | Internal logic + 1 new output line (`render_error=`) | No — additive output |
| `actions/onboard-drift/action.yml` | New `render_error` output + status doc update | No — additive |
| `.github/workflows/drift-check.yml` | Extended result emission + extended publish table | No — operational workflow |
| `tests/shell/onboard-drift.bats` | +3 tests | No |
| `tests/fixtures/onboard/drift-clean/**` | UNCHANGED | — |

**Version impact:** `feat(drift-check):` → release-please default minor bump.

**Action consumer compatibility:** any consumer that reads `steps.drift.outputs.status` and case-splits on the existing 5 values gets a new 6th value (`stale-lock`). Existing exact-equality consumers (e.g. Phase 4's `caller-onboard-drift-happy.yml` which uses `[[ "$STATUS" != "clean" ]] && exit 1`) keep working because the drift-clean fixture's re-render still matches its lock (no template evolution between fixture-generation and current state for that specific fixture).

## 6. Test Strategy

| Surface | Verification |
|---|---|
| Drift-script logic | `bats tests/shell/onboard-drift.bats` — 11 tests green (8 existing + 3 new) |
| Existing reproducibility guarantee | Test #7 ("re-render at locked catalog_version is byte-reproducible") still green — proves render-and-compare doesn't break when files truly match |
| Composite action wrapper | `caller-onboard-drift-happy / drift` PR check green — drift-clean fixture's re-render matches lock → status=clean unchanged |
| End-to-end | After merge: `workflow_dispatch` drift-check.yml against all onboarded adopters; verify Issue posted has at least one `stale-lock` row (likely many, given Catalog has evolved since most adopter onboardings) |
| Lint | `validate.yml` PR check green (actionlint + yamllint) |

## 7. PR Plan

### Single PR — `feat/drift-render-and-compare`

- **Worktree:** `.worktrees/drift-render-compare`
- **Files:**
  - `scripts/onboard-drift.sh` (extended logic, ~25 line addition)
  - `actions/onboard-drift/action.yml` (new output + status doc update)
  - `.github/workflows/drift-check.yml` (extended publish job)
  - `tests/shell/onboard-drift.bats` (+3 tests)
- **Commits (4):**
  1. `feat(onboard-drift): render-and-compare for stale-lock detection`
  2. `feat(onboard-drift): expose render_error output on composite action`
  3. `feat(drift-check): surface stale-lock + render_error in rolling Issue`
  4. `test(onboard-drift): bats coverage for stale-lock and render_error`

PR-body style: kein Claude attribution footer.

## 8. Acceptance Criteria

- [ ] `bats tests/shell/onboard-drift.bats` green (11 tests)
- [ ] `bats tests/shell/onboard-render.bats` green (39 tests; drift-clean golden re-render still matches lock)
- [ ] `caller-onboard-drift-happy / drift` PR check green
- [ ] `validate.yml` PR check green
- [ ] Manual `workflow_dispatch` drift-check.yml after merge — Issue contains `stale-lock` row for at least one expected adopter (e.g. an adopter onboarded before PR #60); other adopters report `clean` or already-known statuses
- [ ] Version bump: minor (`feat(drift-check):` per release-please default)

## 9. Risks & Mitigations

| Risk | Likelihood | Mitigation |
|---|---|---|
| Re-render produces non-deterministic output (timestamp in template) → false-positive `stale-lock` every run | Medium | Existing `.github/onboard.lock.json` has `rendered_at` timestamp but is NOT in `.files[]` (lock doesn't self-track). Other templates use only profile-data + pin. If a template ever adds a timestamp, that's a renderer bug worth fixing — but defensive: confirm during implementation that no template embeds `now()` or `{{ date }}` constructs. |
| Re-detect produces a different profile than original (adopter added a Dockerfile) → re-render differs → `stale-lock` fires | Likely (= intended behavior) | This IS drift — adopter's source state changed, rendered output should reflect. `stale-lock` correctly signals "re-onboard to pick up your own change". |
| Render takes too long, drift-check matrix job hits timeout-minutes | Low | Existing timeout-minutes: 30; render is seconds per adopter. ~20 adopters → ~30-60s extra total. Safe. |
| `cmp -s` byte-comparison too strict (line-ending drift) | Low | Both renders happen on the same ubuntu-latest runner; gomplate produces deterministic output. If it bites: switch to sha256 compare with `[[ "$(sha256_of A)" == "$(sha256_of B)" ]]`. |
| Existing exact-equality consumers of `status` enum (e.g. Phase 4 caller) break on `stale-lock` | Low | Phase 4 `caller-onboard-drift-happy.yml` uses `[[ "$STATUS" != "clean" ]]`. Drift-clean's re-render matches lock → status stays `clean`. No break. Future consumers should case-split. |
| `.github/onboard.lock.json` itself differs every render (rendered_at) → false `stale-lock` | Mitigated | Lock isn't in its own `.files[]` (verified). Defensive `&& continue` for `.github/onboard.lock.json` in the cmp loop. |
| `onboard-detect.sh` is run twice in drift-check (once for current_version derivation, once for re-detect) → 2× `gh api` round-trip per adopter | Low | Existing drift-check already mints token + does enumerate per adopter. One extra `gh api` per adopter is < 200ms; trivial in a 30min job. Phase 5's `--emit-both` optimization is for action-context, not relevant here. |

## 10. Open Questions

Keine. Alle Brainstorming-Entscheidungen fixiert:

1. ✓ Profile-Quelle: re-detect via `onboard-detect.sh --profile-json`
2. ✓ Status-Name: `stale-lock`
3. ✓ Combination-Logik: skip re-render wenn `behind`/`modified`/`no-lock`
4. ✓ Error-Handling: fallback zu lock-only + `render_error` output field
5. ✓ Lock-self-exclusion: defensive `&& continue`, lock-self-tracking is moot in practice
6. ✓ Out-of-scope: auto-fix (→ onboard-sweep), schema-migration, notifications
