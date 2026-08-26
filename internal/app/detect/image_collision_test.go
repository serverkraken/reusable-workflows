package detect

import (
	"context"
	"os"
	"path/filepath"
	"sort"
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

// Gefunden ueber das Suchmuster "nicht-injektive Abbildung", nicht ueber die
// Fundliste: checkImageNameCollisions oben fing die Basename-Kollision nur,
// wenn beide Komponenten ein Dockerfile tragen — ueber den daraus abgeleiteten
// Image-Namen. OHNE Dockerfiles gab es nichts zu vergleichen, und die
// gerenderte release-please-config.json sah so aus:
//
//	apps/api      -> package-name: api
//	services/api  -> package-name: api
//
// release-please erzeugt daraus fuer beide Tags `api-vX.Y.Z`. Zwei Komponenten
// teilen sich eine Versionsreihe.

func writeGoComponent(t *testing.T, repo, rel string) {
	t.Helper()
	dir := filepath.Join(repo, filepath.FromSlash(rel))
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, "go.mod"), []byte("module x\ngo 1.22\n"), 0o644); err != nil {
		t.Fatal(err)
	}
}

func TestDuplicatePackageNameWithoutDockerfilesIsRejected(t *testing.T) {
	repo := t.TempDir()
	writeGoComponent(t, repo, "apps/api")
	writeGoComponent(t, repo, "services/api")

	_, err := (Service{}).Detect(context.Background(), Request{RepoPath: repo})
	if err == nil {
		t.Fatal("erwartet: Abbruch — beide Komponenten bekaemen den Paketnamen \"api\"")
	}
	for _, want := range []string{"package name", "apps/api", "services/api", "rename"} {
		if !strings.Contains(err.Error(), want) {
			t.Errorf("Fehlertext nennt %q nicht: %v", want, err)
		}
	}
}

func TestDistinctPackageNamesPass(t *testing.T) {
	// Gegenprobe: ein gewoehnliches Monorepo darf die Pruefung nicht treffen.
	repo := t.TempDir()
	writeGoComponent(t, repo, "services/api")
	writeGoComponent(t, repo, "services/worker")

	res, err := (Service{}).Detect(context.Background(), Request{RepoPath: repo})
	if err != nil {
		t.Fatalf("verschiedene Paketnamen muessen durchgehen: %v", err)
	}
	if len(res.Profile.Components) != 2 {
		t.Fatalf("components=%+v", res.Profile.Components)
	}
}

func TestRootComponentIsExemptFromPackageNameCheck(t *testing.T) {
	// Die Wurzel traegt keinen Paketnamen aus dem Pfad — genau wie im Manifest.
	// Ein Repo mit Wurzelkomponente und einem gleichnamigen Unterordner darf
	// nicht abgewiesen werden.
	repo := t.TempDir()
	if err := os.WriteFile(filepath.Join(repo, "go.mod"), []byte("module x\ngo 1.22\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if _, err := (Service{}).Detect(context.Background(), Request{RepoPath: repo}); err != nil {
		t.Fatalf("eine reine Wurzelkomponente muss durchgehen: %v", err)
	}
}

// Audit H-17: OCI-Namen sind kleingeschrieben. Ein Verzeichnis
// `services/MyService` ergab `$REPO-MyService`, und das landete unveraendert
// im gerenderten `image_name` UND im GHCR-`package_name`:
//
//	image_name:   upper-out-MyService
//	package_name: ${{ github.event.repository.name }}-MyService
//
// Die Templates lowercasen dieselbe Quelle laengst fuer das Job-ID-Suffix
// (`strings.ToLower $base`) — die Herleitung tat es nicht.
//
// Nicht empirisch gegen eine Registry geprueft (lokal ist keine
// OCI-Werkzeugkette vorhanden); die Grammatik der Distribution-Spec laesst im
// Repository-Namen nur [a-z0-9] plus Trenner zu. Verifiziert ist das
// RENDERING.

func TestDerivedImageNameIsLowercased(t *testing.T) {
	repo := t.TempDir()
	dir := filepath.Join(repo, "services", "MyService")
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, "go.mod"), []byte("module x\ngo 1.22\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, "Dockerfile"), []byte("FROM scratch\n"), 0o644); err != nil {
		t.Fatal(err)
	}

	res, err := (Service{}).Detect(context.Background(), Request{RepoPath: repo})
	if err != nil {
		t.Fatal(err)
	}
	got := res.Profile.Components[0].Dockerfiles[0].ImageName
	if got != "$REPO-myservice" {
		t.Fatalf("image_name=%q, erwartet $REPO-myservice", got)
	}
	// Der Komponentenpfad selbst bleibt, wie er auf der Platte heisst — er ist
	// ein Pfad, kein Image-Name.
	if res.Profile.Components[0].Path != "services/MyService" {
		t.Fatalf("path=%q — der Pfad darf nicht veraendert werden", res.Profile.Components[0].Path)
	}
}

func TestDerivedSuffixIsLowercasedToo(t *testing.T) {
	// `Dockerfile.Debug` → Suffix `Debug`, das genauso in den Image-Namen geht.
	repo := t.TempDir()
	dir := filepath.Join(repo, "svc")
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, "go.mod"), []byte("module x\ngo 1.22\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, "Dockerfile.Debug"),
		[]byte("# onboard:release=true\nFROM scratch\n"), 0o644); err != nil {
		t.Fatal(err)
	}

	res, err := (Service{}).Detect(context.Background(), Request{RepoPath: repo})
	if err != nil {
		t.Fatal(err)
	}
	// Nur der ABGELEITETE Teil wird geprueft: `$REPO` ist ein Platzhalter und
	// absichtlich gross — er wird spaeter durch das kleingeschriebene
	// `owner/repo` ersetzt. Eine naive Pruefung auf "alles klein" schlug genau
	// daran fehl.
	for _, d := range res.Profile.Components[0].Dockerfiles {
		derived := strings.TrimPrefix(d.ImageName, "$REPO")
		if strings.ToLower(derived) != derived {
			t.Fatalf("image_name=%q: der abgeleitete Teil %q enthaelt Grossbuchstaben",
				d.ImageName, derived)
		}
		if derived != "-svc-debug" {
			t.Fatalf("image_name=%q, erwartet $REPO-svc-debug", d.ImageName)
		}
	}
}

// Die Regel fuer Image-Namen existierte zweimal woertlich: in manifest.go und
// hier in readImageOverride, das `# onboard:image=` aus einem Dockerfile-Kopf
// liest. Beim Verschaerfen auf Kleinschreibung (#316) habe ich nur die
// Manifest-Fassung angefasst — der Zwilling nahm `Acme/UPPER` weiter an. Genau
// die Divergenz, die M-1 beschreibt, diesmal von mir selbst erzeugt.
//
// Jetzt teilen sich beide manifest.ImagePattern: eine Definition, beide
// Aufrufstellen.

func writeDockerfileWithHeader(t *testing.T, repo, header string) {
	t.Helper()
	dir := filepath.Join(repo, "svc")
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, "go.mod"), []byte("module x\ngo 1.22\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	body := header + "FROM scratch\n"
	if err := os.WriteFile(filepath.Join(dir, "Dockerfile"), []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}
}

func TestImageAnnotationFollowsTheManifestRule(t *testing.T) {
	for _, c := range []struct {
		name, header, want string
	}{
		{"gueltig", "# onboard:image=acme/svc\n", "acme/svc"},
		{"Grossbuchstaben", "# onboard:image=Acme/UPPER\n", "$REPO-svc"},
		{"Leerzeichen dahinter", "# onboard:image=acme/svc UND MEHR\n", "$REPO-svc"},
		{"keine Annotation", "", "$REPO-svc"},
	} {
		t.Run(c.name, func(t *testing.T) {
			repo := t.TempDir()
			writeDockerfileWithHeader(t, repo, c.header)
			res, err := (Service{}).Detect(context.Background(), Request{RepoPath: repo})
			if err != nil {
				t.Fatal(err)
			}
			got := res.Profile.Components[0].Dockerfiles[0].ImageName
			if got != c.want {
				t.Fatalf("image_name=%q, erwartet %q", got, c.want)
			}
		})
	}
}

// Unsichtbare Zeichen am Zeilenende entschieden ueber die Auslieferung.
//
// readReleaseOverride vergleicht die Zeile exakt (`case "# onboard:release=true"`),
// die Bash-Fassung matchte mit `grep -oE '^…'` nur den Anfang. Damit entschieden
// die beiden Engines gegensaetzlich, und zwar in BEIDE Richtungen:
//
//	# onboard:release=true<CR>            Go: verworfen   Bash: true
//	# onboard:release=false-aber-doch-ja  Go: verworfen   Bash: false
//
// Der erste Fall ist der wahrscheinlichere: ein auf Windows geschriebenes
// Dockerfile traegt CRLF. Beide Engines schneiden das Zeilenende jetzt ab und
// verankern beidseitig.

func TestAnnotationIgnoresInvisibleLineEnds(t *testing.T) {
	for _, c := range []struct {
		name, file, header string
		want               bool
	}{
		{"sauber", "Dockerfile.dev", "# onboard:release=true\n", true},
		{"Leerzeichen dahinter", "Dockerfile.dev", "# onboard:release=true \n", true},
		{"Tab dahinter", "Dockerfile.dev", "# onboard:release=true\t\n", true},
		{"CRLF aus Windows", "Dockerfile.dev", "# onboard:release=true\r\n", true},
		// Kein Endanker-Ersatz: was hinter dem Wert steht, ist kein Leerraum
		// und macht die Annotation ungueltig - der Default gilt weiter.
		{"Text dahinter zaehlt nicht", "Dockerfile", "# onboard:release=false-aber-doch-ja\n", true},
		{"angehaengte Zeichen", "Dockerfile", "# onboard:release=falsex\n", true},
		{"echtes false", "Dockerfile", "# onboard:release=false\n", false},
	} {
		t.Run(c.name, func(t *testing.T) {
			repo := t.TempDir()
			dir := filepath.Join(repo, "svc")
			if err := os.MkdirAll(dir, 0o755); err != nil {
				t.Fatal(err)
			}
			if err := os.WriteFile(filepath.Join(dir, "go.mod"), []byte("module x\ngo 1.22\n"), 0o644); err != nil {
				t.Fatal(err)
			}
			if err := os.WriteFile(filepath.Join(dir, c.file), []byte(c.header+"FROM scratch\n"), 0o644); err != nil {
				t.Fatal(err)
			}
			res, err := (Service{}).Detect(context.Background(), Request{RepoPath: repo})
			if err != nil {
				t.Fatal(err)
			}
			if got := res.Profile.Components[0].Dockerfiles[0].ReleaseEligible; got != c.want {
				t.Fatalf("release_eligible=%v, erwartet %v", got, c.want)
			}
		})
	}
}

func TestImageAnnotationSurvivesCRLF(t *testing.T) {
	repo := t.TempDir()
	writeDockerfileWithHeader(t, repo, "# onboard:image=acme/svc\r\n")
	res, err := (Service{}).Detect(context.Background(), Request{RepoPath: repo})
	if err != nil {
		t.Fatal(err)
	}
	// Ein auf Windows geschriebenes Dockerfile ist normal. Die Annotation dort
	// still zu ignorieren waere in beiden Engines falsch, nicht bloss uneinheitlich.
	if got := res.Profile.Components[0].Dockerfiles[0].ImageName; got != "acme/svc" {
		t.Fatalf("image_name=%q, erwartet %q", got, "acme/svc")
	}
}

// Die Mehrdeutigkeits-Absage war fuer den Adopter unentrinnbar.
//
// `Detect` baut das Profil vollstaendig und leitet erst danach das Legacy-Feld
// `language=` aus den WURZELSIGNALEN ab. Ein Manifest, das die Sprache
// ausdruecklich deklariert, sah diese Ableitung nie:
//
//	go.mod + pyproject.toml, dazu .github/onboard.yml mit
//	components: [{path: ., language: python}]
//	-> "ambiguous language signals: go python; rerun with explicit language input"
//
// Der Adopter hatte genau das getan, wozu die Meldung raet — im dokumentierten
// Feld — und wurde trotzdem abgewiesen, samt fertig gebautem Profil.

func writeAmbiguousRepo(t *testing.T, manifestBody string) string {
	t.Helper()
	repo := t.TempDir()
	if err := os.WriteFile(filepath.Join(repo, "go.mod"), []byte("module x\ngo 1.22\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(repo, "pyproject.toml"), []byte("[project]\nname=\"x\"\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if manifestBody != "" {
		if err := os.MkdirAll(filepath.Join(repo, ".github"), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(filepath.Join(repo, ".github", "onboard.yml"), []byte(manifestBody), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	return repo
}

func TestManifestLanguageResolvesAmbiguity(t *testing.T) {
	repo := writeAmbiguousRepo(t, "schema: 1\ncomponents:\n  - path: .\n    language: python\n")
	res, err := (Service{}).Detect(context.Background(), Request{RepoPath: repo})
	if err != nil {
		t.Fatalf("Manifest deklariert die Sprache, trotzdem abgewiesen: %v", err)
	}
	if res.Legacy.Language != "python" {
		t.Fatalf("language=%q, erwartet %q", res.Legacy.Language, "python")
	}
	if res.Legacy.ReleaseType != "python" {
		t.Fatalf("release_type=%q, erwartet %q", res.Legacy.ReleaseType, "python")
	}
}

func TestAmbiguityWithoutDeclarationStillRefuses(t *testing.T) {
	// Keine Lockerung: ohne Deklaration bleibt die Absage. Sie ist jetzt bloss
	// aufloesbar statt endgueltig.
	repo := writeAmbiguousRepo(t, "")
	if _, err := (Service{}).Detect(context.Background(), Request{RepoPath: repo}); err == nil {
		t.Fatal("erwartet: Absage bei mehrdeutigen Signalen ohne Deklaration")
	}
}

// `--language-override` erreichte das Profil nicht (Audit B-4).
//
// Der Eingang ist beschrieben als "auto = detect, otherwise force
// release-type". Gemessen an einem go-Repo mit Override `python`:
//
//	Legacy   language=python  release_type=python
//	Profil   release_please_type=go
//
// Gerendert wird aus dem PROFIL - release-please-config.json trug weiter
// `"release-type": "go"`. Fuer alles, was der Adopter hinterher sieht, war der
// Schalter ein stiller Leerlauf.

func TestLanguageOverrideReachesTheProfile(t *testing.T) {
	repo := t.TempDir()
	if err := os.WriteFile(filepath.Join(repo, "go.mod"), []byte("module x\ngo 1.22\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	for _, c := range []struct{ override, wantType, wantPrimary string }{
		{"", "go", "go"},
		{"auto", "go", "go"},
		{"python", "python", "go"}, // primary_language bleibt, was erkannt wurde
		{"flutter", "dart", "go"},  // dieselbe Abbildung wie im Legacy-Pfad
	} {
		t.Run("override="+c.override, func(t *testing.T) {
			res, err := (Service{}).Detect(context.Background(), Request{RepoPath: repo, LanguageOverride: c.override})
			if err != nil {
				t.Fatal(err)
			}
			got := res.Profile.Components[0]
			if got.ReleasePleaseType != c.wantType {
				t.Fatalf("release_please_type=%q, erwartet %q", got.ReleasePleaseType, c.wantType)
			}
			// Bewusst NICHT ueberschrieben: wuerde der Schalter auch die
			// Sprachwahl erzwingen, rendere ein erzwungenes `python` auf einem
			// reinen Go-Repo Python-Jobs gegen ein Repo ohne pyproject.toml.
			if got.PrimaryLanguage != c.wantPrimary {
				t.Fatalf("primary_language=%q, erwartet %q", got.PrimaryLanguage, c.wantPrimary)
			}
		})
	}
}

func TestLanguageOverrideWithoutRootComponentWarns(t *testing.T) {
	// Im Monorepo trifft ein repo-weiter Wert keine Wurzelkomponente. Statt
	// stumm wirkungslos zu bleiben - also genau der Fehler, den B-4 beschreibt -
	// sagt eine Warnung, dass der Schalter nicht gegriffen hat.
	repo := t.TempDir()
	for _, sub := range []string{"services/api", "services/worker"} {
		dir := filepath.Join(repo, sub)
		if err := os.MkdirAll(dir, 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(filepath.Join(dir, "go.mod"), []byte("module x\ngo 1.22\n"), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	res, err := (Service{}).Detect(context.Background(), Request{RepoPath: repo, LanguageOverride: "python"})
	if err != nil {
		t.Fatal(err)
	}
	var found bool
	for _, w := range res.Profile.Warnings {
		if w.Code == "language_override_not_applied" {
			found = true
		}
	}
	if !found {
		t.Fatalf("Warnung language_override_not_applied fehlt: %+v", res.Profile.Warnings)
	}
	for _, c := range res.Profile.Components {
		if c.ReleasePleaseType != "go" {
			t.Fatalf("%s: release_please_type=%q — Unterkomponenten duerfen nicht ueberschrieben werden", c.Path, c.ReleasePleaseType)
		}
	}
}

// Audit A-3 und A-4: `workflows.keep` und `workflows.e2e.script` wurden nur
// LEXIKALISCH geprueft — Zeichensatz und Form, nicht Existenz. Beide Werte
// gingen kommentarlos durch, mit `warnings: []`.
//
// Was daran haengt, ist nicht dasselbe:
//
//   - `keep` nennt Workflows, die die Legacy-Erkennung AUSNEHMEN soll. Bei
//     einem Tippfehler wird die gemeinte Datei nicht ausgenommen, und PR B
//     schlaegt ihre Loeschung vor: der Adopter deklariert Schutz und bekommt
//     das Gegenteil.
//   - `e2e.script` landet im gerenderten e2e.yml; fehlt die Datei, scheitert
//     der Job planmaessig zur Laufzeit.
//
// Warnung statt Fehler: die Loeschung geschieht in einem PR, den der Adopter
// sieht, und die Warnung steht in dessen Text. Ein harter Fehler wuerde ein
// veraltetes `keep` zum Totalblocker fuer jedes kuenftige Onboarding machen.

// Der Helfer writeManifestRepo aus service_test.go legt Repo, Manifest und
// go.mod an; hier kommen nur die deklarierten Dateien dazu.
func writeFiles(t *testing.T, repo string, files map[string]string) {
	t.Helper()
	for rel, body := range files {
		full := filepath.Join(repo, filepath.FromSlash(rel))
		if err := os.MkdirAll(filepath.Dir(full), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(full, []byte(body), 0o644); err != nil {
			t.Fatal(err)
		}
	}
}

const keepAndE2EManifest = `schema: 1
components:
  - path: .
workflows:
  keep:
    - eigenes.yml
  e2e:
    script: tests/e2e/run.sh
`

func TestDeclaredButMissingFilesAreReported(t *testing.T) {
	repo := writeManifestRepo(t, keepAndE2EManifest)
	res, err := (Service{}).Detect(context.Background(), Request{RepoPath: repo})
	if err != nil {
		t.Fatal(err)
	}
	var paths []string
	for _, w := range res.Profile.Warnings {
		if w.Code == "declared_file_missing" {
			paths = append(paths, w.Path)
		}
	}
	want := []string{".github/workflows/eigenes.yml", "tests/e2e/run.sh"}
	if len(paths) != len(want) {
		t.Fatalf("erwartet %v, bekommen %v (alle: %+v)", want, paths, res.Profile.Warnings)
	}
	for i := range want {
		if paths[i] != want[i] {
			t.Fatalf("Warnung %d nennt %q, erwartet %q", i, paths[i], want[i])
		}
	}
}

func TestDeclaredFilesThatExistAreSilent(t *testing.T) {
	repo := writeManifestRepo(t, keepAndE2EManifest)
	writeFiles(t, repo, map[string]string{
		".github/workflows/eigenes.yml": "name: eigenes\n",
		"tests/e2e/run.sh":              "#!/bin/sh\n",
	})
	res, err := (Service{}).Detect(context.Background(), Request{RepoPath: repo})
	if err != nil {
		t.Fatal(err)
	}
	for _, w := range res.Profile.Warnings {
		if w.Code == "declared_file_missing" {
			t.Fatalf("vorhandene Datei darf nicht gemeldet werden: %+v", w)
		}
	}
}

// Audit H-9: `packages:` in pnpm-workspace.yaml wurde nur in Block-Form
// gelesen. Beides ist gueltiges YAML und bedeutet dasselbe:
//
//	packages:                erkannt
//	  - apps/*
//
//	packages: ["apps/*"]     NICHT erkannt
//
// Gemessen an einem Repo mit apps/web und apps/api: die Block-Form ergab zwei
// Komponenten, die Flow-Form eine einzige Wurzelkomponente. Das Monorepo fiel
// lautlos in sich zusammen — keine Jobs je Paket, keine Release-Konfiguration
// je Paket. BEIDE Engines hatten denselben blinden Fleck, das
// Fixture-Paritaets-Gate konnte es also nicht sehen.

func TestPNPMWorkspaceReadsBothYAMLStyles(t *testing.T) {
	for _, c := range []struct {
		name, workspace string
	}{
		{"Block", "packages:\n  - apps/*\n"},
		{"Flow einzeilig", "packages: [\"apps/*\"]\n"},
		{"Flow mit zwei Eintraegen", "packages: [\"apps/web\", \"apps/api\"]\n"},
		{"Flow mit einfachen Anfuehrungszeichen", "packages: ['apps/*']\n"},
		{"Flow ueber mehrere Zeilen", "packages: [\n  \"apps/web\",\n  \"apps/api\"\n]\n"},
	} {
		t.Run(c.name, func(t *testing.T) {
			repo := t.TempDir()
			if err := os.WriteFile(filepath.Join(repo, "package.json"), []byte(`{"name":"root"}`), 0o644); err != nil {
				t.Fatal(err)
			}
			for _, sub := range []string{"apps/web", "apps/api"} {
				dir := filepath.Join(repo, filepath.FromSlash(sub))
				if err := os.MkdirAll(dir, 0o755); err != nil {
					t.Fatal(err)
				}
				if err := os.WriteFile(filepath.Join(dir, "package.json"), []byte(`{"name":"x"}`), 0o644); err != nil {
					t.Fatal(err)
				}
			}
			if err := os.WriteFile(filepath.Join(repo, "pnpm-workspace.yaml"), []byte(c.workspace), 0o644); err != nil {
				t.Fatal(err)
			}
			res, err := (Service{}).Detect(context.Background(), Request{RepoPath: repo})
			if err != nil {
				t.Fatal(err)
			}
			var got []string
			for _, comp := range res.Profile.Components {
				got = append(got, comp.Path)
			}
			sort.Strings(got)
			if len(got) != 2 || got[0] != "apps/api" || got[1] != "apps/web" {
				t.Fatalf("Komponenten=%v, erwartet [apps/api apps/web]", got)
			}
		})
	}
}
