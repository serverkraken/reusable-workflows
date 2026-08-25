package detect

import (
	"context"
	"os"
	"path/filepath"
	"runtime"
	"testing"
)

// Audit B-6 und B-10: Dateisystemfehler wurden waehrend der Erkennung zweifach
// verworfen — der WalkDirFunc gab bei `err != nil` einfach `nil` zurueck, und
// der Rueckgabewert von WalkDir landete in `_`. `os.ReadDir` in
// inventoryDockerfiles verhielt sich genauso.
//
// Gemessen gegen den Stand davor, mit `chmod 000` auf einem Unterverzeichnis:
//
//	zwei Go-Komponenten, eine unlesbar   -> nur eine im Profil, warnings: []
//	Komponente mit Dockerfile, unlesbar  -> dockerfiles: [], warnings: []
//
// Beides mit rc=0. Die Komponente verschwand lautlos, und die gerenderten
// Workflows haetten fuer sie keinen einzigen Job gehabt; das Image waere nie
// gebaut und nie gescannt worden.
//
// Abgebrochen wird NICHT: ein einzelnes unlesbares Verzeichnis — etwa ein
// root-eigenes Artefaktverzeichnis auf einem self-hosted Runner — soll das
// Onboarding nicht unmoeglich machen. Es soll nur nicht unsichtbar sein.

func skipIfRoot(t *testing.T) {
	t.Helper()
	if runtime.GOOS == "windows" {
		t.Skip("Dateirechte verhalten sich unter Windows anders")
	}
	if os.Geteuid() == 0 {
		// root liest auch ein 0000-Verzeichnis; der Test wuerde nichts messen.
		t.Skip("als root laesst sich ein unlesbares Verzeichnis nicht herstellen")
	}
}

func TestUnreadableComponentDirIsReported(t *testing.T) {
	skipIfRoot(t)

	repo := t.TempDir()
	for _, c := range []string{"services/api", "services/worker"} {
		dir := filepath.Join(repo, filepath.FromSlash(c))
		if err := os.MkdirAll(dir, 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(filepath.Join(dir, "go.mod"), []byte("module x\ngo 1.22\n"), 0o644); err != nil {
			t.Fatal(err)
		}
	}

	// Erst der Gutfall: beide Komponenten, keine Warnung.
	res, err := (Service{}).Detect(context.Background(), Request{RepoPath: repo})
	if err != nil {
		t.Fatal(err)
	}
	if got := componentPaths(res.Profile.Components); len(got) != 2 {
		t.Fatalf("paths=%v, erwartet zwei Komponenten", got)
	}
	for _, w := range res.Profile.Warnings {
		if w.Code == "path_unreadable" {
			t.Fatalf("unerwartete Warnung im Gutfall: %+v", w)
		}
	}

	worker := filepath.Join(repo, "services", "worker")
	if err := os.Chmod(worker, 0o000); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.Chmod(worker, 0o755) })

	res, err = (Service{}).Detect(context.Background(), Request{RepoPath: repo})
	if err != nil {
		t.Fatalf("ein unlesbares Verzeichnis darf das Onboarding nicht unmoeglich machen: %v", err)
	}

	var reported string
	for _, w := range res.Profile.Warnings {
		if w.Code == "path_unreadable" {
			reported = w.Path
		}
	}
	if reported == "" {
		t.Fatalf("keine path_unreadable-Warnung; Komponenten=%v, Warnungen=%+v",
			componentPaths(res.Profile.Components), res.Profile.Warnings)
	}
	if reported != "services/worker" {
		t.Errorf("Warnung nennt %q, erwartet services/worker", reported)
	}
}

func TestUnreadableDirIsNotAnEmptyDockerfileList(t *testing.T) {
	skipIfRoot(t)

	repo := t.TempDir()
	svc := filepath.Join(repo, "svc")
	if err := os.MkdirAll(filepath.Join(repo, ".github"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(svc, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(svc, "go.mod"), []byte("module x\ngo 1.22\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(svc, "Dockerfile"), []byte("FROM scratch\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	// Das Manifest haelt die Komponente fest, damit sie auch dann im Profil
	// steht, wenn ihr Verzeichnis nicht mehr lesbar ist — sonst waere gar
	// nichts da, an dem die leere Dockerfile-Liste zu sehen waere.
	manifestBody := "schema: 1\ncomponents:\n  - path: svc\n    language: go\n"
	if err := os.WriteFile(filepath.Join(repo, ".github", "onboard.yml"), []byte(manifestBody), 0o644); err != nil {
		t.Fatal(err)
	}

	if err := os.Chmod(svc, 0o000); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.Chmod(svc, 0o755) })

	res, err := (Service{}).Detect(context.Background(), Request{RepoPath: repo})
	if err != nil {
		t.Fatal(err)
	}
	if len(res.Profile.Components) != 1 {
		t.Fatalf("components=%+v", res.Profile.Components)
	}
	if n := len(res.Profile.Components[0].Dockerfiles); n != 0 {
		t.Fatalf("dockerfiles=%d — der Test misst nichts, wenn das Verzeichnis doch lesbar war", n)
	}
	found := false
	for _, w := range res.Profile.Warnings {
		if w.Code == "path_unreadable" {
			found = true
		}
	}
	if !found {
		t.Fatalf("eine leere Dockerfile-Liste aus einem unlesbaren Verzeichnis muss gemeldet werden; Warnungen=%+v",
			res.Profile.Warnings)
	}
}
