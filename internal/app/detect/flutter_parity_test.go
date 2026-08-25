package detect

import (
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"testing"
)

// Audit M-1: die Flutter-Erkennung war zwischen Bash und Go auseinandergelaufen.
// Bash nahm `sdk:[[:space:]]*flutter`, Go verglich woertlich mit "sdk: flutter".
// Gemessen an vier pubspec.yaml-Varianten:
//
//	sdk: flutter    gueltiges YAML, Flutter   Bash flutter   Go flutter
//	sdk:  flutter   gueltiges YAML, Flutter   Bash flutter   Go simple  <- verloren
//	sdk:\tflutter   gueltiges YAML, Flutter   Bash flutter   Go simple  <- verloren
//	sdk:flutter     KEIN Mapping, kein Dep    Bash flutter   Go simple  <- Bash irrte
//
// Weil `use_go_cli` standardmaessig an ist, hat der Go-Pfad solche Repos als
// `simple` gerendert — ohne jeden Flutter-Job. Die Fixture-Erkennung war davon
// nicht betroffen, weil jede eingecheckte Fixture genau ein Leerzeichen nutzt;
// deshalb ist es keinem Test aufgefallen.

func TestFlutterSDKPatternMatchesValidYAMLSpacings(t *testing.T) {
	cases := []struct {
		name  string
		line  string
		match bool
		why   string
	}{
		{"ein Leerzeichen", "sdk: flutter", true, "kanonische Schreibweise"},
		{"zwei Leerzeichen", "sdk:  flutter", true, "gueltiges YAML, gleiche Bedeutung"},
		{"Tab", "sdk:\tflutter", true, "gueltiges YAML, gleiche Bedeutung"},
		{"ohne Leerzeichen", "sdk:flutter", false, "in YAML kein Mapping, also keine Abhaengigkeit"},
		{"Zeilenumbruch", "sdk:\nflutter", false, "grep arbeitet zeilenweise, Go muss es genauso halten"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			if got := flutterSDKDep.MatchString(c.line); got != c.match {
				t.Fatalf("%q: erwartet %v (%s), bekommen %v", c.line, c.match, c.why, got)
			}
		})
	}
}

func TestIsFlutterAcceptsValidSpacings(t *testing.T) {
	// Nicht nur das Muster, sondern der Aufrufpfad: isFlutter liest die Datei.
	cases := map[string]bool{
		"sdk: flutter":  true,
		"sdk:  flutter": true,
		"sdk:\tflutter": true,
		"sdk:flutter":   false,
	}
	for line, want := range cases {
		dir := t.TempDir()
		body := "name: demo\ndependencies:\n  flutter:\n    " + line + "\n"
		if err := os.WriteFile(filepath.Join(dir, "pubspec.yaml"), []byte(body), 0o644); err != nil {
			t.Fatal(err)
		}
		if got := isFlutter(dir); got != want {
			t.Errorf("pubspec mit %q: isFlutter=%v, erwartet %v", line, got, want)
		}
	}
}

// Der eigentliche Drift-Riegel: die Go-Konstante und das Muster, das die
// Bash-Bibliothek an `grep -E` uebergibt, muessen dieselbe Zeichenkette sein.
// Ein Vergleich der TrefferMENGEN waere schoener, ist aber ohne grep-Aufruf
// nicht zu haben; Zeichengleichheit ist dafuer nicht zu umgehen. Deshalb nutzt
// die Go-Seite `[[:blank:]]` statt `[ \t]` — nur so sind es dieselben Zeichen.
func TestFlutterPatternIdenticalToBashSource(t *testing.T) {
	root := repoRoot(t)
	src, err := os.ReadFile(filepath.Join(root, "scripts", "lib", "onboard-detect-lib.sh"))
	if err != nil {
		t.Fatalf("Bash-Bibliothek nicht lesbar: %v", err)
	}

	// Das erste einfach gequotete Muster in der Zeile, die pubspec.yaml prueft.
	var found string
	for _, line := range strings.Split(string(src), "\n") {
		if !strings.Contains(line, "pubspec.yaml") || !strings.Contains(line, "-qE") {
			continue
		}
		m := regexp.MustCompile(`'([^']+)'`).FindStringSubmatch(line)
		if m != nil {
			found = m[1]
			break
		}
	}
	if found == "" {
		t.Fatal("Muster in scripts/lib/onboard-detect-lib.sh nicht gefunden — " +
			"wurde _component_is_flutter umgebaut? Dann diesen Test mit umbauen, nicht loeschen.")
	}
	if found != FlutterSDKDepPattern {
		t.Fatalf("Flutter-Erkennung driftet wieder auseinander:\n  bash: %q\n  go:   %q",
			found, FlutterSDKDepPattern)
	}
}

func repoRoot(t *testing.T) string {
	t.Helper()
	dir, err := os.Getwd()
	if err != nil {
		t.Fatal(err)
	}
	for i := 0; i < 8; i++ {
		if _, err := os.Stat(filepath.Join(dir, "go.mod")); err == nil {
			return dir
		}
		parent := filepath.Dir(dir)
		if parent == dir {
			break
		}
		dir = parent
	}
	t.Fatal("Repo-Wurzel (go.mod) nicht gefunden")
	return ""
}
