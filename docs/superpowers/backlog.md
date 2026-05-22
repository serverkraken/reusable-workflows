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
