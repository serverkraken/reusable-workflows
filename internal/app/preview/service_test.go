package preview

import (
	"context"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"

	"github.com/serverkraken/reusable-workflows/internal/app/detect"
	"github.com/serverkraken/reusable-workflows/internal/app/render"
	"github.com/serverkraken/reusable-workflows/internal/domain"
)

type fakeDetector struct {
	req detect.Request
	res detect.Result
	err error
}

func (f *fakeDetector) Detect(_ context.Context, req detect.Request) (detect.Result, error) {
	f.req = req
	return f.res, f.err
}

type fakeRenderer struct {
	req      render.Request
	err      error
	skipLock bool
}

func (f *fakeRenderer) Render(_ context.Context, req render.Request) error {
	f.req = req
	if f.err != nil {
		return f.err
	}
	if err := os.MkdirAll(filepath.Join(req.TargetPath, ".github", "workflows"), 0o755); err != nil {
		return err
	}
	if err := os.WriteFile(filepath.Join(req.TargetPath, ".github", "workflows", "ci.yml"), []byte("ci\n"), 0o644); err != nil {
		return err
	}
	if f.skipLock {
		return nil
	}
	lock := domain.OnboardLock{
		SchemaVersion:   1,
		CatalogVersion:  req.PinVersion,
		RenderedAgainst: req.RenderedAgainst,
		Files: map[string]string{
			"release-please-config.json": "sha256:def",
			".github/workflows/ci.yml":   "sha256:abc",
		},
	}
	content, err := json.Marshal(lock)
	if err != nil {
		return err
	}
	return os.WriteFile(filepath.Join(req.TargetPath, ".github", "onboard.lock.json"), content, 0o644)
}

func TestPreviewDetectsWritesProfileRendersAndReportsFiles(t *testing.T) {
	detector := &fakeDetector{res: detect.Result{
		Legacy: domain.LegacyOutputs{
			Language:       "go",
			ReleaseType:    "go",
			CurrentVersion: "1.2.3",
			DefaultBranch:  "main",
		},
		Profile: domain.Profile{
			SchemaVersion:  1,
			DefaultBranch:  "main",
			CurrentVersion: "1.2.3",
			Components: []domain.Component{{
				Path:              ".",
				PrimaryLanguage:   "go",
				ReleasePleaseType: "go",
				ReleaseSignals:    domain.ReleaseSignal{},
			}},
		},
	}}
	renderer := &fakeRenderer{}
	repo := filepath.Join(t.TempDir(), "repo")
	if err := os.MkdirAll(repo, 0o755); err != nil {
		t.Fatal(err)
	}
	out := t.TempDir()

	res, err := (Service{Detector: detector, Renderer: renderer}).Preview(context.Background(), Request{
		CatalogPath:      "/catalog",
		RepoPath:         repo,
		OutPath:          out,
		LanguageOverride: "auto",
		PinVersion:       "v4",
		RenderedAgainst:  "v4.2.0",
	})
	if err != nil {
		t.Fatal(err)
	}
	if detector.req.RepoPath != repo || detector.req.LanguageOverride != "auto" {
		t.Fatalf("detect req=%+v", detector.req)
	}
	if renderer.req.CatalogPath != "/catalog" || renderer.req.TargetPath != out || renderer.req.PinVersion != "v4" || renderer.req.RenderedAgainst != "v4.2.0" {
		t.Fatalf("render req=%+v", renderer.req)
	}
	if renderer.req.ProfileJSONPath != filepath.Join(out, "profile.json") {
		t.Fatalf("profile path=%q", renderer.req.ProfileJSONPath)
	}
	if res.Profile.TargetRepo != "repo" {
		t.Fatalf("derived target repo=%q", res.Profile.TargetRepo)
	}
	if !reflect.DeepEqual(res.RenderedFiles, []string{".github/workflows/ci.yml", "release-please-config.json"}) {
		t.Fatalf("rendered files=%v", res.RenderedFiles)
	}
	content, err := os.ReadFile(res.ProfileJSONPath)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(content), `"target_repo": "repo"`) || !strings.HasSuffix(string(content), "\n") {
		t.Fatalf("profile=%s", content)
	}
}

func TestPreviewKeepsExplicitTargetRepo(t *testing.T) {
	detector := &fakeDetector{res: detect.Result{
		Profile: domain.Profile{
			SchemaVersion: 1,
			TargetRepo:    "serverkraken/app",
			Components: []domain.Component{{
				Path:           ".",
				ReleaseSignals: domain.ReleaseSignal{},
			}},
		},
	}}
	out := t.TempDir()
	res, err := (Service{Detector: detector, Renderer: &fakeRenderer{}}).Preview(context.Background(), Request{
		CatalogPath: "/catalog",
		RepoPath:    t.TempDir(),
		OutPath:     out,
		TargetRepo:  "serverkraken/app",
		PinVersion:  "v4",
	})
	if err != nil {
		t.Fatal(err)
	}
	if detector.req.TargetRepo != "serverkraken/app" || res.Profile.TargetRepo != "serverkraken/app" {
		t.Fatalf("target repo req=%+v profile=%+v", detector.req, res.Profile)
	}
}

func TestPreviewValidationAndDependencyErrors(t *testing.T) {
	valid := Request{
		CatalogPath: "/catalog",
		RepoPath:    filepath.Join(t.TempDir(), "repo"),
		OutPath:     t.TempDir(),
		PinVersion:  "v4",
	}
	if err := os.MkdirAll(valid.RepoPath, 0o755); err != nil {
		t.Fatal(err)
	}
	tests := []struct {
		name    string
		service Service
		req     Request
		want    string
	}{
		{
			name:    "usage",
			service: Service{Detector: &fakeDetector{}, Renderer: &fakeRenderer{}},
			req:     Request{},
			want:    "usage: sk-workflows preview",
		},
		{
			name:    "missing detector",
			service: Service{Renderer: &fakeRenderer{}},
			req:     valid,
			want:    "detector not configured",
		},
		{
			name:    "missing renderer",
			service: Service{Detector: &fakeDetector{}},
			req:     valid,
			want:    "renderer not configured",
		},
		{
			name:    "same output",
			service: Service{Detector: &fakeDetector{}, Renderer: &fakeRenderer{}},
			req:     Request{CatalogPath: "/catalog", RepoPath: valid.RepoPath, OutPath: valid.RepoPath, PinVersion: "v4"},
			want:    "must not be the source repo",
		},
		{
			name:    "detect error",
			service: Service{Detector: &fakeDetector{err: errors.New("detect failed")}, Renderer: &fakeRenderer{}},
			req:     valid,
			want:    "detect failed",
		},
		{
			name: "render error",
			service: Service{
				Detector: &fakeDetector{res: detect.Result{Profile: domain.Profile{Components: []domain.Component{{Path: ".", ReleaseSignals: domain.ReleaseSignal{}}}}}},
				Renderer: &fakeRenderer{err: errors.New("render failed")},
			},
			req:  valid,
			want: "render failed",
		},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			_, err := tt.service.Preview(context.Background(), tt.req)
			if err == nil || !strings.Contains(err.Error(), tt.want) {
				t.Fatalf("err=%v want %q", err, tt.want)
			}
		})
	}
}

func TestPreviewFilesystemErrorBranches(t *testing.T) {
	repo := filepath.Join(t.TempDir(), "repo")
	if err := os.MkdirAll(repo, 0o755); err != nil {
		t.Fatal(err)
	}
	blocked := filepath.Join(t.TempDir(), "blocked")
	if err := os.WriteFile(blocked, []byte("file"), 0o644); err != nil {
		t.Fatal(err)
	}
	_, err := (Service{Detector: &fakeDetector{}, Renderer: &fakeRenderer{}}).Preview(context.Background(), Request{
		CatalogPath: "/catalog",
		RepoPath:    repo,
		OutPath:     filepath.Join(blocked, "child"),
		PinVersion:  "v4",
	})
	if err == nil {
		t.Fatal("expected mkdir error")
	}

	_, err = (Service{
		Detector: &fakeDetector{res: detect.Result{Profile: domain.Profile{Components: []domain.Component{{Path: ".", ReleaseSignals: domain.ReleaseSignal{}}}}}},
		Renderer: &fakeRenderer{skipLock: true},
	}).Preview(context.Background(), Request{
		CatalogPath: "/catalog",
		RepoPath:    repo,
		OutPath:     t.TempDir(),
		PinVersion:  "v4",
	})
	if err == nil || !strings.Contains(err.Error(), "preview lock not found") {
		t.Fatalf("missing lock err=%v", err)
	}

	if err := writeProfile(filepath.Join(t.TempDir(), "missing", "profile.json"), domain.Profile{}); err == nil {
		t.Fatal("expected profile write error")
	}
}

func TestPreviewLockErrors(t *testing.T) {
	if _, err := renderedFiles(t.TempDir()); err == nil || !strings.Contains(err.Error(), "preview lock not found") {
		t.Fatalf("missing lock err=%v", err)
	}
	out := t.TempDir()
	if err := os.MkdirAll(filepath.Join(out, ".github"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(out, ".github", "onboard.lock.json"), []byte("{"), 0o644); err != nil {
		t.Fatal(err)
	}
	if _, err := renderedFiles(out); err == nil || !strings.Contains(err.Error(), "invalid preview lock") {
		t.Fatalf("invalid lock err=%v", err)
	}
}
