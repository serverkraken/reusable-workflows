# Spec Backlog

Spec-Kandidaten, die aus laufenden Brainstorms bewusst ausgeklammert wurden. Jeder Eintrag ist ein potenzieller eigener Spec — Reihenfolge ist nicht festgelegt.

## Repo-Hygiene-Bootstrapping

Während des Onboardings zusätzlich setzen:
- `CODEOWNERS` (falls fehlt)
- Branch-Protection-Regeln auf dem Default-Branch (required checks aus Atom-Set)
- PR-Template (`.github/pull_request_template.md`)
- Standard-Labels (`type:bug`, `type:feat`, `release-please:*`)

- **Warum ausgeklammert:** Thematisch GitHub-Repo-Verwaltung, nicht Workflow-Rendering. Eigene Risiken (Branch-Protection-API erfordert `administration` Permission auf dem App-Token, anderes Berechtigungsbild).
- **Scope eines Folge-Specs:** dritter PR-Pfad (`Branch C — repo hygiene`) im `onboard.yml`, neben Add- und Cleanup-PR. App-Token-Berechtigungen erweitern. Bedingt rendern (nur wenn fehlt).
- **Abhängigkeiten:** Detection muss erkennen, ob `CODEOWNERS` / Branch-Protection bereits vorhanden ist — kommt mit dem `repo_hygiene`-Feld aus Spec "Smarter Onboarding".

## PR-Comment-Retries (`/onboard rerun`)

Adopter triggern Onboarding-Reruns per Kommentar in einem bestehenden Onboarding-PR (`/onboard rerun`, `/onboard dry-run`).

- **Warum ausgeklammert:** UX-Politur. Heute genügt der zentrale `workflow_dispatch`.
- **Scope eines Folge-Specs:** `issue_comment`-Trigger im `onboard.yml`, Kommando-Parser, Re-Dispatch des Matrix-Targets. Achtung: `issue_comment`-Auth-Modell weicht von `workflow_dispatch` ab.
- **Abhängigkeiten:** Keine.
- **Referenz:** `2026-05-16-onboarding-workflow-design.md` § "Out of scope (future)".

## Rollback / Un-Onboard

Geordneter Rückzug eines Adopter-Repos aus dem Reusable-Catalog (gerenderte Dateien wieder entfernen, ggf. Legacy-Workflows wiederherstellen).

- **Warum ausgeklammert:** Heute deckt `git revert` des Add-PRs den Bedarf ab. Echter Un-Onboard-Workflow wird erst relevant, wenn ein Adopter länger drin war und seinen Stand stark verändert hat.
- **Scope eines Folge-Specs:** inverser Renderer; löscht gerenderte Dateien, signalisiert Legacy-Restore aus Git-History.
- **Abhängigkeiten:** Keine.
- **Referenz:** `2026-05-16-onboarding-workflow-design.md` § "Out of scope (future)".

## cosign Rekor-409 idempotent behandeln (Image-Signing)

Der cosign-Signing-Step im Multi-Arch-Image-Pfad (`docker-build-multi.yml` merge-Job, ggf. auch `docker-build.yml`) behandelt einen Rekor-`409 createLogEntryConflict` ("an equivalent entry already exists in the transparency log") als harten Fehler. Auslöser: ein Netzwerk-Hänger (`Failed to restore: Premature close`) zwingt cosign zu einem internen Retry — der erste Versuch schreibt den Transparency-Log-Eintrag, die Antwort geht verloren, der Retry kollidiert mit dem bereits existierenden Eintrag → 409 → Job rot, obwohl das Image korrekt signiert ist.

- **Warum ausgeklammert:** Reines Flake-Hardening, kein Feature. Tritt selten auf (1× in ~5 integration-Runs am 2026-05-28). Aktueller Workaround: Job re-runnen (lief sofort grün).
- **Scope eines Folge-Specs:** Im Signing-Pfad den cosign-Fehler auf `409`/`createLogEntryConflict` prüfen und idempotent als Erfolg werten (der Eintrag IST signiert). Entweder cosign-eigene Retry/Idempotenz-Optionen nutzen oder den Step in einen Wrapper fassen, der einen 409 abfängt und `exit 0` macht. **Betrifft alle Adopter, die Images signieren — Catalog-weit, nicht PR-lokal.**
- **Abhängigkeiten:** Keine. Gegen ein deterministisch reproduzierbares Fixture-Image testen (denselben Digest mehrfach signieren, 409 erzwingen).
- **Referenz:** Fehlerlauf `actions/runs/26575638022/job/78300930257` (2026-05-28, `test-docker-build-multi` merge-Job); cosign-attest-swap-Kontext in `2026-05-25-cosign-attest-swap-design.md`.
