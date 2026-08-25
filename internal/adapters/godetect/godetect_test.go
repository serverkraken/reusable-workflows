package godetect

import (
	"context"
	"encoding/json"
	"path/filepath"
	"testing"
)

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
