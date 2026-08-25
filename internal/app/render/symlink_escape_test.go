package render

import (
	"context"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
)

// Audit H-3: ein Adopter-Repo, in dem `.github` ein Symlink nach aussen ist,
// liess BEIDE Engines den Lock und alle vier Workflow-Dateien ausserhalb des
// Checkouts schreiben — mit rc=0. Auf einem self-hosted Runner ist das ein
// Schreibvorgang an einen beliebigen Ort, den der Job erreichen kann; der
// anschliessende Commit im Adopter-Repo findet dann nichts.
//
// Der Bash-Renderer prueft dasselbe (scripts/onboard-render.sh,
// ensure_inside_target); bats haelt das dort fest. Die beiden Engines duerfen
// sich hier nicht unterscheiden — genau daran ist M-1 entstanden.

func skipIfNoSymlinks(t *testing.T) {
	t.Helper()
	if runtime.GOOS == "windows" {
		t.Skip("Symlinks verhalten sich unter Windows anders")
	}
}

func TestEnsureInsideTargetRejectsEscapingSymlink(t *testing.T) {
	skipIfNoSymlinks(t)

	base := t.TempDir()
	target := filepath.Join(base, "target")
	outside := filepath.Join(base, "outside")
	for _, d := range []string{target, outside} {
		if err := os.MkdirAll(d, 0o755); err != nil {
			t.Fatal(err)
		}
	}
	if err := os.Symlink(outside, filepath.Join(target, ".github")); err != nil {
		t.Fatal(err)
	}

	out := filepath.Join(target, ".github", "workflows", "ci.yml")
	err := ensureInsideTarget(target, out)
	if err == nil {
		t.Fatal("erwartet: Abweisung — der Pfad zeigt aus dem Ziel heraus")
	}
	if !strings.Contains(err.Error(), "outside the target") {
		t.Fatalf("Grund fehlt im Fehler: %v", err)
	}

	// Nichts darf angelegt worden sein: die Pruefung laeuft VOR jedem
	// MkdirAll, sonst entsteht das Verzeichnis draussen trotzdem. Der erste
	// Anlauf dieses Fixes prueft zu spaet und hinterliess `outside/workflows/`.
	entries, err := os.ReadDir(outside)
	if err != nil {
		t.Fatal(err)
	}
	if len(entries) != 0 {
		t.Fatalf("ausserhalb des Ziels wurde etwas angelegt: %v", entries)
	}
}

func TestEnsureInsideTargetRejectsSymlinkedOutputFile(t *testing.T) {
	skipIfNoSymlinks(t)

	base := t.TempDir()
	target := filepath.Join(base, "target")
	if err := os.MkdirAll(filepath.Join(target, ".github", "workflows"), 0o755); err != nil {
		t.Fatal(err)
	}
	victim := filepath.Join(base, "fremd.yml")
	if err := os.WriteFile(victim, []byte("gehoert mir nicht\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	out := filepath.Join(target, ".github", "workflows", "ci.yml")
	if err := os.Symlink(victim, out); err != nil {
		t.Fatal(err)
	}

	err := ensureInsideTarget(target, out)
	if err == nil || !strings.Contains(err.Error(), "through the symlink") {
		t.Fatalf("erwartet: Abweisung wegen Symlink-Zieldatei, bekommen: %v", err)
	}

	// Die fremde Datei bleibt unangetastet.
	got, err := os.ReadFile(victim)
	if err != nil {
		t.Fatal(err)
	}
	if string(got) != "gehoert mir nicht\n" {
		t.Fatalf("fremde Datei veraendert: %q", got)
	}
}

func TestEnsureInsideTargetAcceptsOrdinaryPaths(t *testing.T) {
	// Gegenprobe: die Pruefung darf den Normalfall nicht treffen — weder eine
	// noch nicht existierende Zieldatei noch ein noch nicht angelegtes
	// Unterverzeichnis.
	skipIfNoSymlinks(t)

	target := t.TempDir()
	for _, rel := range []string{
		"release-please-config.json",
		".github/workflows/ci.yml",
		".github/onboard.lock.json",
	} {
		out := filepath.Join(target, filepath.FromSlash(rel))
		if err := ensureInsideTarget(target, out); err != nil {
			t.Errorf("%s wurde abgewiesen: %v", rel, err)
		}
	}
}

func TestRenderCreatesAMissingTarget(t *testing.T) {
	// drift rendert in ein Temp-Verzeichnis, das beim Aufruf NOCH NICHT
	// existiert. `ensureInsideTarget` kann einen nicht existierenden Pfad nicht
	// aufloesen, also muss Render das Ziel vorher anlegen.
	//
	// Diese Luecke hat KEIN Test gefangen: die erste Fassung des Riegels liess
	// den go-cli-Drift-Pfad mit `render-failed: target path not resolvable`
	// zurueck, und die bats-Suite blieb trotzdem gruen. Deshalb hier ueber
	// Render und nicht ueber ensureInsideTarget direkt — die Regression sass
	// in der Verdrahtung, nicht in der Pruefung.
	catalog := renderCatalog(t, allTemplateFiles()...)
	profileDir := t.TempDir()
	profile := writeProfile(t, profileDir, `{
	  "schema_version": 1,
	  "target_repo": "serverkraken/example",
	  "default_branch": "main",
	  "current_version": "1.2.3",
	  "monorepo": false,
	  "topics": [],
	  "components": [{
	    "path": ".",
	    "primary_language": "go",
	    "release_please_type": "go",
	    "dockerfiles": [],
	    "release_signals": {}
	  }]
	}`)

	target := filepath.Join(t.TempDir(), "existiert-noch-nicht")
	if _, err := os.Stat(target); !os.IsNotExist(err) {
		t.Fatalf("der Test misst nichts, wenn das Ziel schon existiert: %v", err)
	}

	err := (Service{Templates: &fakeTemplates{}, Now: fixedNow}).
		Render(context.Background(), Request{
			CatalogPath:     catalog,
			TargetPath:      target,
			ProfileJSONPath: profile,
			PinVersion:      "v4",
		})
	if err != nil {
		t.Fatalf("ein noch nicht existierendes Ziel muss angelegt werden: %v", err)
	}
	if _, err := os.Stat(filepath.Join(target, ".github", "workflows", "ci.yml")); err != nil {
		t.Fatalf("ci.yml fehlt: %v", err)
	}
}
