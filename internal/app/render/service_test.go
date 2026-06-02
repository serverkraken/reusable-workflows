package render

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/serverkraken/reusable-workflows/internal/domain"
)

type templateCall struct {
	template string
	output   string
	context  string
}

type fakeTemplates struct {
	calls    []templateCall
	contexts [][]byte
	content  map[string]string
	errFor   string
	noWrite  bool
}

func (f *fakeTemplates) Execute(_ context.Context, templatePath, outputPath, contextPath string) error {
	if filepath.Base(templatePath) == f.errFor {
		return errors.New("template execution failed")
	}
	ctx, err := os.ReadFile(contextPath)
	if err != nil {
		return err
	}
	f.contexts = append(f.contexts, ctx)
	f.calls = append(f.calls, templateCall{template: filepath.ToSlash(templatePath), output: filepath.ToSlash(outputPath), context: contextPath})
	if err := os.MkdirAll(filepath.Dir(outputPath), 0o755); err != nil {
		return err
	}
	if f.noWrite {
		return nil
	}
	content := f.content[filepath.Base(templatePath)]
	if content == "" {
		content = filepath.Base(templatePath) + "\n\n\n"
	}
	return os.WriteFile(outputPath, []byte(content), 0o644)
}

func TestRenderSingleServiceWritesFilesSubstitutesRepoAndLock(t *testing.T) {
	catalog := renderCatalog(t, allTemplateFiles()...)
	target := t.TempDir()
	profile := writeProfile(t, target, `{
	  "schema_version": 1,
	  "target_repo": "serverkraken/example",
	  "default_branch": "main",
	  "current_version": "1.2.3",
	  "monorepo": false,
	  "topics": ["sk-prerelease-on-push"],
	  "components": [{
	    "path": ".",
	    "primary_language": "go",
	    "release_please_type": "go",
	    "dockerfiles": [{"path": "Dockerfile", "image_name": "ghcr.io/$REPO/app", "release_eligible": true}],
	    "release_signals": {}
	  }]
	}`)
	templates := &fakeTemplates{content: map[string]string{
		"release.yml.tmpl":                "release ghcr.io/$REPO/app\n\n\n",
		"prerelease.yml.tmpl":             "pre ghcr.io/$REPO/app\n\n",
		"prerelease-on-push.yml.tmpl":     "push ghcr.io/$REPO/app\n",
		"release-please-config.json.tmpl": `{"single":true}` + "\n\n",
	}}
	err := (Service{
		Templates: templates,
		Now:       fixedNow,
	}).Render(context.Background(), Request{
		CatalogPath:     catalog,
		TargetPath:      target,
		ProfileJSONPath: profile,
		PinVersion:      "v4",
		RenderedAgainst: "v4.2.0",
	})
	if err != nil {
		t.Fatal(err)
	}

	wantFiles := []string{
		".github/workflows/ci.yml",
		".github/workflows/release.yml",
		".github/workflows/prerelease.yml",
		".github/workflows/cleanup.yml",
		".github/workflows/prerelease-on-push.yml",
		"release-please-config.json",
		".release-please-manifest.json",
	}
	for _, rel := range wantFiles {
		content := readRenderFile(t, target, rel)
		if !strings.HasSuffix(content, "\n") || strings.HasSuffix(content, "\n\n") {
			t.Fatalf("%s has bad trailing newline shape: %q", rel, content)
		}
	}
	if got := readRenderFile(t, target, ".github/workflows/release.yml"); !strings.Contains(got, "serverkraken/example") || strings.Contains(got, "$REPO") {
		t.Fatalf("repo substitution failed: %q", got)
	}

	lock := readLock(t, target)
	if lock.SchemaVersion != 1 || lock.CatalogVersion != "v4" || lock.RenderedAgainst != "v4.2.0" || lock.RenderedAt != "2026-06-02T10:11:12Z" {
		t.Fatalf("lock metadata=%+v", lock)
	}
	if len(lock.Files) != len(wantFiles) {
		t.Fatalf("lock files=%v", lock.Files)
	}
	ciHash := sha256String(readRenderFile(t, target, ".github/workflows/ci.yml"))
	if lock.Files[".github/workflows/ci.yml"] != "sha256:"+ciHash {
		t.Fatalf("ci hash=%s want %s", lock.Files[".github/workflows/ci.yml"], ciHash)
	}
	if !strings.Contains(string(templates.contexts[0]), `"pin": "v4"`) || !strings.Contains(string(templates.contexts[0]), `"target_repo": "serverkraken/example"`) {
		t.Fatalf("context=%s", templates.contexts[0])
	}
	if calledTemplate(templates.calls, "release-please-config.monorepo.json.tmpl") {
		t.Fatal("monorepo config rendered for single-service profile")
	}
}

func TestRenderGitOpsOnlyWritesCI(t *testing.T) {
	catalog := renderCatalog(t, "skeletons/ci.yml.tmpl")
	target := t.TempDir()
	profile := writeProfile(t, target, `{
	  "schema_version": 1,
	  "gitops": {"manifests_paths": ["kubernetes/apps"], "sops": true},
	  "topics": ["sk-prerelease-on-push"],
	  "components": [{"path": ".", "primary_language": "gitops", "release_please_type": "simple", "release_signals": {}}]
	}`)
	templates := &fakeTemplates{}
	if err := (Service{Templates: templates, Now: fixedNow}).Render(context.Background(), Request{
		CatalogPath:     catalog,
		TargetPath:      target,
		ProfileJSONPath: profile,
		PinVersion:      "v4",
	}); err != nil {
		t.Fatal(err)
	}
	if len(templates.calls) != 1 || !strings.HasSuffix(templates.calls[0].template, "skeletons/ci.yml.tmpl") {
		t.Fatalf("calls=%+v", templates.calls)
	}
	lock := readLock(t, target)
	if len(lock.Files) != 1 || lock.Files[".github/workflows/ci.yml"] == "" {
		t.Fatalf("lock files=%v", lock.Files)
	}
	if _, err := os.Stat(filepath.Join(target, ".github/workflows/release.yml")); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("release.yml err=%v", err)
	}
	if lock.RenderedAgainst != "v4" {
		t.Fatalf("rendered_against=%q", lock.RenderedAgainst)
	}
}

func TestRenderMonorepoUsesMonorepoConfig(t *testing.T) {
	catalog := renderCatalog(t, allTemplateFiles()...)
	target := t.TempDir()
	profile := writeProfile(t, target, `{
	  "schema_version": 1,
	  "monorepo": true,
	  "components": [
	    {"path": "services/api", "primary_language": "go", "release_please_type": "go", "release_signals": {}},
	    {"path": "services/worker", "primary_language": "go", "release_please_type": "go", "release_signals": {}}
	  ]
	}`)
	templates := &fakeTemplates{}
	if err := (Service{Templates: templates, Now: fixedNow}).Render(context.Background(), Request{
		CatalogPath:     catalog,
		TargetPath:      target,
		ProfileJSONPath: profile,
		PinVersion:      "v4",
	}); err != nil {
		t.Fatal(err)
	}
	if !calledTemplate(templates.calls, "release-please-config.monorepo.json.tmpl") {
		t.Fatalf("calls=%+v", templates.calls)
	}
	if calledTemplate(templates.calls, "release-please-config.json.tmpl") {
		t.Fatalf("single config rendered: %+v", templates.calls)
	}
}

func TestRenderErrors(t *testing.T) {
	catalog := renderCatalog(t, allTemplateFiles()...)
	target := t.TempDir()
	profile := writeProfile(t, target, `{"schema_version":1,"components":[{"path":".","release_signals":{}}]}`)
	tests := []struct {
		name    string
		service Service
		req     Request
		want    string
	}{
		{
			name:    "usage",
			service: Service{Templates: &fakeTemplates{}},
			req:     Request{},
			want:    "usage: sk-workflows render",
		},
		{
			name:    "missing executor",
			service: Service{},
			req:     Request{CatalogPath: catalog, TargetPath: target, ProfileJSONPath: profile, PinVersion: "v4"},
			want:    "template executor not configured",
		},
		{
			name:    "missing profile",
			service: Service{Templates: &fakeTemplates{}},
			req:     Request{CatalogPath: catalog, TargetPath: target, ProfileJSONPath: filepath.Join(target, "missing.json"), PinVersion: "v4"},
			want:    "profile not found",
		},
		{
			name:    "missing template",
			service: Service{Templates: &fakeTemplates{}},
			req:     Request{CatalogPath: t.TempDir(), TargetPath: target, ProfileJSONPath: profile, PinVersion: "v4"},
			want:    "template missing",
		},
		{
			name:    "template error",
			service: Service{Templates: &fakeTemplates{errFor: "ci.yml.tmpl"}},
			req:     Request{CatalogPath: catalog, TargetPath: target, ProfileJSONPath: profile, PinVersion: "v4"},
			want:    "template execution failed",
		},
		{
			name:    "temp dir error",
			service: Service{Templates: &fakeTemplates{}, TempDir: func() (string, error) { return "", errors.New("temp failed") }},
			req:     Request{CatalogPath: catalog, TargetPath: target, ProfileJSONPath: profile, PinVersion: "v4"},
			want:    "temp failed",
		},
		{
			name:    "template writes no file",
			service: Service{Templates: &fakeTemplates{noWrite: true}},
			req:     Request{CatalogPath: catalog, TargetPath: target, ProfileJSONPath: profile, PinVersion: "v4"},
			want:    "no such file",
		},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			err := tt.service.Render(context.Background(), tt.req)
			if err == nil || !strings.Contains(err.Error(), tt.want) {
				t.Fatalf("err=%v want %q", err, tt.want)
			}
		})
	}
}

func TestRenderInvalidProfileErrors(t *testing.T) {
	target := t.TempDir()
	invalid := filepath.Join(target, "invalid.json")
	if err := os.WriteFile(invalid, []byte("{"), 0o644); err != nil {
		t.Fatal(err)
	}
	err := (Service{Templates: &fakeTemplates{}}).Render(context.Background(), Request{
		CatalogPath:     renderCatalog(t, allTemplateFiles()...),
		TargetPath:      target,
		ProfileJSONPath: invalid,
		PinVersion:      "v4",
	})
	if err == nil || !strings.Contains(err.Error(), "invalid profile JSON") {
		t.Fatalf("err=%v", err)
	}

	empty := writeProfile(t, target, `{"schema_version":1,"components":[]}`)
	err = (Service{Templates: &fakeTemplates{}}).Render(context.Background(), Request{
		CatalogPath:     renderCatalog(t, allTemplateFiles()...),
		TargetPath:      target,
		ProfileJSONPath: empty,
		PinVersion:      "v4",
	})
	if err == nil || !strings.Contains(err.Error(), "components must not be empty") {
		t.Fatalf("err=%v", err)
	}
}

func TestWriteLockErrorsWhenRenderedFileMissing(t *testing.T) {
	err := writeLock(t.TempDir(), "v4", "v4", "2026-06-02T10:11:12Z", []string{".github/workflows/ci.yml"})
	if err == nil || !strings.Contains(err.Error(), "expected rendered file missing") {
		t.Fatalf("err=%v", err)
	}
}

func TestRenderHelpersErrorAndFallbackBranches(t *testing.T) {
	if err := writeContext(filepath.Join(t.TempDir(), "ctx.json"), "v4", []byte("{")); err == nil {
		t.Fatal("expected invalid raw profile context error")
	}
	if err := normalizeTrailingNewline(filepath.Join(t.TempDir(), "missing.txt")); err == nil {
		t.Fatal("expected normalize missing file error")
	}
	if _, err := sha256File(filepath.Join(t.TempDir(), "missing.txt")); err == nil {
		t.Fatal("expected sha256 missing file error")
	}
	if got := renderedAt(nil); !strings.HasSuffix(got, "Z") {
		t.Fatalf("renderedAt=%q", got)
	}
	if got := repoName(filepath.Join("tmp", "repo"), ""); got != "repo" {
		t.Fatalf("fallback repoName=%q", got)
	}
	if got := repoName(".", ""); got == "" || got == "." {
		t.Fatalf("cwd repoName=%q", got)
	}
}

func TestRenderOneParentDirectoryError(t *testing.T) {
	catalog := renderCatalog(t, "skeletons/ci.yml.tmpl")
	target := t.TempDir()
	if err := os.WriteFile(filepath.Join(target, "blocked"), []byte("file"), 0o644); err != nil {
		t.Fatal(err)
	}
	err := (Service{Templates: &fakeTemplates{}}).renderOne(context.Background(), Request{
		CatalogPath: catalog,
		TargetPath:  target,
	}, renderFile{Template: "skeletons/ci.yml.tmpl", Output: "blocked/ci.yml"}, filepath.Join(t.TempDir(), "ctx.json"))
	if err == nil {
		t.Fatal("expected parent directory error")
	}
}

func TestWriteLockReadFileError(t *testing.T) {
	target := t.TempDir()
	path := filepath.Join(target, ".github/workflows/ci.yml")
	if err := os.MkdirAll(path, 0o755); err != nil {
		t.Fatal(err)
	}
	err := writeLock(target, "v4", "v4", "2026-06-02T10:11:12Z", []string{".github/workflows/ci.yml"})
	if err == nil {
		t.Fatal("expected read directory as file error")
	}
}

func TestEncodeLockEmptyFiles(t *testing.T) {
	content := encodeLock("v4", "v4", "2026-06-02T10:11:12Z", nil, map[string]string{})
	if !strings.Contains(string(content), `"files": {`) {
		t.Fatalf("content=%s", content)
	}
}

func TestSubstituteRepoReadError(t *testing.T) {
	target := t.TempDir()
	if err := os.MkdirAll(filepath.Join(target, ".github/workflows/release.yml"), 0o755); err != nil {
		t.Fatal(err)
	}
	err := substituteRepo(target, domain.Profile{TargetRepo: "serverkraken/example"})
	if err == nil {
		t.Fatal("expected read error")
	}
}

func renderCatalog(t *testing.T, templates ...string) string {
	t.Helper()
	root := t.TempDir()
	for _, rel := range templates {
		path := filepath.Join(root, filepath.FromSlash(templateRoot), filepath.FromSlash(rel))
		if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(path, []byte(rel+"\n"), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	return root
}

func allTemplateFiles() []string {
	return []string{
		"skeletons/ci.yml.tmpl",
		"skeletons/release.yml.tmpl",
		"skeletons/prerelease.yml.tmpl",
		"skeletons/cleanup.yml.tmpl",
		"skeletons/prerelease-on-push.yml.tmpl",
		"configs/release-please-config.json.tmpl",
		"configs/release-please-config.monorepo.json.tmpl",
		"configs/release-please-manifest.json.tmpl",
	}
}

func writeProfile(t *testing.T, dir, content string) string {
	t.Helper()
	path := filepath.Join(dir, "profile-"+strings.ReplaceAll(t.Name(), "/", "-")+".json")
	if err := os.WriteFile(path, []byte(content), 0o644); err != nil {
		t.Fatal(err)
	}
	return path
}

func readRenderFile(t *testing.T, target, rel string) string {
	t.Helper()
	content, err := os.ReadFile(filepath.Join(target, filepath.FromSlash(rel)))
	if err != nil {
		t.Fatal(err)
	}
	return string(content)
}

func readLock(t *testing.T, target string) struct {
	SchemaVersion   int               `json:"schema_version"`
	CatalogVersion  string            `json:"catalog_version"`
	RenderedAgainst string            `json:"rendered_against"`
	RenderedAt      string            `json:"rendered_at"`
	Files           map[string]string `json:"files"`
} {
	t.Helper()
	content, err := os.ReadFile(filepath.Join(target, filepath.FromSlash(lockPath)))
	if err != nil {
		t.Fatal(err)
	}
	var lock struct {
		SchemaVersion   int               `json:"schema_version"`
		CatalogVersion  string            `json:"catalog_version"`
		RenderedAgainst string            `json:"rendered_against"`
		RenderedAt      string            `json:"rendered_at"`
		Files           map[string]string `json:"files"`
	}
	if err := json.Unmarshal(content, &lock); err != nil {
		t.Fatal(err)
	}
	return lock
}

func calledTemplate(calls []templateCall, name string) bool {
	for _, call := range calls {
		if strings.HasSuffix(call.template, name) {
			return true
		}
	}
	return false
}

func sha256String(content string) string {
	sum := sha256.Sum256([]byte(content))
	return hex.EncodeToString(sum[:])
}

func fixedNow() time.Time {
	return time.Date(2026, 6, 2, 10, 11, 12, 0, time.UTC)
}
