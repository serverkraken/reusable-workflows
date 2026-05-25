# Drift-Check: Skip `.release-please-manifest.json` from Compare (Design Spec)

**Datum:** 2026-05-25
**Quelle:** Issue #66 — skytrack-ui zeigt `✏️ modified | .release-please-manifest.json` im wöchentlichen Drift-Report, obwohl der Adopter nichts hand-editiert hat. release-please-action rewrited den Manifest by-design bei jedem Release.
**Scope:** Zwei skip-Lines in `scripts/onboard-drift.sh` (eine in jedem `.files{}`-Iterations-Loop) + zwei bats-Tests. Single PR, patch bump.
**Konsumiert von:** Implementation Plan (writing-plans als Nachfolger)
**Vorgänger:** PR #107 (render-and-compare) etablierte den lock-self-skip-Pattern, den dieser Spec für den Manifest replicated.

---

## 1. Goal

Verhindern, dass `.release-please-manifest.json` einen perpetuellen False-Positive im Drift-Report erzeugt.

| Heute | Mit dem Spec |
|---|---|
| Aktiver Release-Adopter sieht jeden Montag `✏️ modified` im Drift-Report | Manifest wird vom Drift-Compare ignoriert. `clean` bleibt `clean`. |
| Der "modified files" Spalte zeigt `.release-please-manifest.json` als Rauschen | Nur echte Hand-Edits surfacen |
| onboard-sweep würde solche `modified`-Adopter als skipped behandeln (richtig), aber der Mensch-Reviewer wird vom Rauschen abgelenkt | Drift-Report focused auf echte Aktion-Items |

**Nicht Goal:**
- Lock-Schema-Migration (Manifest aus `.files{}` rausnehmen). Drift-side Skip ist genug.
- Andere rendered files vom Compare exempten. `release-please-config.json` ist statisch — Hand-Edits dort sind echtes Drift, soll surfacen.
- Auto-Fix für Manifest-Konflikte. Wir flaggen einfach nichts mehr.

## 2. Scope

### In Scope

| Concern | Outcome |
|---|---|
| **C-1** Lock-compare loop skip | Zeile in `onboard-drift.sh` line 53-62: skip wenn `$f == ".release-please-manifest.json"` → kein `modified` durch Manifest-Mutation |
| **C-2** Render-compare loop skip | Existing PR #107 if-chain um den Manifest erweitern → kein `stale-lock` durch initial-vs-current Manifest-Inhalt |
| **C-3** Bats coverage | 2 neue Tests: modified-suppression + stale-lock-suppression |
| **C-4** Header docstring update | Doc-Comment im script reflektiert, welche files ignoriert werden |

### Out of Scope

- Lock-side removal des Manifest aus `.files{}` (würde alle bestehenden Adopter-Locks invalidieren)
- Konfigurierbarer drift_ignore-List im Lock-Schema (YAGNI für 1 File)
- `release-please-config.json` Skip (intentionally tracked — Hand-Edits sind echtes Drift)
- Spec-Aware Manifest-Check (z.B. "ignore Manifest unless `.` key is missing") — overengineering

## 3. Background

### 3.1 Warum der Manifest by-design mutiert wird

`release-please-action` läuft auf jedem Release-PR-Merge eines Adopters. Workflow:

1. Adopter committed conventional commits → release-please-action öffnet Release-PR
2. Release-PR landet → release-please-action erkennt `release_created`
3. release-please-action rewrites `.release-please-manifest.json` mit dem neuen Version-State: `{".": "0.32.0"}` (oder welche Version auch immer das Release-PR getaggt hat)
4. release-please-action erzeugt GitHub Release + Git Tag

Schritt 3 ist by-design — der Manifest IS das Single-Source-of-Truth für "auf welcher Version stehe ich". Er muss adopter-side sein, nicht catalog-side, weil jeder Adopter eine eigene Version-Timeline hat.

### 3.2 Wie der Manifest in den Lock kommt

`scripts/onboard-render.sh` rendert den Manifest beim ersten Onboarding (zeigt aufs Initial-Version):

```bash
# Line 86 of onboard-render.sh:
render "$CONFIGS/release-please-manifest.json.tmpl" "$TARGET/.release-please-manifest.json"

# Line 119-125: the RENDERED= array used to compute the lock's .files{}
RENDERED=(
  ".github/workflows/ci.yml"
  ".github/workflows/release.yml"
  ".github/workflows/prerelease.yml"
  ".github/workflows/cleanup.yml"
  "release-please-config.json"
  ".release-please-manifest.json"   # ← gets a sha256 in the lock
)
```

Beim ersten Onboarding ist der gespeicherte Hash korrekt (Adopter committed das Initial-Manifest in seinem Onboarding-PR). Sobald release-please-action das erste Release publisht, ändert sich der Manifest-Inhalt → Hash mismatch → Drift-Check meldet `modified`.

### 3.3 Warum beide Loops gepatched werden müssen

`onboard-drift.sh` iteriert `.files{}` an zwei Stellen:

**Loop 1 (lock-compare, lines 53-62):**
```bash
while IFS= read -r f; do
  ...
  expected=$(jq -r --arg k "$f" '.files[$k]' "$LOCK")
  actual="sha256:$(sha256_of "$TARGET/$f")"
  [[ "$expected" != "$actual" ]] && modified_files+=("$f")
done < <(jq -r '.files | keys[]' "$LOCK")
```

Hier fires `modified` heute false-positive für Manifest. → Skip-Line vor `expected=...`.

**Loop 2 (render-compare, lines 99-110, added in PR #107):**
```bash
while IFS= read -r f; do
  [[ "$f" == ".github/onboard.lock.json" ]] && continue
  [[ -f "$scratch/rendered/$f" ]] || continue
  if ! cmp -s "$TARGET/$f" "$scratch/rendered/$f"; then
    stale_files+=("$f")
  fi
done < <(jq -r '.files | keys[]' "$LOCK")
```

Hier WÜRDE `stale-lock` fires fail-positive, wenn der Manifest im Adopter (z.B. `{".": "0.32.0"}`) gegen den frisch gerenderten Initial-Manifest (`{".": "0.0.0"}`) diffed. → Skip-Line zur existing if-chain hinzufügen.

Both loops MUST skip the manifest, sonst verschiebt sich der False-Positive nur von der Lock-compare Phase (status=modified) in die Render-compare Phase (status=stale-lock) — gleiche Klasse Bug, andere Spalte im Issue.

### 3.4 Warum drift-side (nicht lock-side)

Drei Gründe:
1. **Drift-side wirkt sofort auf alle bestehenden Adopter-Locks.** Lock-side erfordert Re-Onboarding aller Adopter, damit ihre Locks den Manifest nicht mehr tracken.
2. **Lock-Reproduzierbarkeitstest bleibt valid.** Test `tests/shell/onboard-drift.bats:85` ("re-render at locked catalog_version is byte-reproducible") verifiziert die Lock-`.files{}` Hashes gegen frisch-gerenderten Output. Wenn der Manifest noch im Lock ist, deckt der Test ihn ab. Wenn wir ihn lock-side entfernen, schrumpft die Coverage des Reproducibility-Tests.
3. **Surgische 2-Line-Änderung** vs. invasives Refactoring der Render-Pipeline.

## 4. Design per Concern

### 4.1 C-1 — Lock-compare loop skip

Edit `scripts/onboard-drift.sh` lock-compare loop (around lines 53-62). Add skip BEFORE the missing-file check:

```bash
modified_files=()
while IFS= read -r f; do
  # .release-please-manifest.json is by-design mutated by release-please-action
  # on every release (rewrites the version-state object). Skip from compare so
  # active-release adopters don't show as perpetually modified.
  [[ "$f" == ".release-please-manifest.json" ]] && continue
  if [[ ! -f "$TARGET/$f" ]]; then
    modified_files+=("$f(missing)")
    continue
  fi
  expected=$(jq -r --arg k "$f" '.files[$k]' "$LOCK")
  actual="sha256:$(sha256_of "$TARGET/$f")"
  [[ "$expected" != "$actual" ]] && modified_files+=("$f")
done < <(jq -r '.files | keys[]' "$LOCK")
```

Single line addition. Comment explains the by-design mutation.

### 4.2 C-2 — Render-compare loop skip

Edit `scripts/onboard-drift.sh` render-compare loop (around lines 99-110). Extend the existing if-chain that already skips `.github/onboard.lock.json`:

```bash
    stale_files=()
    while IFS= read -r f; do
      # Lock should never track itself, but guard defensively.
      [[ "$f" == ".github/onboard.lock.json" ]] && continue
      # .release-please-manifest.json mutates by-design (see lock-compare loop).
      # Skip here too so the render-compare doesn't surface stale-lock for the
      # same reason.
      [[ "$f" == ".release-please-manifest.json" ]] && continue
      # If the rendered tree doesn't contain this path (profile-conditional
      # template), skip — we can't compare what doesn't exist on both sides.
      [[ -f "$scratch/rendered/$f" ]] || continue
      if ! cmp -s "$TARGET/$f" "$scratch/rendered/$f"; then
        stale_files+=("$f")
      fi
    done < <(jq -r '.files | keys[]' "$LOCK")
```

The new skip-line goes immediately after the existing `.github/onboard.lock.json` skip — parallel structure, same comment-pattern.

### 4.3 C-3 — Bats tests

Two new tests appended to `tests/shell/onboard-drift.bats`:

```bats
@test "drift: mutated .release-please-manifest.json does NOT count as modified" {
  # Simulate release-please updating the manifest after a release.
  echo '{".":"0.32.0"}' > "$TARGET/.release-please-manifest.json"
  CATALOG_CURRENT_VERSION=v3 run "$DRIFT" "$TARGET" "$REPO_ROOT"
  [ "$status" -eq 0 ]
  # Should still report clean — manifest is skipped from the lock-compare loop.
  [[ "$output" == *"status=clean"* ]]
  # And modified should NOT mention the manifest.
  [[ "$output" != *"release-please-manifest"* ]]
}

@test "drift: divergent manifest in render-compare does NOT count as stale-lock" {
  # Simulate a state where lock-compare clean, but render would produce different
  # manifest content. We achieve this by mutating the working-tree manifest to
  # match the lock's stored hash (lock stays valid), and the render at current
  # catalog state naturally produces the initial-state manifest different from
  # what release-please would have rewritten.
  #
  # Easiest reproducible setup: hand-edit the manifest then hand-update the lock
  # to record the new hash → lock-compare sees match → render-compare loop fires.
  echo '{".":"1.2.3"}' > "$TARGET/.release-please-manifest.json"
  new_hash="sha256:$(sha256_of "$TARGET/.release-please-manifest.json")"
  jq --arg h "$new_hash" '.files[".release-please-manifest.json"] = $h' \
    "$TARGET/.github/onboard.lock.json" > "$TARGET/.github/onboard.lock.json.new"
  mv "$TARGET/.github/onboard.lock.json.new" "$TARGET/.github/onboard.lock.json"

  CATALOG_CURRENT_VERSION=v3 run "$DRIFT" "$TARGET" "$REPO_ROOT"
  [ "$status" -eq 0 ]
  # Re-render would emit the original manifest from the template, which differs
  # from the working-tree's "1.2.3" content. Without the skip, this would fire
  # stale-lock; with the skip, status stays clean.
  [[ "$output" == *"status=clean"* ]]
  [[ "$output" != *"release-please-manifest"* ]]
}
```

Both tests live in the same bats file (`onboard-drift.bats`); current count is 11 → 13 after this PR.

### 4.4 C-4 — Header docstring update

Add a note to the script header explaining the manifest-skip alongside the existing lock-self-skip mention:

```bash
# onboard-drift.sh — compute drift status for a single adopter checkout.
#
# Compares the SHA-256 hashes in <target>/.github/onboard.lock.json against
# the working-tree contents of the same paths, plus catalog-version freshness.
# When lock-comparison says "clean", additionally re-renders the catalog
# templates at the current catalog state and byte-compares the result — if
# the renderer would now produce different files than what the lock recorded,
# emits status=stale-lock. This catches within-major template evolution that
# pure lock-comparison cannot see.
#
# Skipped from both compare loops (by-design adopter mutation):
#   - .github/onboard.lock.json     lock never self-tracks (defensive)
#   - .release-please-manifest.json release-please rewrites it on every release
#
# Usage:   onboard-drift.sh <target-path> <catalog-path>
# ...
```

Inline with the existing docstring structure.

## 5. Interface Contracts

| File | Change-class | Caller-Breaking? |
|---|---|---|
| `scripts/onboard-drift.sh` | 2 skip-lines + header update | NO — semantically narrows the set of files that can trigger `modified`/`stale-lock`. Consumers get fewer false-positives. |
| `tests/shell/onboard-drift.bats` | +2 tests | NO |
| `actions/onboard-drift/action.yml` | UNCHANGED | — |
| `.github/workflows/drift-check.yml` | UNCHANGED | — |

**Output enum unchanged.** The `status` values stay `clean | modified | behind | behind+modified | no-lock | stale-lock` — we just produce `clean` more often for adopters that previously surfaced as `modified` solely because of manifest churn.

**Version impact:** `fix(onboard-drift):` → release-please default = patch bump.

## 6. Test Strategy

| Surface | Verification |
|---|---|
| Existing 11 bats tests | Stay green — proves no behavioral regression for other drift scenarios |
| New test #12 (manifest mutated → still clean) | Catches the lock-compare-loop skip |
| New test #13 (manifest mutated + lock updated → still clean) | Catches the render-compare-loop skip |
| Drift-clean fixture (`tests/fixtures/onboard/drift-clean/`) | Smoke-check post-fix: `CATALOG_CURRENT_VERSION=v3 scripts/onboard-drift.sh tests/fixtures/onboard/drift-clean "$PWD"` still reports `status=clean` (the fixture has the initial manifest matching lock — no change expected) |
| `caller-onboard-drift-happy / drift` PR check | Stays green — drift-clean fixture untouched |
| Validate | actionlint + yamllint untouched (script-only change) |
| End-to-end post-merge | Trigger drift-check.yml — skytrack-ui's manifest-driven `modified` should disappear from the next Issue update |

## 7. PR Plan

### Single PR — `fix/drift-skip-release-please-manifest`

- **Worktree:** `.worktrees/drift-skip-manifest`
- **Files:** `scripts/onboard-drift.sh`, `tests/shell/onboard-drift.bats`
- **Commits (2):**
  1. `fix(onboard-drift): skip .release-please-manifest.json from compare loops (closes #66 follow-up)`
  2. `test(onboard-drift): bats coverage for manifest-skip in modified + stale-lock paths`

PR-Body-Style: kein Claude-Attribution-Footer.

## 8. Acceptance Criteria

- [ ] `bats tests/shell/onboard-drift.bats` green (13 tests — 11 existing + 2 new)
- [ ] `bats tests/shell/` full suite green (no cross-test pollution)
- [ ] drift-clean smoke-check: `scripts/onboard-drift.sh tests/fixtures/onboard/drift-clean "$PWD"` reports `status=clean` (unchanged from today)
- [ ] `caller-onboard-drift-happy / drift` PR check green
- [ ] `validate.yml` PR check green
- [ ] Post-merge: dispatch drift-check.yml — verify skytrack-ui (or any active-release adopter) NO LONGER shows `release-please-manifest.json` in "Modified files" column

## 9. Risks & Mitigations

| Risk | Likelihood | Mitigation |
|---|---|---|
| Adopter genuinely hand-edits manifest (rare — e.g. corrects a wrong version) | Low | This becomes invisible to drift-check. Acceptable — corrects-against-prior-state isn't really "drift" anyway, and release-please will overwrite on the next release. |
| Future file is added to RENDERED that ALSO needs by-design-mutation skip | Possible | Pattern is now established (two skip-lines, two locations). Adding a third file is a copy-paste. The configurable drift_ignore-list option (rejected in this spec as YAGNI) can be revisited if we hit 3+ files. |
| Skip-line typo (e.g. wrong file name) | Low | Bats tests assert the exact filename strings appear/don't appear in output. |
| Lock-side and drift-side go out of sync (manifest STILL in lock's .files{} but drift skips it) | Acceptable | Lock entry remains useful for the reproducibility test (`tests/shell/onboard-drift.bats:85`). The cost is minimal: one extra hash entry in lock + one entry we never iterate against. |

## 10. Open Questions

Keine. Alle Entscheidungen aus dem Brainstorm fixiert:

1. ✓ Approach: drift-side skip (not lock-side removal)
2. ✓ Scope: nur `.release-please-manifest.json` (nicht config, nicht configurable list)
3. ✓ Beide Loops gepatched (lock-compare + render-compare)
4. ✓ Header docstring updated parallel zur lock-self-skip Doku
