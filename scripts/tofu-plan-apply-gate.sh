#!/usr/bin/env bash
# Entscheidet, ob tofu-plan-apply unter diesem Ereignis anwenden darf.
#
# Aufruf:
#   tofu-plan-apply-gate.sh <event_name> <ref_type> <require_tag>
#
#   event_name  — github.event_name
#   ref_type    — github.ref_type (`branch` | `tag`)
#   require_tag — `true` | `false`
#   Exit 0 — anwenden erlaubt
#   Exit 1 — abgelehnt, mit ::error:: auf stderr
#
# WARUM ALS SKRIPT UND NICHT INLINE: hier haengt dran, ob ein PR-Lauf oder ein
# gewoehnlicher Branch-Push Infrastruktur veraendert. Inline waere das nur
# ueber einen echten Workflow-Lauf je Ereignis pruefbar; so deckt
# tests/shell/tofu-plan-apply-gate.bats jedes Ereignis in beiden Stellungen
# von require_tag ab.
#
# DIE FREIGABE IST DER MERGE BZW. DER RELEASE, NICHT EIN KNOPF. Anders als
# tofu-apply (Dispatch mit Run-ID eines gelesenen Plans) laeuft dieses Atom
# automatisch, nachdem ein Mensch den Plan im PR gelesen und gemergt hat.
# Deshalb duerfen nur Ereignisse durch, hinter denen ein Merge steht:
#
#   push auf einen Tag, release   — ein Release-PR wurde gemergt (release-please)
#   push auf einen Branch         — nur mit require_tag=false: der Merge auf
#                                   den Branch IST die Freigabe
#   workflow_dispatch             — die Handlung eines Menschen, wie bei tofu-apply
#
# Nie: pull_request (fremder Code vor jedem Review), pull_request_target
# (fremder Code mit Secrets), workflow_run (kein sicherer ref-Vertrag),
# schedule (kein Mensch beteiligt).
set -euo pipefail

EVENT="${1:?event_name fehlt}"
REF_TYPE="${2:?ref_type fehlt}"
REQUIRE_TAG="${3:?require_tag fehlt}"

case "$REQUIRE_TAG" in
  true|false) ;;
  *)
    echo "::error::require_tag muss 'true' oder 'false' sein, nicht '${REQUIRE_TAG}'" >&2
    exit 1
    ;;
esac

case "$EVENT" in
  workflow_dispatch|repository_dispatch)
    # Die Handlung eines Menschen — dieselbe Freigabe wie bei tofu-apply.
    exit 0
    ;;
  release)
    exit 0
    ;;
  push)
    if [[ "$REF_TYPE" == "tag" ]]; then
      exit 0
    fi
    if [[ "$REQUIRE_TAG" == "true" ]]; then
      echo "::error::tofu-plan-apply laeuft mit require_tag=true nur auf einem Tag oder Release, dieser Push kommt von einem Branch" >&2
      echo "::error::entweder ein Release (z. B. release-please) ausloesen, oder require_tag=false setzen, wenn der Merge selbst die Freigabe sein soll" >&2
      exit 1
    fi
    exit 0
    ;;
  pull_request|pull_request_target|workflow_run|schedule)
    echo "::error::tofu-plan-apply darf nicht unter '${EVENT}' laufen" >&2
    echo "::error::ein Apply gehoert hinter einen Merge oder eine Handlung eines Menschen, nie vor ein Review oder in einen Zeitplan" >&2
    exit 1
    ;;
  *)
    echo "::error::tofu-plan-apply kennt das Ereignis '${EVENT}' nicht und lehnt es deshalb ab" >&2
    exit 1
    ;;
esac
