package godetect

import (
	"context"
	"encoding/json"
	"errors"
	"path/filepath"
	"testing"
)

// unreachableGitHub stands in for `gh` without credentials: every call fails.
type unreachableGitHub struct{}

func (unreachableGitHub) DefaultBranch(context.Context, string) (string, error) {
	return "", errors.New("gh: no authentication token")
}
func (unreachableGitHub) LatestStableRelease(context.Context, string) (string, error) {
	return "", errors.New("gh: no authentication token")
}
func (unreachableGitHub) ReleaseTags(context.Context, string) ([]string, error) {
	return nil, errors.New("gh: no authentication token")
}
func (unreachableGitHub) Topics(context.Context, string) ([]string, error) {
	return nil, errors.New("gh: no authentication token")
}

// Drift runs in jobs that mint no GitHub token, and the Bash engine this
// adapter replaces degrades rather than failing there. Detect on its own treats
// an unreachable repo as fatal, so without the tolerant wrapper every tokenless
// drift run would report a render error instead of comparing anything.
func TestProfileJSONDegradesWhenRepoUnreachable(t *testing.T) {
	repo := filepath.Join("..", "..", "..", "tests", "fixtures", "onboard", "go-root-multi-image")

	got, err := Adapter{GitHub: unreachableGitHub{}}.ProfileJSON(context.Background(), "", repo, "serverkraken/fixture")
	if err != nil {
		t.Fatalf("ProfileJSON should degrade, not fail: %v", err)
	}
	var profile struct {
		DefaultBranch string `json:"default_branch"`
	}
	if err := json.Unmarshal(got, &profile); err != nil {
		t.Fatalf("unmarshal profile: %v\n%s", err, got)
	}
	if profile.DefaultBranch != "main" {
		t.Errorf("default_branch = %q, want the \"main\" fallback", profile.DefaultBranch)
	}
}

// The whole point of this adapter: the Bash detector rejects a repo carrying an
// adopter manifest, which used to leave drift's render-and-compare permanently
// broken for exactly those repos. Detecting one here is the regression guard.
func TestProfileJSONDetectsRepoWithAdopterManifest(t *testing.T) {
	repo := filepath.Join("..", "..", "..", "tests", "fixtures", "onboard", "go-root-multi-image")

	got, err := Adapter{}.ProfileJSON(context.Background(), "", repo, "serverkraken/fixture")
	if err != nil {
		t.Fatalf("ProfileJSON: %v", err)
	}

	var profile struct {
		TargetRepo string `json:"target_repo"`
		Components []struct {
			Path        string `json:"path"`
			Dockerfiles []struct {
				Path string `json:"path"`
			} `json:"dockerfiles"`
		} `json:"components"`
	}
	if err := json.Unmarshal(got, &profile); err != nil {
		t.Fatalf("unmarshal profile: %v\n%s", err, got)
	}
	if profile.TargetRepo != "serverkraken/fixture" {
		t.Errorf("target_repo = %q, want serverkraken/fixture", profile.TargetRepo)
	}
	if len(profile.Components) == 0 {
		t.Fatalf("no components detected\n%s", got)
	}
	// The fixture is named for its several images; a manifest-blind detector
	// would not surface them.
	images := 0
	for _, c := range profile.Components {
		images += len(c.Dockerfiles)
	}
	if images < 2 {
		t.Errorf("detected %d dockerfiles, want >= 2\n%s", images, got)
	}
}

func TestProfileJSONReportsDetectionFailure(t *testing.T) {
	if _, err := (Adapter{}).ProfileJSON(context.Background(), "", filepath.Join(t.TempDir(), "absent"), ""); err == nil {
		t.Fatal("expected an error for a non-existent repo path")
	}
}

// Die Toleranz muss ALLE vier Metadaten-Aufrufe umfassen, nicht nur
// DefaultBranch. Seit C-4/C-5 sind Release- und Topics-Fehler im Kern fatal —
// richtig fuer das Onboarding, das ein Repo zum ersten Mal rendert. Drift
// rendert ein bereits onboardetes Repo nur erneut, um zu vergleichen, und
// laeuft in Jobs ohne Token.
//
// Ohne diesen Test wuerde eine spaetere Verengung der Toleranz erst auffallen,
// wenn der naechste tokenlose Drift-Lauf einen Render-Fehler statt eines
// Vergleichs meldet.
func TestProfileJSONDegradesOnEveryMetadataCall(t *testing.T) {
	repo := filepath.Join("..", "..", "..", "tests", "fixtures", "onboard", "go-root-multi-image")

	got, err := Adapter{GitHub: unreachableGitHub{}}.ProfileJSON(context.Background(), "", repo, "serverkraken/fixture")
	if err != nil {
		t.Fatalf("ProfileJSON should degrade on every failing call, not fail: %v", err)
	}

	var profile struct {
		DefaultBranch  string   `json:"default_branch"`
		CurrentVersion string   `json:"current_version"`
		Topics         []string `json:"topics"`
	}
	if err := json.Unmarshal(got, &profile); err != nil {
		t.Fatalf("unmarshal profile: %v\n%s", err, got)
	}
	if profile.DefaultBranch != "main" {
		t.Errorf("default_branch = %q, want the \"main\" fallback", profile.DefaultBranch)
	}
	// Genau der Wert, der beim Onboarding NICHT geraten werden darf — hier ist
	// er richtig, weil Drift ihn nur vergleicht und nichts damit seedet.
	if profile.CurrentVersion != "0.0.0" {
		t.Errorf("current_version = %q, want the 0.0.0 fallback", profile.CurrentVersion)
	}
	if len(profile.Topics) != 0 {
		t.Errorf("topics = %v, want empty", profile.Topics)
	}
}
