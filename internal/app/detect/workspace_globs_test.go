package detect

import (
	"context"
	"os"
	"path/filepath"
	"reflect"
	"testing"
)

// Audit B-8/H-8 und B-11/H-7.
//
// Cargo-Member wurden woertlich uebernommen: `members = ["crates/*"]` ergab
// eine Komponente mit dem Pfad `crates/*` — ein Verzeichnis, das es nicht gibt.
// Die echten Crates bekamen dadurch KEINE Jobs: kein Lint, kein Test, kein
// Scan. `crates/*` ist das uebliche Cargo-Layout, und der pnpm-Zweig direkt
// daneben expandierte laengst.
//
// Dazu: ein Member-Pfad kann aus dem Checkout herausfuehren (`../nachbar`). Was
// danach als Komponente gilt, wuerde ausserhalb des ausgecheckten Repos gesucht,
// und die gerenderten Workflows truegen ein `working_directory`, das beim
// Adopter woanders hinzeigt.
//
// Beide Engines verhalten sich jetzt gleich; bats haelt die Bash-Seite fest.

func writeCrate(t *testing.T, dir string) {
	t.Helper()
	if err := os.MkdirAll(filepath.Join(dir, "src"), 0o755); err != nil {
		t.Fatal(err)
	}
	body := "[package]\nname = \"" + filepath.Base(dir) + "\"\nversion = \"0.1.0\"\n"
	if err := os.WriteFile(filepath.Join(dir, "Cargo.toml"), []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, "src", "main.rs"), []byte("fn main(){}\n"), 0o644); err != nil {
		t.Fatal(err)
	}
}

func TestCargoWorkspaceGlobIsExpanded(t *testing.T) {
	repo := t.TempDir()
	writeCrate(t, filepath.Join(repo, "crates", "alpha"))
	writeCrate(t, filepath.Join(repo, "crates", "beta"))
	if err := os.WriteFile(filepath.Join(repo, "Cargo.toml"),
		[]byte("[workspace]\nmembers = [\"crates/*\"]\n"), 0o644); err != nil {
		t.Fatal(err)
	}

	res, err := (Service{}).Detect(context.Background(), Request{RepoPath: repo})
	if err != nil {
		t.Fatal(err)
	}
	got := componentPaths(res.Profile.Components)
	want := []string{"crates/alpha", "crates/beta"}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("paths=%v want %v — ein literales \"crates/*\" heisst, dass die echten Crates keine Jobs bekommen", got, want)
	}
}

func TestCargoWorkspaceMemberOutsideRepoIsDropped(t *testing.T) {
	base := t.TempDir()
	repo := filepath.Join(base, "repo")
	if err := os.MkdirAll(repo, 0o755); err != nil {
		t.Fatal(err)
	}
	writeCrate(t, filepath.Join(base, "nachbar"))
	if err := os.WriteFile(filepath.Join(repo, "Cargo.toml"),
		[]byte("[workspace]\nmembers = [\"../nachbar\"]\n"), 0o644); err != nil {
		t.Fatal(err)
	}

	res, err := (Service{}).Detect(context.Background(), Request{RepoPath: repo})
	if err != nil {
		t.Fatal(err)
	}
	for _, c := range res.Profile.Components {
		if c.Path != "." {
			t.Fatalf("ein Member ausserhalb des Checkouts wurde uebernommen: %q", c.Path)
		}
	}
}

func TestCargoWorkspaceLiteralMembersStillWork(t *testing.T) {
	// Gegenprobe: die Expansion darf gewoehnliche, ausgeschriebene Member nicht
	// verlieren.
	repo := t.TempDir()
	writeCrate(t, filepath.Join(repo, "pkg-a"))
	writeCrate(t, filepath.Join(repo, "pkg-b"))
	if err := os.WriteFile(filepath.Join(repo, "Cargo.toml"),
		[]byte("[workspace]\nmembers = [\"pkg-a\", \"pkg-b\"]\n"), 0o644); err != nil {
		t.Fatal(err)
	}

	res, err := (Service{}).Detect(context.Background(), Request{RepoPath: repo})
	if err != nil {
		t.Fatal(err)
	}
	if got := componentPaths(res.Profile.Components); !reflect.DeepEqual(got, []string{"pkg-a", "pkg-b"}) {
		t.Fatalf("paths=%v", got)
	}
}

func TestGoWorkUseOutsideRepoIsDropped(t *testing.T) {
	// B-11. Beim Cargo-Fix (#308) hatte ich das im PR-Text als miterledigt
	// bezeichnet — es war es nicht: `parseGoWork` blieb unangetastet, und beide
	// Engines lieferten weiterhin `["../nachbar"]`. Nachgemessen, dann behoben.
	base := t.TempDir()
	repo := filepath.Join(base, "repo")
	if err := os.MkdirAll(repo, 0o755); err != nil {
		t.Fatal(err)
	}
	nachbar := filepath.Join(base, "nachbar")
	if err := os.MkdirAll(nachbar, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(nachbar, "go.mod"), []byte("module nachbar\ngo 1.22\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(repo, "go.work"), []byte("go 1.22\n\nuse ../nachbar\n"), 0o644); err != nil {
		t.Fatal(err)
	}

	res, err := (Service{}).Detect(context.Background(), Request{RepoPath: repo})
	if err != nil {
		t.Fatal(err)
	}
	for _, c := range res.Profile.Components {
		if c.Path != "." {
			t.Fatalf("ein use-Pfad ausserhalb des Checkouts wurde uebernommen: %q", c.Path)
		}
	}
}

func TestGoWorkOrdinaryUseStillWorks(t *testing.T) {
	// Gegenprobe: die Eingrenzung darf ein gewoehnliches `use ./svc` nicht
	// verlieren — der fuehrende `./` muss weiterhin aufgeloest werden.
	repo := t.TempDir()
	if err := os.MkdirAll(filepath.Join(repo, "svc"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(repo, "svc", "go.mod"), []byte("module svc\ngo 1.22\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(repo, "go.work"), []byte("go 1.22\n\nuse ./svc\n"), 0o644); err != nil {
		t.Fatal(err)
	}

	res, err := (Service{}).Detect(context.Background(), Request{RepoPath: repo})
	if err != nil {
		t.Fatal(err)
	}
	if got := componentPaths(res.Profile.Components); !reflect.DeepEqual(got, []string{"svc"}) {
		t.Fatalf("paths=%v want [svc]", got)
	}
}
