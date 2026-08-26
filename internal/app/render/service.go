package render

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"time"

	"github.com/serverkraken/reusable-workflows/internal/domain"
	"github.com/serverkraken/reusable-workflows/internal/ports"
)

const (
	templateRoot = "docs/adopter-templates"
	lockPath     = ".github/onboard.lock.json"
)

type Service struct {
	Templates ports.TemplateExecutor
	Now       func() time.Time
	TempDir   func() (string, error)
}

type Request struct {
	CatalogPath     string
	TargetPath      string
	ProfileJSONPath string
	PinVersion      string
	RenderedAgainst string
}

type renderFile struct {
	Template string
	Output   string
}

func (s Service) Render(ctx context.Context, req Request) error {
	if err := validateRequest(req); err != nil {
		return err
	}
	if s.Templates == nil {
		return errors.New("template executor not configured")
	}
	rawProfile, profile, err := readProfile(req.ProfileJSONPath)
	if err != nil {
		return err
	}
	if err := checkSlugCollisions(profile); err != nil {
		return err
	}

	tempDir := os.MkdirTemp
	if s.TempDir != nil {
		tempDir = func(_, _ string) (string, error) { return s.TempDir() }
	}
	scratch, err := tempDir("", "sk-workflows-render-*")
	if err != nil {
		return err
	}
	defer func() { _ = os.RemoveAll(scratch) }()

	contextPath := filepath.Join(scratch, "ctx.json")
	// Leeres target_repo VOR dem Templating auffuellen. Die Templates
	// interpolieren den Wert direkt:
	//
	//	oci_registry: ghcr.io/{{ .profile.target_repo }}/charts
	//
	// Ist er leer, entsteht `ghcr.io//charts` - syntaktisch einwandfreies YAML
	// mit einer Registry, die es nicht gibt, und actionlint sieht nichts, weil
	// es ein gueltiger String ist. Gemessen an der Fixture service-with-helm.
	//
	// onboard-render.sh tut das laengst, und der Kommentar dort behauptet, der
	// Go-Pfad tue es auch - belegt aber mit `preview`, einem anderen
	// Unterbefehl. `render` selbst hatte den Rueckfall nie. repoName() darunter
	// implementiert genau diese Herleitung und wurde bisher nur fuer den
	// $REPO-Ersatz benutzt: die Faehigkeit lag eine Funktion weiter und war
	// hier nicht angewandt.
	rawProfile, err = fillTargetRepo(rawProfile, repoName(req.TargetPath, profile.TargetRepo))
	if err != nil {
		return err
	}
	if err := writeContext(contextPath, req.PinVersion, rawProfile); err != nil {
		return err
	}

	files := plannedFiles(profile)
	// Das Zielverzeichnis selbst anlegen, BEVOR es aufgeloest wird: drift
	// rendert in ein frisches Temp-Verzeichnis, das hier noch nicht existiert.
	// Ohne diese Zeile scheitert die Aufloesung, und der go-cli-Drift-Pfad
	// meldet `render-failed` - genau so gemessen, nachdem der Riegel unten
	// zuerst ohne sie eingebaut war.
	if err := os.MkdirAll(req.TargetPath, 0o755); err != nil {
		return err
	}
	// Derselbe Riegel wie in renderOne, nur frueher: dieses MkdirAll laeuft vor
	// jedem Rendern und wuerde durch einen `.github`-Symlink hindurch bereits
	// ein Verzeichnis ausserhalb des Ziels anlegen (Audit H-3).
	if err := ensureInsideTarget(req.TargetPath, filepath.Join(req.TargetPath, ".github", "workflows", "probe")); err != nil {
		return err
	}
	if err := os.MkdirAll(filepath.Join(req.TargetPath, ".github", "workflows"), 0o755); err != nil {
		return err
	}
	for _, file := range files {
		if err := s.renderOne(ctx, req, file, contextPath); err != nil {
			return err
		}
	}
	if err := substituteRepo(req.TargetPath, profile); err != nil {
		return err
	}
	renderedAgainst := req.RenderedAgainst
	if renderedAgainst == "" {
		renderedAgainst = req.PinVersion
	}
	return writeLock(req.TargetPath, req.PinVersion, renderedAgainst, renderedAt(s.Now), profile.ManifestSHA256, lockPaths(profile))
}

func validateRequest(req Request) error {
	if req.CatalogPath == "" || req.TargetPath == "" || req.ProfileJSONPath == "" || req.PinVersion == "" {
		return errors.New("usage: sk-workflows render <catalog-path> <target-path> <profile-json-path> <pin-version>")
	}
	return nil
}

func readProfile(path string) ([]byte, domain.Profile, error) {
	content, err := os.ReadFile(path)
	if err != nil {
		return nil, domain.Profile{}, fmt.Errorf("profile not found: %s", path)
	}
	var profile domain.Profile
	if err := json.Unmarshal(content, &profile); err != nil {
		return nil, domain.Profile{}, fmt.Errorf("invalid profile JSON: %w", err)
	}
	if len(profile.Components) == 0 {
		return nil, domain.Profile{}, errors.New("invalid profile JSON: components must not be empty")
	}
	return content, profile, nil
}

// fillTargetRepo setzt target_repo im rohen Profil-JSON, wenn es fehlt oder
// leer ist.
//
// Ueber eine Map statt ueber domain.Profile: der Kontext soll das Profil
// unveraendert weiterreichen. Ein Umweg ueber die Struktur wuerde jedes Feld
// verlieren, das dort (noch) nicht modelliert ist - und die Templates lesen
// aus dem JSON, nicht aus der Struktur.
func fillTargetRepo(rawProfile []byte, fallback string) ([]byte, error) {
	var m map[string]json.RawMessage
	if err := json.Unmarshal(rawProfile, &m); err != nil {
		return nil, fmt.Errorf("invalid profile JSON: %w", err)
	}
	var cur string
	if v, ok := m["target_repo"]; ok {
		_ = json.Unmarshal(v, &cur)
	}
	if cur != "" || fallback == "" {
		return rawProfile, nil
	}
	enc, err := json.Marshal(fallback)
	if err != nil {
		return nil, err
	}
	m["target_repo"] = enc
	return json.Marshal(m)
}

func writeContext(path, pin string, rawProfile []byte) error {
	payload := struct {
		Pin     string          `json:"pin"`
		Profile json.RawMessage `json:"profile"`
	}{
		Pin:     pin,
		Profile: rawProfile,
	}
	content, err := json.MarshalIndent(payload, "", "  ")
	if err != nil {
		return err
	}
	content = append(content, '\n')
	return os.WriteFile(path, content, 0o600)
}

func plannedFiles(profile domain.Profile) []renderFile {
	files := []renderFile{
		{Template: "skeletons/ci.yml.tmpl", Output: ".github/workflows/ci.yml"},
	}
	if profile.GitOps != nil {
		return files
	}
	files = append(files,
		renderFile{Template: "skeletons/release.yml.tmpl", Output: ".github/workflows/release.yml"},
		renderFile{Template: "skeletons/prerelease.yml.tmpl", Output: ".github/workflows/prerelease.yml"},
		renderFile{Template: "skeletons/cleanup.yml.tmpl", Output: ".github/workflows/cleanup.yml"},
	)
	if hasTopic(profile.Topics, "sk-prerelease-on-push") {
		files = append(files, renderFile{Template: "skeletons/prerelease-on-push.yml.tmpl", Output: ".github/workflows/prerelease-on-push.yml"})
	}
	// After the sk-prerelease-on-push block — mirrors the shell engine's
	// render/lock ordering so both engines emit identical lock files.
	if hasFlutterAndroid(profile) {
		files = append(files, renderFile{Template: "skeletons/ci-android.yml.tmpl", Output: ".github/workflows/ci-android.yml"})
	}
	if profile.Workflows != nil && profile.Workflows.E2E != nil {
		files = append(files, renderFile{Template: "skeletons/e2e.yml.tmpl", Output: ".github/workflows/e2e.yml"})
	}
	configTemplate := "configs/release-please-config.json.tmpl"
	if profile.Monorepo {
		configTemplate = "configs/release-please-config.monorepo.json.tmpl"
	}
	files = append(files,
		renderFile{Template: configTemplate, Output: "release-please-config.json"},
		renderFile{Template: "configs/release-please-manifest.json.tmpl", Output: ".release-please-manifest.json"},
	)
	return files
}

func lockPaths(profile domain.Profile) []string {
	if profile.GitOps != nil {
		return []string{".github/workflows/ci.yml"}
	}
	files := []string{
		".github/workflows/ci.yml",
		".github/workflows/release.yml",
		".github/workflows/prerelease.yml",
		".github/workflows/cleanup.yml",
		"release-please-config.json",
		".release-please-manifest.json",
	}
	if hasTopic(profile.Topics, "sk-prerelease-on-push") {
		files = append(files, ".github/workflows/prerelease-on-push.yml")
	}
	// After the sk-prerelease-on-push block — mirrors the shell engine's
	// render/lock ordering so both engines emit identical lock files.
	if hasFlutterAndroid(profile) {
		files = append(files, ".github/workflows/ci-android.yml")
	}
	if profile.Workflows != nil && profile.Workflows.E2E != nil {
		files = append(files, ".github/workflows/e2e.yml")
	}
	return files
}

// ensureInsideTarget stellt sicher, dass outputPath tatsaechlich UNTERHALB von
// targetPath landet, nachdem alle Symlinks aufgeloest sind (Audit H-3).
//
// Nachgestellt: ein Adopter-Repo, in dem `.github` ein Symlink nach aussen ist.
// Beide Engines schrieben daraufhin `onboard.lock.json` und alle vier
// Workflow-Dateien ausserhalb des Checkouts - mit rc=0. Auf einem self-hosted
// Runner ist das ein Schreibvorgang an einen beliebigen Ort, den der Job
// erreichen kann; der Lock landet dort ebenfalls, und der anschliessende
// Commit im Adopter-Repo findet nichts.
//
// Geprueft wird das ELTERNVERZEICHNIS aufgeloest, nicht der Dateipfad selbst:
// die Datei existiert beim ersten Rendern noch nicht. Zusaetzlich wird eine
// bereits vorhandene Zieldatei abgewiesen, wenn sie ein Symlink ist - sonst
// schriebe gomplate durch sie hindurch.
func ensureInsideTarget(targetPath, outputPath string) error {
	root, err := filepath.EvalSymlinks(targetPath)
	if err != nil {
		return fmt.Errorf("target path not resolvable: %w", err)
	}
	// Den tiefsten BEREITS EXISTIERENDEN Vorfahren aufloesen. Geprueft werden
	// muss VOR dem MkdirAll: ein MkdirAll durch einen Symlink hindurch legt das
	// Verzeichnis bereits draussen an, auch wenn danach keine Datei mehr
	// geschrieben wird. Der erste Anlauf dieses Fixes prueft zu spaet und hat
	// `aussen/workflows/` hinterlassen.
	probe := filepath.Dir(outputPath)
	for {
		if _, err := os.Lstat(probe); err == nil {
			break
		}
		parent := filepath.Dir(probe)
		if parent == probe {
			break
		}
		probe = parent
	}
	dir, err := filepath.EvalSymlinks(probe)
	if err != nil {
		return fmt.Errorf("output directory not resolvable: %w", err)
	}
	rel, err := filepath.Rel(root, dir)
	if err != nil || rel == ".." || strings.HasPrefix(rel, ".."+string(filepath.Separator)) {
		return fmt.Errorf("refusing to write outside the target: %s resolves under %s, which is not inside %s",
			outputPath, dir, root)
	}
	if info, err := os.Lstat(outputPath); err == nil && info.Mode()&os.ModeSymlink != 0 {
		return fmt.Errorf("refusing to write through the symlink %s", outputPath)
	}
	return nil
}

func (s Service) renderOne(ctx context.Context, req Request, file renderFile, contextPath string) error {
	templatePath := filepath.Join(req.CatalogPath, filepath.FromSlash(templateRoot), filepath.FromSlash(file.Template))
	if _, err := os.Stat(templatePath); errors.Is(err, os.ErrNotExist) {
		return fmt.Errorf("template missing: %s", templatePath)
	} else if err != nil {
		return err
	}
	outputPath := filepath.Join(req.TargetPath, filepath.FromSlash(file.Output))
	// Vor MkdirAll: siehe ensureInsideTarget.
	if err := ensureInsideTarget(req.TargetPath, outputPath); err != nil {
		return err
	}
	if err := os.MkdirAll(filepath.Dir(outputPath), 0o755); err != nil {
		return err
	}
	if err := s.Templates.Execute(ctx, templatePath, outputPath, contextPath); err != nil {
		return err
	}
	return normalizeTrailingNewline(outputPath)
}

func normalizeTrailingNewline(path string) error {
	content, err := os.ReadFile(path)
	if err != nil {
		return err
	}
	content = bytes.TrimRight(content, "\n")
	content = append(content, '\n')
	return os.WriteFile(path, content, 0o644)
}

func substituteRepo(targetPath string, profile domain.Profile) error {
	repo := repoName(targetPath, profile.TargetRepo)
	for _, rel := range []string{
		".github/workflows/release.yml",
		".github/workflows/prerelease.yml",
		".github/workflows/prerelease-on-push.yml",
	} {
		path := filepath.Join(targetPath, filepath.FromSlash(rel))
		content, err := os.ReadFile(path)
		if errors.Is(err, os.ErrNotExist) {
			continue
		}
		if err != nil {
			return err
		}
		if !bytes.Contains(content, []byte("$REPO")) {
			continue
		}
		replaced := strings.ReplaceAll(string(content), "$REPO", repo)
		if err := os.WriteFile(path, []byte(replaced), 0o644); err != nil {
			return err
		}
	}
	return nil
}

func repoName(targetPath, targetRepo string) string {
	if targetRepo != "" {
		return targetRepo
	}
	base := filepath.Base(targetPath)
	if base == "." || base == "" {
		if cwd, err := os.Getwd(); err == nil {
			return filepath.Base(cwd)
		}
	}
	return base
}

func writeLock(targetPath, pinVersion, renderedAgainst, renderedAt, manifestSHA string, files []string) error {
	hashes := make(map[string]string, len(files))
	for _, rel := range files {
		path := filepath.Join(targetPath, filepath.FromSlash(rel))
		if _, err := os.Stat(path); errors.Is(err, os.ErrNotExist) {
			return fmt.Errorf("expected rendered file missing: %s", rel)
		} else if err != nil {
			return err
		}
		hash, err := sha256File(path)
		if err != nil {
			return err
		}
		hashes[rel] = "sha256:" + hash
	}
	content := encodeLock(pinVersion, renderedAgainst, renderedAt, manifestSHA, files, hashes)
	lockFile := filepath.Join(targetPath, filepath.FromSlash(lockPath))
	// Auch der Lock geht durch den Riegel (Audit C-7). H-3 hat die gerenderten
	// Dateien abgesichert und den Lock uebersehen; die fruehe Pruefung in
	// Render() sondiert `.github/workflows/`, faengt also nur ein Symlink-
	// `.github`, nicht die Lock-DATEI selbst.
	//
	// Nachgestellt mit einem echten `.github/` und `onboard.lock.json` als
	// Symlink nach draussen: die Go-Engine schrieb den Lock durch ihn hindurch
	// und ueberschrieb die fremde Datei, mit rc=0 und ohne ein Wort. Die
	// Bash-Engine wies denselben Fall laengst ab ("refusing to write through
	// the symlink") - eine Abweichung, die die Fixture-Paritaet nicht sehen
	// kann, weil keine Fixture Symlinks traegt.
	if err := ensureInsideTarget(targetPath, lockFile); err != nil {
		return err
	}
	return os.WriteFile(lockFile, content, 0o644)
}

func encodeLock(pinVersion, renderedAgainst, renderedAt, manifestSHA string, files []string, hashes map[string]string) []byte {
	var out bytes.Buffer
	out.WriteString("{\n")
	fmt.Fprintf(&out, "  \"schema_version\": 1,\n")
	writeStringField(&out, "catalog_version", pinVersion, true)
	writeStringField(&out, "rendered_against", renderedAgainst, true)
	writeStringField(&out, "rendered_at", renderedAt, true)
	if manifestSHA != "" {
		out.WriteString("  \"inputs\": {\n")
		fmt.Fprintf(&out, "    \"manifest_sha256\": %s\n", mustJSON("sha256:"+manifestSHA))
		out.WriteString("  },\n")
	}
	out.WriteString("  \"files\": {")
	if len(files) == 0 {
		out.WriteString("}\n")
		out.WriteString("}\n")
		return out.Bytes()
	}
	for i, rel := range files {
		key, _ := json.Marshal(rel)
		value, _ := json.Marshal(hashes[rel])
		if i == 0 {
			out.WriteByte('\n')
		} else {
			out.WriteString(",\n")
		}
		fmt.Fprintf(&out, "    %s: %s", key, value)
	}
	out.WriteByte('\n')
	out.WriteString("  }\n")
	out.WriteString("}\n")
	return out.Bytes()
}

func mustJSON(s string) string {
	b, _ := json.Marshal(s)
	return string(b)
}

func writeStringField(out *bytes.Buffer, key, value string, comma bool) {
	encoded, _ := json.Marshal(value)
	fmt.Fprintf(out, "  %q: %s", key, encoded)
	if comma {
		out.WriteByte(',')
	}
	out.WriteByte('\n')
}

func renderedAt(now func() time.Time) string {
	if now == nil {
		now = time.Now
	}
	return now().UTC().Format(time.RFC3339)
}

func hasTopic(topics []string, topic string) bool {
	for _, candidate := range topics {
		if candidate == topic {
			return true
		}
	}
	return false
}

func hasFlutterAndroid(profile domain.Profile) bool {
	for _, c := range profile.Components {
		if c.ReleaseSignals.FlutterAndroid {
			return true
		}
	}
	return false
}

func sha256File(path string) (string, error) {
	content, err := os.ReadFile(path)
	if err != nil {
		return "", err
	}
	sum := sha256.Sum256(content)
	return hex.EncodeToString(sum[:]), nil
}

// jobIDSlug bildet einen Komponentenpfad auf das ab, was die Templates als
// Job-ID-Suffix verwenden: Slashes zu Bindestrichen, dann alles, was GitHub in
// einer Job-ID nicht erlaubt, ebenfalls zu Bindestrichen.
func jobIDSlug(path string) string {
	s := strings.ReplaceAll(path, "/", "-")
	return notJobIDChar.ReplaceAllString(s, "-")
}

var notJobIDChar = regexp.MustCompile(`[^A-Za-z0-9_-]`)

// checkSlugCollisions weist ein Profil zurueck, dessen Komponenten auf dieselbe
// Job-ID abgebildet wuerden.
//
// Die Bereinigung ist nicht injektiv: `svc/x.y` und `svc/x-y` ergeben beide
// `svc-x-y`. Gerendert wird daraus zweimal derselbe Job-Key, und GitHub bzw.
// actionlint melden "key ... is duplicated in jobs section" — der Adopter
// bekommt eine Datei, die gar nicht laeuft. Gemessen an einem Profil mit genau
// diesen beiden Pfaden.
//
// Hier abzubrechen ist die ehrlichere Antwort als ein angehaengter Hash: der
// wuerde die Job-IDs aller bestehenden Adopter stabil halten muessen und waere
// fuer den Menschen, der den Lauf liest, nicht mehr zuzuordnen.
func checkSlugCollisions(profile domain.Profile) error {
	seen := map[string]string{}
	for _, c := range profile.Components {
		if c.Path == "." {
			continue
		}
		slug := jobIDSlug(c.Path)
		if other, dup := seen[slug]; dup {
			return fmt.Errorf(
				"doppelte Job-ID %q: die Komponenten %q und %q werden beide darauf abgebildet — GitHub wuerde den Workflow wegen doppelter Job-Keys verwerfen; eine der beiden umbenennen",
				slug, other, c.Path)
		}
		seen[slug] = c.Path
	}
	return nil
}
