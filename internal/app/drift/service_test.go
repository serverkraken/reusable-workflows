package drift

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"

	"github.com/serverkraken/reusable-workflows/internal/domain"
)

type fakeDetector struct {
	profile    []byte
	err        error
	targetRepo string
}

func (f *fakeDetector) ProfileJSON(_ context.Context, _, _, targetRepo string) ([]byte, error) {
	f.targetRepo = targetRepo
	if f.err != nil {
		return nil, f.err
	}
	return f.profile, nil
}

type fakeRenderer struct {
	err     error
	files   map[string]string
	profile string
}

func (f *fakeRenderer) Render(_ context.Context, _, targetPath, profilePath, _ string) error {
	f.profile = profilePath
	if f.err != nil {
		return f.err
	}
	for p, content := range f.files {
		full := filepath.Join(targetPath, filepath.FromSlash(p))
		if err := os.MkdirAll(filepath.Dir(full), 0o755); err != nil {
			return err
		}
		if err := os.WriteFile(full, []byte(content), 0o644); err != nil {
			return err
		}
	}
	return nil
}

type fakeGit struct {
	origin string
	err    error
}

func (f fakeGit) OriginURL(context.Context, string) (string, error) {
	return f.origin, f.err
}

func TestDriftStatuses(t *testing.T) {
	tests := []struct {
		name         string
		current      string
		lockVersion  string
		mutate       func(t *testing.T, repo string)
		wantStatus   domain.DriftStatus
		wantModified []string
		wantLock     string
		wantCurrent  string
		wantNoRender bool
	}{
		{
			name:         "clean",
			current:      "v4",
			lockVersion:  "v4",
			wantStatus:   domain.DriftClean,
			wantLock:     "v4",
			wantCurrent:  "v4",
			wantNoRender: false,
		},
		{
			name:        "modified",
			current:     "v4",
			lockVersion: "v4",
			mutate: func(t *testing.T, repo string) {
				t.Helper()
				appendFile(t, filepath.Join(repo, ".github/workflows/ci.yml"), "\n# edit")
			},
			wantStatus:   domain.DriftModified,
			wantModified: []string{".github/workflows/ci.yml"},
			wantLock:     "v4",
			wantCurrent:  "v4",
			wantNoRender: true,
		},
		{
			name:         "behind",
			current:      "v4",
			lockVersion:  "v3",
			wantStatus:   domain.DriftBehind,
			wantLock:     "v3",
			wantCurrent:  "v4",
			wantNoRender: true,
		},
		{
			name:        "behind modified",
			current:     "v4",
			lockVersion: "v3",
			mutate: func(t *testing.T, repo string) {
				t.Helper()
				appendFile(t, filepath.Join(repo, ".github/workflows/release.yml"), "\n# edit")
			},
			wantStatus:   domain.DriftBehindModified,
			wantModified: []string{".github/workflows/release.yml"},
			wantLock:     "v3",
			wantCurrent:  "v4",
			wantNoRender: true,
		},
		{
			name:        "missing",
			current:     "v4",
			lockVersion: "v4",
			mutate: func(t *testing.T, repo string) {
				t.Helper()
				if err := os.Remove(filepath.Join(repo, ".github/workflows/cleanup.yml")); err != nil {
					t.Fatal(err)
				}
			},
			wantStatus:   domain.DriftModified,
			wantModified: []string{".github/workflows/cleanup.yml(missing)"},
			wantLock:     "v4",
			wantCurrent:  "v4",
			wantNoRender: true,
		},
		{
			name:        "manifest is skipped",
			current:     "v4",
			lockVersion: "v4",
			mutate: func(t *testing.T, repo string) {
				t.Helper()
				writeFile(t, filepath.Join(repo, ".release-please-manifest.json"), `{".":"9.9.9"}`)
			},
			wantStatus:  domain.DriftClean,
			wantLock:    "v4",
			wantCurrent: "v4",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			repo := fixtureRepo(t, tt.lockVersion)
			if tt.mutate != nil {
				tt.mutate(t, repo)
			}
			detector := &fakeDetector{profile: []byte(`{"schema_version":1}`)}
			renderer := &fakeRenderer{files: renderedFixtureFiles()}
			res, err := (Service{Detector: detector, Renderer: renderer}).Drift(context.Background(), Request{
				TargetPath:     repo,
				CatalogPath:    t.TempDir(),
				CurrentVersion: tt.current,
			})
			if err != nil {
				t.Fatalf("Drift error: %v", err)
			}
			if res.Status != tt.wantStatus {
				t.Fatalf("status=%s want %s result=%+v", res.Status, tt.wantStatus, res)
			}
			if !reflect.DeepEqual(res.Modified, tt.wantModified) {
				t.Fatalf("modified=%v want %v", res.Modified, tt.wantModified)
			}
			if res.LockVersion != tt.wantLock || res.CurrentVersion != tt.wantCurrent {
				t.Fatalf("versions=%q/%q", res.LockVersion, res.CurrentVersion)
			}
			if tt.wantNoRender && detector.targetRepo != "" {
				t.Fatalf("render compare unexpectedly ran: targetRepo=%q", detector.targetRepo)
			}
		})
	}
}

func TestDriftNoLockAndInputErrors(t *testing.T) {
	repo := t.TempDir()
	catalog := t.TempDir()
	res, err := (Service{}).Drift(context.Background(), Request{TargetPath: repo, CatalogPath: catalog})
	if err != nil {
		t.Fatalf("no-lock error: %v", err)
	}
	if res.Status != domain.DriftNoLock {
		t.Fatalf("status=%s", res.Status)
	}
	if _, err := (Service{}).Drift(context.Background(), Request{TargetPath: "/missing", CatalogPath: catalog}); err == nil {
		t.Fatal("expected missing target error")
	}
	if _, err := (Service{}).Drift(context.Background(), Request{TargetPath: repo, CatalogPath: "/missing"}); err == nil {
		t.Fatal("expected missing catalog error")
	}

	writeFile(t, filepath.Join(repo, lockPath), "{")
	if _, err := (Service{}).Drift(context.Background(), Request{TargetPath: repo, CatalogPath: catalog}); err == nil {
		t.Fatal("expected invalid lock error")
	}
}

func TestRenderCompareStaleLockAndErrors(t *testing.T) {
	tests := []struct {
		name        string
		detectorErr error
		renderErr   error
		rendered    map[string]string
		wantStatus  domain.DriftStatus
		wantMod     []string
		wantError   string
	}{
		{
			name:       "stale lock",
			rendered:   map[string]string{".github/workflows/ci.yml": "changed\n"},
			wantStatus: domain.DriftStaleLock,
			wantMod:    []string{".github/workflows/ci.yml"},
		},
		{
			name:        "detect failure stays clean",
			detectorErr: errors.New("detect failed with verbose stderr that should be truncated after enough characters are present in the message"),
			rendered:    renderedFixtureFiles(),
			wantStatus:  domain.DriftClean,
			wantError:   "detect-failed:",
		},
		{
			name:       "render failure stays clean",
			renderErr:  errors.New("render failed"),
			rendered:   renderedFixtureFiles(),
			wantStatus: domain.DriftClean,
			wantError:  "render-failed:",
		},
		{
			name:       "missing rendered tracked file is skipped",
			rendered:   map[string]string{},
			wantStatus: domain.DriftClean,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			repo := fixtureRepo(t, "v4")
			detector := &fakeDetector{profile: []byte(`{"schema_version":1}`), err: tt.detectorErr}
			renderer := &fakeRenderer{files: tt.rendered, err: tt.renderErr}
			res, err := (Service{Detector: detector, Renderer: renderer}).Drift(context.Background(), Request{
				TargetPath:     repo,
				CatalogPath:    t.TempDir(),
				CurrentVersion: "v4",
			})
			if err != nil {
				t.Fatalf("Drift error: %v", err)
			}
			if res.Status != tt.wantStatus {
				t.Fatalf("status=%s want %s result=%+v", res.Status, tt.wantStatus, res)
			}
			if !reflect.DeepEqual(res.Modified, tt.wantMod) {
				t.Fatalf("modified=%v want %v", res.Modified, tt.wantMod)
			}
			if tt.wantError != "" && !strings.HasPrefix(res.RenderError, tt.wantError) {
				t.Fatalf("render_error=%q want prefix %q", res.RenderError, tt.wantError)
			}
			if len(res.RenderError) > len(tt.wantError)+renderErrorLimit {
				t.Fatalf("render_error not truncated: %q", res.RenderError)
			}
			if tt.detectorErr == nil && renderer.profile == "" {
				t.Fatal("renderer did not receive a profile path")
			}
		})
	}
}

func TestRenderCompareDerivesTargetRepoFromOrigin(t *testing.T) {
	repo := fixtureRepo(t, "v4")
	detector := &fakeDetector{profile: []byte(`{"schema_version":1}`)}
	renderer := &fakeRenderer{files: renderedFixtureFiles()}
	res, err := (Service{
		Detector: detector,
		Renderer: renderer,
		Git:      fakeGit{origin: "git@github.com:serverkraken/example.git"},
	}).Drift(context.Background(), Request{TargetPath: repo, CatalogPath: t.TempDir(), CurrentVersion: "v4"})
	if err != nil {
		t.Fatal(err)
	}
	if res.Status != domain.DriftClean {
		t.Fatalf("status=%s", res.Status)
	}
	if detector.targetRepo != "serverkraken/example" {
		t.Fatalf("targetRepo=%q", detector.targetRepo)
	}
}

func TestRenderCompareConfigurationErrors(t *testing.T) {
	repo := fixtureRepo(t, "v4")
	catalog := t.TempDir()
	res, err := (Service{Renderer: &fakeRenderer{files: renderedFixtureFiles()}}).Drift(context.Background(), Request{
		TargetPath:     repo,
		CatalogPath:    catalog,
		CurrentVersion: "v4",
	})
	if err != nil {
		t.Fatal(err)
	}
	if !strings.HasPrefix(res.RenderError, "detect-failed:") {
		t.Fatalf("render_error=%q", res.RenderError)
	}

	res, err = (Service{Detector: &fakeDetector{profile: []byte(`{}`)}}).Drift(context.Background(), Request{
		TargetPath:     repo,
		CatalogPath:    catalog,
		CurrentVersion: "v4",
	})
	if err != nil {
		t.Fatal(err)
	}
	if !strings.HasPrefix(res.RenderError, "render-failed:") {
		t.Fatalf("render_error=%q", res.RenderError)
	}
}

func TestRenderCompareScratchFailures(t *testing.T) {
	repo := fixtureRepo(t, "v4")
	catalog := t.TempDir()
	res, err := (Service{
		Detector: &fakeDetector{profile: []byte(`{}`)},
		Renderer: &fakeRenderer{files: renderedFixtureFiles()},
		TempDir:  func() (string, error) { return "", errors.New("no temp") },
	}).Drift(context.Background(), Request{TargetPath: repo, CatalogPath: catalog, CurrentVersion: "v4"})
	if err != nil {
		t.Fatal(err)
	}
	if !strings.HasPrefix(res.RenderError, "render-failed:") {
		t.Fatalf("temp render_error=%q", res.RenderError)
	}

	notDir := filepath.Join(t.TempDir(), "not-dir")
	writeFile(t, notDir, "x")
	res, err = (Service{
		Detector: &fakeDetector{profile: []byte(`{}`)},
		Renderer: &fakeRenderer{files: renderedFixtureFiles()},
		TempDir:  func() (string, error) { return notDir, nil },
	}).Drift(context.Background(), Request{TargetPath: repo, CatalogPath: catalog, CurrentVersion: "v4"})
	if err != nil {
		t.Fatal(err)
	}
	if !strings.HasPrefix(res.RenderError, "detect-failed:") {
		t.Fatalf("profile write render_error=%q", res.RenderError)
	}
}

func TestLockAndFileHelperErrors(t *testing.T) {
	bad := filepath.Join(t.TempDir(), "bad-lock.json")
	writeFile(t, bad, "{")
	if _, err := readLock(bad); err == nil {
		t.Fatal("expected invalid lock JSON error")
	}
	if _, err := readLock(filepath.Join(t.TempDir(), "missing.json")); err == nil {
		t.Fatal("expected missing lock error")
	}
	if _, err := sha256File(filepath.Join(t.TempDir(), "missing")); err == nil {
		t.Fatal("expected missing sha file error")
	}
	if _, err := sameBytes(filepath.Join(t.TempDir(), "missing-a"), filepath.Join(t.TempDir(), "missing-b")); err == nil {
		t.Fatal("expected missing sameBytes left error")
	}
	leftOnly := filepath.Join(t.TempDir(), "left")
	writeFile(t, leftOnly, "left")
	if _, err := sameBytes(leftOnly, filepath.Join(t.TempDir(), "missing-right")); err == nil {
		t.Fatal("expected missing sameBytes right error")
	}

	nilFilesLock := filepath.Join(t.TempDir(), "lock.json")
	writeFile(t, nilFilesLock, `{"catalog_version":"v4"}`)
	lock, err := readLock(nilFilesLock)
	if err != nil {
		t.Fatal(err)
	}
	if lock.Files == nil || len(lock.Files) != 0 {
		t.Fatalf("files=%v", lock.Files)
	}

	repo := fixtureRepo(t, "v4")
	rendered := t.TempDir()
	writeFile(t, filepath.Join(rendered, ".github/workflows/ci.yml"), "ci\n")
	same, err := sameBytes(filepath.Join(repo, ".github/workflows/ci.yml"), filepath.Join(rendered, ".github/workflows/ci.yml"))
	if err != nil || !same {
		t.Fatalf("sameBytes=%v err=%v", same, err)
	}
	writeFile(t, filepath.Join(rendered, ".github/workflows/ci.yml"), "changed\n")
	same, err = sameBytes(filepath.Join(repo, ".github/workflows/ci.yml"), filepath.Join(rendered, ".github/workflows/ci.yml"))
	if err != nil || same {
		t.Fatalf("sameBytes changed=%v err=%v", same, err)
	}

	dirTarget := t.TempDir()
	if err := os.Mkdir(filepath.Join(dirTarget, "tracked"), 0o755); err != nil {
		t.Fatal(err)
	}
	if _, err := modifiedFiles(dirTarget, domain.OnboardLock{Files: map[string]string{"tracked": "sha256:any"}}); err == nil {
		t.Fatal("expected directory read error from modifiedFiles")
	}
}

func TestStaleFilesSkipsLockManifestAndMissingRendered(t *testing.T) {
	repo := fixtureRepo(t, "v4")
	rendered := t.TempDir()
	writeFile(t, filepath.Join(rendered, ".github/onboard.lock.json"), "different")
	writeFile(t, filepath.Join(rendered, ".release-please-manifest.json"), "different")
	lock := domain.OnboardLock{Files: map[string]string{
		".github/onboard.lock.json":     "sha256:any",
		".release-please-manifest.json": "sha256:any",
		".github/workflows/missing.yml": "sha256:any",
		".github/workflows/release.yml": "sha256:any",
	}}
	writeFile(t, filepath.Join(rendered, ".github/workflows/release.yml"), "changed\n")
	got, err := staleFiles(repo, rendered, lock)
	if err != nil {
		t.Fatal(err)
	}
	if !reflect.DeepEqual(got, []string{".github/workflows/release.yml"}) {
		t.Fatalf("stale=%v", got)
	}

	missingTarget := t.TempDir()
	rendered = t.TempDir()
	writeFile(t, filepath.Join(rendered, ".github/workflows/ci.yml"), "ci\n")
	if _, err := staleFiles(missingTarget, rendered, domain.OnboardLock{Files: map[string]string{".github/workflows/ci.yml": "sha256:any"}}); err == nil {
		t.Fatal("expected target read error from staleFiles")
	}
}

func TestNormalizeGitHubOrigin(t *testing.T) {
	tests := map[string]string{
		"git@github.com:serverkraken/reusable-workflows.git":     "serverkraken/reusable-workflows",
		"https://github.com/serverkraken/reusable-workflows.git": "serverkraken/reusable-workflows",
		"https://github.com/serverkraken/reusable-workflows":     "serverkraken/reusable-workflows",
		"": "",
		"https://example.com/serverkraken/reusable-workflows": "",
		"https://github.com/serverkraken":                     "",
	}
	for in, want := range tests {
		if got := NormalizeGitHubOrigin(in); got != want {
			t.Fatalf("NormalizeGitHubOrigin(%q)=%q want %q", in, got, want)
		}
	}
}

func fixtureRepo(t *testing.T, lockVersion string) string {
	t.Helper()
	repo := t.TempDir()
	for p, content := range renderedFixtureFiles() {
		writeFile(t, filepath.Join(repo, filepath.FromSlash(p)), content)
	}
	writeFile(t, filepath.Join(repo, ".release-please-manifest.json"), `{".":"0.0.0"}`)
	files := map[string]string{}
	for p := range renderedFixtureFiles() {
		files[p] = "sha256:" + hashString(renderedFixtureFiles()[p])
	}
	files[".release-please-manifest.json"] = "sha256:" + hashString(`{".":"0.0.0"}`)
	lock := domain.OnboardLock{SchemaVersion: 1, CatalogVersion: lockVersion, Files: files}
	content, err := json.Marshal(lock)
	if err != nil {
		t.Fatal(err)
	}
	writeFile(t, filepath.Join(repo, lockPath), string(content))
	return repo
}

func renderedFixtureFiles() map[string]string {
	return map[string]string{
		".github/workflows/ci.yml":         "ci\n",
		".github/workflows/release.yml":    "release\n",
		".github/workflows/prerelease.yml": "prerelease\n",
		".github/workflows/cleanup.yml":    "cleanup\n",
		"release-please-config.json":       "{}\n",
	}
}

func writeFile(t *testing.T, path, content string) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte(content), 0o644); err != nil {
		t.Fatal(err)
	}
}

func appendFile(t *testing.T, path, content string) {
	t.Helper()
	f, err := os.OpenFile(path, os.O_APPEND|os.O_WRONLY, 0)
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close()
	if _, err := f.WriteString(content); err != nil {
		t.Fatal(err)
	}
}

func hashString(content string) string {
	sum := sha256.Sum256([]byte(content))
	return hex.EncodeToString(sum[:])
}
