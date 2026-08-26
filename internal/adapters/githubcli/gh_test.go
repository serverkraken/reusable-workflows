package githubcli

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
)

func TestClientUsesGHExecutable(t *testing.T) {
	withFakeGH(t, `#!/usr/bin/env bash
set -euo pipefail
if [[ "$1 $2 $3" == "api /repos/o/r -q" ]]; then
  echo trunk
elif [[ "$1 $2 $3" == "release list --repo" ]]; then
  echo v1.2.3
elif [[ "$1 $2 $3" == "api /repos/o/r/topics -q" ]]; then
  echo '["a","b"]'
else
  echo "unexpected: $*" >&2
  exit 9
fi
`)
	c := Client{}
	branch, err := c.DefaultBranch(context.Background(), "o/r")
	if err != nil || branch != "trunk" {
		t.Fatalf("branch=%q err=%v", branch, err)
	}
	version, err := c.LatestStableRelease(context.Background(), "o/r")
	if err != nil || version != "1.2.3" {
		t.Fatalf("version=%q err=%v", version, err)
	}
	topics, err := c.Topics(context.Background(), "o/r")
	if err != nil || !reflect.DeepEqual(topics, []string{"a", "b"}) {
		t.Fatalf("topics=%v err=%v", topics, err)
	}
}

func TestClientFallbacksAndErrors(t *testing.T) {
	withFakeGH(t, `#!/usr/bin/env bash
set -euo pipefail
if [[ "$1" == "api" && "$2" == "/repos/o/r" ]]; then
  echo "boom" >&2
  exit 7
elif [[ "$1" == "release" ]]; then
  echo null
elif [[ "$1" == "api" && "$2" == "/repos/o/r/topics" ]]; then
  echo "forbidden" >&2
  exit 8
elif [[ "$*" == "api /repos/o/r/branches/main/protection" ]]; then
  echo "gh: Forbidden (HTTP 403)" >&2
  exit 1
fi
`)
	c := Client{}
	if _, err := c.DefaultBranch(context.Background(), "o/r"); err == nil || !strings.Contains(err.Error(), "boom") {
		t.Fatalf("expected branch error, got %v", err)
	}
	if version, err := c.LatestStableRelease(context.Background(), "o/r"); err != nil || version != "0.0.0" {
		t.Fatalf("version=%q err=%v", version, err)
	}
	if topics, err := c.Topics(context.Background(), "o/r"); err == nil || !strings.Contains(err.Error(), "forbidden") || topics != nil {
		t.Fatalf("topics=%v err=%v (expected propagated read error)", topics, err)
	}
	if raw, missing, err := c.BranchProtection(context.Background(), "o/r", "main"); err == nil || missing || raw != nil || !strings.Contains(err.Error(), "HTTP 403") {
		t.Fatalf("raw=%s missing=%v err=%v (expected propagated 403)", raw, missing, err)
	}
}

func TestClientNullAndEmptyFallbacks(t *testing.T) {
	withFakeGH(t, `#!/usr/bin/env bash
set -euo pipefail
if [[ "$1" == "api" && "$2" == "/repos/o/r" ]]; then
  echo null
elif [[ "$1" == "release" ]]; then
  echo ''
elif [[ "$1" == "api" && "$2" == "/repos/o/r/topics" ]]; then
  echo null
fi
`)
	c := Client{}
	if branch, err := c.DefaultBranch(context.Background(), "o/r"); err != nil || branch != "main" {
		t.Fatalf("branch=%q err=%v", branch, err)
	}
	if version, err := c.LatestStableRelease(context.Background(), "o/r"); err != nil || version != "0.0.0" {
		t.Fatalf("version=%q err=%v", version, err)
	}
	if topics, err := c.Topics(context.Background(), "o/r"); err != nil || len(topics) != 0 {
		t.Fatalf("topics=%v err=%v", topics, err)
	}
}

func TestRunReportsCommandLookupFailure(t *testing.T) {
	t.Setenv("PATH", t.TempDir())
	if _, err := run(context.Background(), "gh", "--version"); err == nil {
		t.Fatal("expected command lookup failure")
	}
}

func TestClientRejectsInvalidTopicsJSON(t *testing.T) {
	withFakeGH(t, `#!/usr/bin/env bash
set -euo pipefail
if [[ "$1" == "api" && "$2" == "/repos/o/r/topics" ]]; then
  echo '{'
else
  echo main
fi
`)
	if _, err := (Client{}).Topics(context.Background(), "o/r"); err == nil {
		t.Fatal("expected invalid JSON error")
	}
}

func TestClientRepoDefaultsAPI(t *testing.T) {
	withFakeGH(t, `#!/usr/bin/env bash
set -euo pipefail
if [[ "$*" == "api /repos/o/r" ]]; then
  echo '{"default_branch":"trunk","delete_branch_on_merge":false,"allow_merge_commit":true,"has_issues":true}'
elif [[ "$*" == "api /repos/o/r/branches/trunk/protection" ]]; then
  echo '{"enforce_admins":{"enabled":false}}'
elif [[ "$*" == "api -X PUT /repos/o/r/branches/trunk/protection --input -" ]]; then
  payload="$(cat)"
  [[ "$payload" == *required_linear_history* ]]
  echo '{"ok":true}'
elif [[ "$*" == "api -X PUT /repos/o/r/topics --input -" ]]; then
  payload="$(cat)"
  [[ "$payload" == '{"names":["a","b"]}' ]]
  echo '{"ok":true}'
elif [[ "$*" == "api -X PATCH /repos/o/r --input -" ]]; then
  payload="$(cat)"
  [[ "$payload" == '{"delete_branch_on_merge":true}' ]]
  echo '{"ok":true}'
else
  echo "unexpected: $*" >&2
  exit 9
fi
`)
	c := Client{}
	meta, err := c.RepoMetadata(context.Background(), "o/r")
	if err != nil || meta.DefaultBranch != "trunk" || !meta.AllowMergeCommit {
		t.Fatalf("meta=%+v err=%v", meta, err)
	}
	raw, missing, err := c.BranchProtection(context.Background(), "o/r", "trunk")
	if err != nil || missing || !json.Valid(raw) {
		t.Fatalf("protection raw=%s missing=%v err=%v", raw, missing, err)
	}
	if err := c.UpdateBranchProtection(context.Background(), "o/r", "trunk", []byte(`{"required_linear_history":true}`)); err != nil {
		t.Fatal(err)
	}
	if err := c.ReplaceTopics(context.Background(), "o/r", []string{"a", "b"}); err != nil {
		t.Fatal(err)
	}
	if err := c.PatchRepository(context.Background(), "o/r", []byte(`{"delete_branch_on_merge":true}`)); err != nil {
		t.Fatal(err)
	}
}

func TestClientRepoDefaultsFallbacksAndErrors(t *testing.T) {
	withFakeGH(t, `#!/usr/bin/env bash
set -euo pipefail
if [[ "$*" == "api /repos/o/r" ]]; then
  echo "forbidden" >&2
  exit 7
elif [[ "$*" == "api /repos/o/r/branches/main/protection" ]]; then
  echo '{"message":"Branch not protected"}'
  echo "gh: HTTP 404" >&2
  exit 1
elif [[ "$*" == "api -X PATCH /repos/o/r --input -" ]]; then
  echo "nope" >&2
  exit 8
fi
`)
	c := Client{}
	if _, err := c.RepoMetadata(context.Background(), "o/r"); err == nil || !strings.Contains(err.Error(), "forbidden") {
		t.Fatalf("metadata err=%v", err)
	}
	raw, missing, err := c.BranchProtection(context.Background(), "o/r", "main")
	if err != nil || !missing || raw != nil {
		t.Fatalf("raw=%s missing=%v err=%v", raw, missing, err)
	}
	if err := c.PatchRepository(context.Background(), "o/r", []byte(`{}`)); err == nil || !strings.Contains(err.Error(), "nope") {
		t.Fatalf("patch err=%v", err)
	}
}

func TestClientRepoDefaultsInvalidJSONAndLookupError(t *testing.T) {
	withFakeGH(t, `#!/usr/bin/env bash
set -euo pipefail
if [[ "$*" == "api /repos/o/r" ]]; then
  echo '{'
else
  echo '{"ok":true}'
fi
`)
	if _, err := (Client{}).RepoMetadata(context.Background(), "o/r"); err == nil {
		t.Fatal("expected metadata JSON error")
	}
	t.Setenv("PATH", t.TempDir())
	if err := (Client{}).PatchRepository(context.Background(), "o/r", []byte(`{}`)); err == nil {
		t.Fatal("expected gh lookup error")
	}
}

func withFakeGH(t *testing.T, script string) {
	t.Helper()
	dir := t.TempDir()
	path := filepath.Join(dir, "gh")
	if err := os.WriteFile(path, []byte(script), 0755); err != nil {
		t.Fatal(err)
	}
	old := os.Getenv("PATH")
	t.Setenv("PATH", dir+string(os.PathListSeparator)+old)
}

// Audit L-7: ReleaseTags hatte keinen einzigen direkten Adaptertest — weder für
// den Aufruf noch für das Zerlegen der Antwort noch für den Fehlerfall.
//
// Der Fehlerfall war dabei der wichtigste: der Adapter gab `nil, nil` zurück,
// womit der Fehlerzweig in detect.Service ("could not list releases for %s")
// toter Code war. Ein Ausfall der Tag-Abfrage sah aus wie "dieses Repo hat
// keine Tags", und das Onboarding säte die Version aus einer leeren Liste.
func TestClientReleaseTagsRequestAndParsing(t *testing.T) {
	argvFile := filepath.Join(t.TempDir(), "argv")
	t.Setenv("FAKE_GH_ARGV", argvFile)
	withFakeGH(t, `#!/usr/bin/env bash
set -euo pipefail
# Die Anfrage selbst festhalten, nicht nur die Antwort: --paginate fehlt sonst
# unbemerkt, und ein Repo mit mehr als einer Tag-Seite verliert die Haelfte.
echo "$*" > "$FAKE_GH_ARGV"
printf 'v1.2.3\n\nnull\n  controller-v2.5.2  \n'
`)
	c := Client{}
	tags, err := c.ReleaseTags(context.Background(), "o/r")
	if err != nil {
		t.Fatalf("unerwarteter Fehler: %v", err)
	}
	// Leerzeilen und "null" fallen raus, Rand-Leerzeichen werden getrimmt.
	want := []string{"v1.2.3", "controller-v2.5.2"}
	if !reflect.DeepEqual(tags, want) {
		t.Fatalf("tags=%v, erwartet %v", tags, want)
	}

	argv, rerr := os.ReadFile(argvFile)
	if rerr != nil {
		t.Fatalf("argv nicht lesbar: %v", rerr)
	}
	got := strings.TrimSpace(string(argv))
	// Tags, nicht Releases: release-please haengt an Tags, und eine Komponente
	// darf mit einem blossen Tag ohne Release-Objekt geseedet sein.
	for _, want := range []string{"api", "--paginate", "/repos/o/r/tags", "-q", ".[].name"} {
		if !strings.Contains(got, want) {
			t.Fatalf("Aufruf %q enthaelt %q nicht", got, want)
		}
	}
	if strings.Contains(got, "release list") {
		t.Fatalf("es wurden Releases statt Tags abgefragt: %q", got)
	}
}

func TestClientReleaseTagsPropagatesFailure(t *testing.T) {
	withFakeGH(t, `#!/usr/bin/env bash
echo "gh: Bad credentials (HTTP 401)" >&2
exit 1
`)
	tags, err := Client{}.ReleaseTags(context.Background(), "o/r")
	if err == nil {
		t.Fatal("ein fehlgeschlagener Aufruf muss einen Fehler liefern, keine leere Liste")
	}
	if tags != nil {
		t.Fatalf("bei einem Fehler duerfen keine Tags zurueckkommen, war: %v", tags)
	}
}

// Gleiche Klasse wie I-11, hier auf der Go-Seite: "0.0.0" ist die richtige
// Antwort auf "noch kein Release" — als Antwort auf "die Abfrage ist
// fehlgeschlagen" saet das Onboarding damit eine Version, und ein Repo, das
// laengst bei v2 steht, faengt wieder bei null an.
func TestClientLatestStableReleaseDistinguishesEmptyFromFailure(t *testing.T) {
	withFakeGH(t, `#!/usr/bin/env bash
exit 1
`)
	if _, err := (Client{}).LatestStableRelease(context.Background(), "o/r"); err == nil {
		t.Fatal("ein fehlgeschlagener Aufruf muss einen Fehler liefern, nicht 0.0.0")
	}

	// Die LEERE Antwort bleibt 0.0.0 — die ist echt und darf nicht scheitern.
	withFakeGH(t, `#!/usr/bin/env bash
echo ""
`)
	v, err := (Client{}).LatestStableRelease(context.Background(), "o/r")
	if err != nil || v != "0.0.0" {
		t.Fatalf("leere Antwort: v=%q err=%v, erwartet 0.0.0 ohne Fehler", v, err)
	}
}
