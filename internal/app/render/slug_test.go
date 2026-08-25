package render

import (
	"strings"
	"testing"

	"github.com/serverkraken/reusable-workflows/internal/domain"
)

// Die Bereinigung ist nicht injektiv: `svc/x.y` und `svc/x-y` ergeben beide
// `svc-x-y`. Gerendert waere das zweimal derselbe Job-Key — actionlint meldet
// "key ... is duplicated in jobs section", und GitHub verwirft die Datei.
// Nachgestellt mit genau diesen beiden Pfaden, bevor der Guard entstand.
func comps(paths ...string) domain.Profile {
	var p domain.Profile
	for _, path := range paths {
		p.Components = append(p.Components, domain.Component{Path: path})
	}
	return p
}

func TestSlugCollisionRejected(t *testing.T) {
	err := checkSlugCollisions(comps("svc/x.y", "svc/x-y"))
	if err == nil {
		t.Fatal("kollidierende Job-IDs muessen abgewiesen werden")
	}
	for _, want := range []string{"svc/x.y", "svc/x-y", "svc-x-y"} {
		if !strings.Contains(err.Error(), want) {
			t.Fatalf("Fehler soll %q nennen, war: %v", want, err)
		}
	}
}

func TestDistinctSlugsPass(t *testing.T) {
	if err := checkSlugCollisions(comps("svc/api", "svc/worker", "charts/demo")); err != nil {
		t.Fatalf("unterschiedliche Pfade duerfen nicht kollidieren: %v", err)
	}
}

// Die Wurzel traegt kein Suffix und darf deshalb nie in die Kollisionspruefung
// geraten — sonst schlaegt ein Monorepo mit Wurzelkomponente grundlos fehl.
func TestRootIsExemptFromCollisionCheck(t *testing.T) {
	if err := checkSlugCollisions(comps(".", "svc/api")); err != nil {
		t.Fatalf("die Wurzel darf nicht kollidieren: %v", err)
	}
}

func TestJobIDSlugSanitises(t *testing.T) {
	cases := map[string]string{
		"services/v2.api": "services-v2-api",
		"a/b/c":           "a-b-c",
		"plain":           "plain",
		"with space":      "with-space",
	}
	for in, want := range cases {
		if got := jobIDSlug(in); got != want {
			t.Errorf("jobIDSlug(%q) = %q, erwartet %q", in, got, want)
		}
	}
}
