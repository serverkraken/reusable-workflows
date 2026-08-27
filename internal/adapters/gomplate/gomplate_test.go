package gomplate

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestExecuteInvokesGomplate(t *testing.T) {
	bin := fakeGomplate(t, 0)
	out := filepath.Join(t.TempDir(), "out.yml")
	err := (Adapter{Binary: bin}).Execute(context.Background(), "/template.yml.tmpl", out, "/ctx.json")
	if err != nil {
		t.Fatal(err)
	}
	got, err := os.ReadFile(out)
	if err != nil {
		t.Fatal(err)
	}
	// gomplate schreibt NEBEN das Ziel und wird danach umbenannt (Audit C-9).
	// Der Test hielt vorher `-o <ziel>` fest — also genau das Verhalten, das
	// bei einem Abbruch mittendrin eine halbe Datei im Adopter-Checkout
	// hinterlaesst. Die Endung gehoert damit zum Vertrag.
	want := "-c .=/ctx.json -f /template.yml.tmpl -o " + out + ".sk-render\n"
	if string(got) != want {
		t.Fatalf("output=%q want %q", got, want)
	}
	if _, err := os.Stat(out + ".sk-render"); err == nil {
		t.Fatal("die temporaere Renderdatei blieb nach dem Rename liegen")
	}
}

// Audit C-9. `gomplate -o <ziel>` streamt direkt dorthin. Bricht das Template
// mittendrin ab, bleibt eine HALBE Datei liegen — gemessen an einer Vorlage,
// die 50 Zeilen ausgibt und in Zeile 51 auf einen fehlenden Schluessel laeuft:
// rc != 0, und out.yml lag trotzdem mit 741 Byte da.
//
// outputPath liegt im Adopter-Checkout. Der Lauf wird zwar rot, die
// verstuemmelte Workflow-Datei bleibt aber im Arbeitsverzeichnis stehen, wo
// ein Wiederholungslauf oder ein Mensch sie einchecken kann.
func TestExecuteLeavesNoPartialFileWhenGomplateFails(t *testing.T) {
	dir := t.TempDir()
	out := filepath.Join(dir, "out.yml")

	// Ein Fake, der erst schreibt und dann scheitert — genau das Verhalten,
	// das ein streamendes gomplate bei einem spaeten Template-Fehler zeigt.
	bin := filepath.Join(dir, "half-writing-gomplate")
	if err := os.WriteFile(bin, []byte(`#!/usr/bin/env bash
while [[ $# -gt 0 ]]; do
  if [[ "$1" == "-o" ]]; then printf 'halb geschrieben\n' > "$2"; shift 2; continue; fi
  shift
done
echo boom >&2
exit 1
`), 0o755); err != nil {
		t.Fatal(err)
	}

	err := (Adapter{Binary: bin}).Execute(context.Background(), "/t.tmpl", out, "/ctx.json")
	if err == nil {
		t.Fatal("erwartet: Fehler")
	}
	if _, statErr := os.Stat(out); statErr == nil {
		b, _ := os.ReadFile(out)
		t.Fatalf("Zieldatei wurde trotz Fehlschlag angelegt: %q", b)
	}
	if _, statErr := os.Stat(out + ".sk-render"); statErr == nil {
		t.Fatal("die temporaere Renderdatei blieb liegen")
	}
}

func TestExecuteIncludesStderrOnFailure(t *testing.T) {
	bin := fakeGomplate(t, 7)
	err := (Adapter{Binary: bin}).Execute(context.Background(), "/template", "/out", "/ctx")
	if err == nil || !strings.Contains(err.Error(), "gomplate failed") {
		t.Fatalf("err=%v", err)
	}
}

func TestExecuteUsesDefaultBinaryFromPath(t *testing.T) {
	dir := t.TempDir()
	bin := fakeGomplateAt(t, filepath.Join(dir, "gomplate"), 0)
	t.Setenv("PATH", filepath.Dir(bin)+string(os.PathListSeparator)+os.Getenv("PATH"))
	out := filepath.Join(t.TempDir(), "out.yml")
	if err := (Adapter{}).Execute(context.Background(), "/template", out, "/ctx"); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(out); err != nil {
		t.Fatal(err)
	}
}

func fakeGomplate(t *testing.T, exitCode int) string {
	t.Helper()
	return fakeGomplateAt(t, filepath.Join(t.TempDir(), "gomplate"), exitCode)
}

func fakeGomplateAt(t *testing.T, path string, exitCode int) string {
	t.Helper()
	failure := ""
	if exitCode != 0 {
		failure = fmt.Sprintf("echo \"gomplate failed\" >&2\nexit %d\n", exitCode)
	}
	script := `#!/usr/bin/env bash
set -euo pipefail
` + failure + `
out=""
for ((i=1; i<=$#; i++)); do
  if [[ "${!i}" == "-o" ]]; then
    j=$((i+1))
    out="${!j}"
  fi
done
mkdir -p "$(dirname "$out")"
printf '%s\n' "$*" > "$out"
`
	if err := os.WriteFile(path, []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}
	return path
}

// Audit C-6: gomplate schreibt die Zieldatei selbst und beendet mit 0, auch
// wenn das Template nichts ergeben hat — etwa weil jeder Zweig darin falsch
// war. Der Renderer nahm das an, der Lock hashte die leere Datei, und der Lauf
// blieb gruen. Im Adopter-Repo landete damit ein leerer Workflow, den GitHub
// kommentarlos ignoriert: kein Lint, kein Test, kein Scan, und nichts sagt es.
//
// Keine gerenderte Datei darf leer sein; die kleinste eingecheckte
// Golden-Ausgabe hat 19 Byte.

// emptyOutputGomplate legt die Zieldatei an und schreibt content hinein.
//
// Der Inhalt geht ueber eine Datei, nicht ueber ein Literal im Skript: eine
// erste Fassung nutzte `printf '%s' "\n"`, und bash schreibt dabei die zwei
// ZEICHEN Backslash und n statt eines Zeilenumbruchs. Der Test war damit gruen
// aus dem falschen Grund — er pruefte nie den Whitespace-Fall.
func emptyOutputGomplate(t *testing.T, content string) string {
	t.Helper()
	dir := t.TempDir()
	payload := filepath.Join(dir, "payload")
	if err := os.WriteFile(payload, []byte(content), 0o644); err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(dir, "gomplate")
	script := `#!/usr/bin/env bash
set -euo pipefail
out=""
for ((i=1; i<=$#; i++)); do
  if [[ "${!i}" == "-o" ]]; then
    j=$((i+1))
    out="${!j}"
  fi
done
mkdir -p "$(dirname "$out")"
cat ` + fmt.Sprintf("%q", payload) + ` > "$out"
`
	if err := os.WriteFile(path, []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}
	return path
}

func TestExecuteRejectsEmptyRender(t *testing.T) {
	for _, c := range []struct {
		name    string
		content string
	}{
		{"komplett leer", ""},
		{"nur ein Zeilenumbruch", "\n"},
		// Der Bash-Renderer normalisiert leeren Inhalt zu genau einem \n —
		// derselbe Fehler in anderer Verkleidung.
		{"nur Whitespace", "  \n\t\n"},
	} {
		t.Run(c.name, func(t *testing.T) {
			out := filepath.Join(t.TempDir(), "ci.yml")
			err := (Adapter{Binary: emptyOutputGomplate(t, c.content)}).
				Execute(context.Background(), "/ci.yml.tmpl", out, "/ctx.json")
			if err == nil {
				t.Fatal("erwartet: Abbruch, bekommen: Erfolg — ein leerer Workflow darf nicht in den Lock")
			}
			if !strings.Contains(err.Error(), "rendered nothing") {
				t.Fatalf("Grund fehlt im Fehler: %v", err)
			}
		})
	}
}

func TestExecuteAcceptsMinimalRender(t *testing.T) {
	// Gegenprobe: die Pruefung darf nicht mehr abweisen als leere Ausgaben.
	// 19 Byte ist die kleinste echte Golden-Datei.
	out := filepath.Join(t.TempDir(), "manifest.json")
	err := (Adapter{Binary: emptyOutputGomplate(t, "{\n  \".\": \"0.0.0\"\n}\n")}).
		Execute(context.Background(), "/manifest.tmpl", out, "/ctx.json")
	if err != nil {
		t.Fatalf("eine kleine, aber gueltige Ausgabe muss durchgehen: %v", err)
	}
}
