package detect

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// Audit H-4: der abgeleitete Image-Name nimmt nur das LETZTE Pfadsegment.
// `apps/api` und `services/api` ergeben damit beide `$REPO-api` — in beiden
// Engines nachgestellt.
//
// Beide Komponenten wuerden in dasselbe GHCR-Image pushen. Derselbe
// Versionstag zeigt danach auf den Build, der zufaellig zuletzt lief, und
// cleanup-images sieht ein Paket statt zweier: die Aufbewahrungsregeln greifen
// dann auf der falschen Menge.
//
// Abgewiesen statt automatisch entschaerft — dieselbe Entscheidung wie bei den
// kollidierenden Job-IDs (J-0b). Ein angehaengter Hash muesste fuer alle
// bestehenden Adopter stabil bleiben und waere in der Registry nicht mehr
// zuzuordnen; ein Abbruch mit beiden Pfaden im Text ist die ehrlichere
// Antwort.

func writeComponent(t *testing.T, repo, rel string) {
	t.Helper()
	dir := filepath.Join(repo, filepath.FromSlash(rel))
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, "go.mod"), []byte("module x\ngo 1.22\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, "Dockerfile"), []byte("FROM scratch\n"), 0o644); err != nil {
		t.Fatal(err)
	}
}

func TestDuplicateDerivedImageNameIsRejected(t *testing.T) {
	repo := t.TempDir()
	writeComponent(t, repo, "apps/api")
	writeComponent(t, repo, "services/api")

	_, err := (Service{}).Detect(context.Background(), Request{RepoPath: repo})
	if err == nil {
		t.Fatal("erwartet: Abbruch — zwei Komponenten wuerden in dasselbe Image pushen")
	}
	// Beide Pfade muessen im Text stehen: mit nur einem waere nicht zu sehen,
	// welche zwei sich in die Quere kommen.
	for _, want := range []string{"$REPO-api", "apps/api/Dockerfile", "services/api/Dockerfile", "rename"} {
		if !strings.Contains(err.Error(), want) {
			t.Errorf("Fehlertext nennt %q nicht: %v", want, err)
		}
	}
}

func TestDistinctDerivedImageNamesPass(t *testing.T) {
	// Gegenprobe: die Pruefung darf ein gewoehnliches Monorepo nicht treffen.
	repo := t.TempDir()
	writeComponent(t, repo, "services/api")
	writeComponent(t, repo, "services/worker")

	res, err := (Service{}).Detect(context.Background(), Request{RepoPath: repo})
	if err != nil {
		t.Fatalf("verschiedene Namen muessen durchgehen: %v", err)
	}
	if len(res.Profile.Components) != 2 {
		t.Fatalf("components=%+v", res.Profile.Components)
	}
}

func TestManifestRejectsTheSameCollisionItsOwnWay(t *testing.T) {
	// Der Ausweg ist NICHT `image:` im Manifest: der Validator dort weist
	// dieselbe Konstellation bereits mit einer eigenen Regel ab, weil das
	// letzte Pfadsegment zugleich der release-please-Paketname ist.
	//
	// Eine erste Fassung der Fehlermeldung riet zu `image:` und haette Adopter
	// auf einen Weg geschickt, den es gar nicht gibt. Dieser Test haelt fest,
	// welche der beiden Regeln greift — und dass ueberhaupt eine greift.
	repo := t.TempDir()
	writeComponent(t, repo, "apps/api")
	writeComponent(t, repo, "services/api")
	if err := os.MkdirAll(filepath.Join(repo, ".github"), 0o755); err != nil {
		t.Fatal(err)
	}
	manifestBody := "schema: 1\ncomponents:\n" +
		"  - path: apps/api\n    language: go\n    image: acme/app-api\n" +
		"  - path: services/api\n    language: go\n    image: acme/svc-api\n"
	if err := os.WriteFile(filepath.Join(repo, ".github", "onboard.yml"), []byte(manifestBody), 0o644); err != nil {
		t.Fatal(err)
	}

	_, err := (Service{}).Detect(context.Background(), Request{RepoPath: repo})
	if err == nil {
		t.Fatal("erwartet: Abbruch — kollidierende Basisnamen sind auch im Manifest verboten")
	}
	if !strings.Contains(err.Error(), "package name") {
		t.Fatalf("erwartet die Manifest-Regel, bekommen: %v", err)
	}
}

func TestRenamingResolvesTheCollision(t *testing.T) {
	// Der Ausweg, den die Meldung nennt, muss funktionieren.
	repo := t.TempDir()
	writeComponent(t, repo, "apps/app-api")
	writeComponent(t, repo, "services/svc-api")

	res, err := (Service{}).Detect(context.Background(), Request{RepoPath: repo})
	if err != nil {
		t.Fatalf("nach dem Umbenennen muss es durchgehen: %v", err)
	}
	if len(res.Profile.Components) != 2 {
		t.Fatalf("components=%+v", res.Profile.Components)
	}
}
