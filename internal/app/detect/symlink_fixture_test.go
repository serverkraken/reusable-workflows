package detect

import (
	"bufio"
	"io/fs"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// materializedFixture kopiert eine Onboard-Fixture nach t.TempDir() und legt
// dort die Symlinks aus ihrer symlinks.txt an. Gegenstueck zu
// tests/shell/lib/materialize-symlinks.sh.
//
// Getrackte Symlinks lassen den Runner beim Entpacken jeder Composite-Action
// des Katalogs abbrechen (#458), deshalb entstehen sie erst zur Laufzeit. Der
// Kopiename bleibt der Fixture-Name, weil Engines den Basisnamen auswerten.
func materializedFixture(t *testing.T, name string) string {
	t.Helper()
	src := fixture(t, name)
	dest := filepath.Join(t.TempDir(), name)

	err := filepath.WalkDir(src, func(path string, d fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		rel, err := filepath.Rel(src, path)
		if err != nil {
			return err
		}
		target := filepath.Join(dest, rel)
		switch {
		case d.IsDir():
			return os.MkdirAll(target, 0o755)
		case rel == "symlinks.txt":
			return nil
		default:
			data, err := os.ReadFile(path)
			if err != nil {
				return err
			}
			return os.WriteFile(target, data, 0o644)
		}
	})
	if err != nil {
		t.Fatalf("Fixture %s kopieren: %v", name, err)
	}

	f, err := os.Open(filepath.Join(src, "symlinks.txt"))
	if err != nil {
		t.Fatalf("Manifest von %s: %v", name, err)
	}
	defer f.Close()

	count := 0
	sc := bufio.NewScanner(f)
	for sc.Scan() {
		line := strings.TrimSpace(sc.Text())
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		fields := strings.Fields(line)
		if len(fields) != 2 {
			t.Fatalf("ungueltige Manifest-Zeile in %s: %q", name, line)
		}
		link := filepath.Join(dest, fields[0])
		if err := os.MkdirAll(filepath.Dir(link), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.Symlink(fields[1], link); err != nil {
			t.Fatalf("Symlink %s anlegen: %v", fields[0], err)
		}
		count++
	}
	if err := sc.Err(); err != nil {
		t.Fatal(err)
	}
	if count == 0 {
		t.Fatalf("Manifest von %s enthaelt keinen Link", name)
	}
	return dest
}
