package cli

import (
	"bytes"
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/serverkraken/reusable-workflows/internal/domain"
)

func repoFixture(t *testing.T, name string) string {
	t.Helper()
	p, err := filepath.Abs(filepath.Join("..", "..", "..", "tests", "fixtures", "onboard", name))
	if err != nil {
		t.Fatal(err)
	}
	return p
}

func TestRunHelpAndUnknown(t *testing.T) {
	var out, errb bytes.Buffer
	if code := Run(context.Background(), nil, &out, &errb); code != 0 {
		t.Fatalf("help code=%d", code)
	}
	if !strings.Contains(out.String(), "sk-workflows detect") {
		t.Fatalf("help output=%q", out.String())
	}
	out.Reset()
	if code := Run(context.Background(), []string{"nope"}, &out, &errb); code != 2 {
		t.Fatalf("unknown code=%d", code)
	}
	if !strings.Contains(errb.String(), "unknown command") {
		t.Fatalf("unknown stderr=%q", errb.String())
	}
}

func TestDetectLegacyProfileAndEmitBoth(t *testing.T) {
	var out, errb bytes.Buffer
	code := Run(context.Background(), []string{"detect", "--repo-path", repoFixture(t, "go-repo")}, &out, &errb)
	if code != 0 {
		t.Fatalf("code=%d stderr=%s", code, errb.String())
	}
	if !strings.Contains(out.String(), "language=go") || !strings.Contains(out.String(), "default_branch=main") {
		t.Fatalf("legacy output=%q", out.String())
	}

	out.Reset()
	code = Run(context.Background(), []string{"detect", "--repo-path", repoFixture(t, "go-repo"), "--format", "profile-json"}, &out, &errb)
	if code != 0 {
		t.Fatalf("code=%d stderr=%s", code, errb.String())
	}
	var profile map[string]any
	if err := json.Unmarshal(out.Bytes(), &profile); err != nil {
		t.Fatalf("invalid profile JSON: %v\n%s", err, out.String())
	}
	if profile["schema_version"].(float64) != 1 {
		t.Fatalf("profile=%v", profile)
	}

	out.Reset()
	code = Run(context.Background(), []string{"detect", "--profile-json", repoFixture(t, "go-repo")}, &out, &errb)
	if code != 0 {
		t.Fatalf("code=%d stderr=%s", code, errb.String())
	}
	profile = map[string]any{}
	if err := json.Unmarshal(out.Bytes(), &profile); err != nil {
		t.Fatalf("invalid profile JSON (alias): %v\n%s", err, out.String())
	}
	if profile["schema_version"].(float64) != 1 {
		t.Fatalf("profile alias=%v", profile)
	}

	out.Reset()
	code = Run(context.Background(), []string{"detect", "--repo-path", repoFixture(t, "go-repo"), "--emit-both"}, &out, &errb)
	if code != 0 {
		t.Fatalf("code=%d stderr=%s", code, errb.String())
	}
	if !strings.Contains(out.String(), "profile_json<<EOF_") || !strings.Contains(out.String(), `"primary_language": "go"`) {
		t.Fatalf("emit-both output=%q", out.String())
	}
}

func TestDetectErrors(t *testing.T) {
	var out, errb bytes.Buffer
	if code := Run(context.Background(), []string{"detect"}, &out, &errb); code != 1 {
		t.Fatalf("missing repo code=%d", code)
	}
	if code := Run(context.Background(), []string{"detect", "--unknown"}, &out, &errb); code != 2 {
		t.Fatalf("flag error code=%d", code)
	}
	if code := Run(context.Background(), []string{"detect", "--repo-path", "/missing/nope"}, &out, &errb); code != 1 {
		t.Fatalf("bad repo code=%d", code)
	}
	if code := Run(context.Background(), []string{"detect", "--repo-path", repoFixture(t, "go-repo"), "--format", "bad"}, &out, &errb); code != 2 {
		t.Fatalf("bad format code=%d", code)
	}
	if code := Run(context.Background(), []string{"detect", repoFixture(t, "go-repo"), "go", "extra"}, &out, &errb); code != 2 {
		t.Fatalf("too many positional args code=%d", code)
	}
}

func TestDetectPositionalCompatibility(t *testing.T) {
	var out, errb bytes.Buffer
	code := Run(context.Background(), []string{"detect", repoFixture(t, "ambiguous"), "go"}, &out, &errb)
	if code != 0 {
		t.Fatalf("code=%d stderr=%s", code, errb.String())
	}
	if !strings.Contains(out.String(), "language=go") {
		t.Fatalf("positional override output=%q", out.String())
	}
}

func TestRenderFlagsAndPositionals(t *testing.T) {
	prependFakeGomplate(t)
	root := repoRoot(t)
	profile := `{
	  "schema_version": 1,
	  "target_repo": "serverkraken/example",
	  "default_branch": "main",
	  "current_version": "1.2.3",
	  "components": [{
	    "path": ".",
	    "primary_language": "go",
	    "release_please_type": "go",
	    "dockerfiles": [{"path": "Dockerfile", "image_name": "ghcr.io/$REPO/app", "release_eligible": true}],
	    "release_signals": {}
	  }]
	}`

	target := t.TempDir()
	profilePath := filepath.Join(target, "profile.json")
	writeCLIFile(t, profilePath, profile)
	var out, errb bytes.Buffer
	code := Run(context.Background(), []string{"render",
		"--catalog-path", root,
		"--target-path", target,
		"--profile-json-path", profilePath,
		"--pin-version", "v4",
		"--rendered-against", "v4.2.0",
	}, &out, &errb)
	if code != 0 {
		t.Fatalf("flags code=%d stderr=%s", code, errb.String())
	}
	release, err := os.ReadFile(filepath.Join(target, ".github/workflows/release.yml"))
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(release), "serverkraken/example") || strings.Contains(string(release), "$REPO") {
		t.Fatalf("release=%q", release)
	}
	assertRenderLock(t, target, "v4.2.0")

	t.Setenv("RENDERED_AGAINST", "v4.3.0")
	target = t.TempDir()
	profilePath = filepath.Join(target, "profile.json")
	writeCLIFile(t, profilePath, profile)
	out.Reset()
	errb.Reset()
	code = Run(context.Background(), []string{"render", root, target, profilePath, "v4"}, &out, &errb)
	if code != 0 {
		t.Fatalf("positional code=%d stderr=%s", code, errb.String())
	}
	assertRenderLock(t, target, "v4.3.0")
}

func TestRenderErrors(t *testing.T) {
	var out, errb bytes.Buffer
	if code := Run(context.Background(), []string{"render", "--unknown"}, &out, &errb); code != 2 {
		t.Fatalf("flag error code=%d", code)
	}
	if code := Run(context.Background(), []string{"render"}, &out, &errb); code != 1 {
		t.Fatalf("missing args code=%d", code)
	}
	if code := Run(context.Background(), []string{"render", t.TempDir(), t.TempDir(), "/profile.json", "v4", "extra"}, &out, &errb); code != 2 {
		t.Fatalf("too many positional args code=%d", code)
	}
}

func TestDriftNoLockAndBehind(t *testing.T) {
	target := t.TempDir()
	catalog := t.TempDir()
	var out, errb bytes.Buffer
	code := Run(context.Background(), []string{"drift", target, catalog}, &out, &errb)
	if code != 0 {
		t.Fatalf("no-lock code=%d stderr=%s", code, errb.String())
	}
	if strings.TrimSpace(out.String()) != "status=no-lock" {
		t.Fatalf("no-lock output=%q", out.String())
	}

	writeCLIFile(t, filepath.Join(target, ".github/workflows/ci.yml"), "ci\n")
	lock := domain.OnboardLock{
		SchemaVersion:  1,
		CatalogVersion: "v3",
		Files: map[string]string{
			".github/workflows/ci.yml": "sha256:e18cfafbb0c8b7909e7517cceecdddc4dec7b2d3483fd2813015eba3531a56ed",
		},
	}
	content, err := json.Marshal(lock)
	if err != nil {
		t.Fatal(err)
	}
	writeCLIFile(t, filepath.Join(target, ".github/onboard.lock.json"), string(content))

	out.Reset()
	errb.Reset()
	code = Run(context.Background(), []string{"drift", "--target-path", target, "--catalog-path", catalog, "--current-version", "v4"}, &out, &errb)
	if code != 0 {
		t.Fatalf("behind code=%d stderr=%s", code, errb.String())
	}
	got := out.String()
	if !strings.Contains(got, "lock_version=v3") || !strings.Contains(got, "current_version=v4") || !strings.Contains(got, "status=behind") {
		t.Fatalf("behind output=%q", got)
	}
}

func TestDriftErrors(t *testing.T) {
	var out, errb bytes.Buffer
	if code := Run(context.Background(), []string{"drift", "--unknown"}, &out, &errb); code != 2 {
		t.Fatalf("flag error code=%d", code)
	}
	if code := Run(context.Background(), []string{"drift", "/missing", t.TempDir()}, &out, &errb); code != 1 {
		t.Fatalf("missing target code=%d", code)
	}
	if code := Run(context.Background(), []string{"drift", t.TempDir(), t.TempDir(), "extra"}, &out, &errb); code != 2 {
		t.Fatalf("too many positional args code=%d", code)
	}
}

func TestDelimiterAvoidsPayloadCollision(t *testing.T) {
	payload := []byte("EOF_MTI_0")
	if got := delimiter(payload); strings.Contains(string(payload), got) {
		t.Fatalf("delimiter collides: %s", got)
	}
}

func writeCLIFile(t *testing.T, path, content string) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte(content), 0o644); err != nil {
		t.Fatal(err)
	}
}

func repoRoot(t *testing.T) string {
	t.Helper()
	root, err := filepath.Abs(filepath.Join("..", "..", ".."))
	if err != nil {
		t.Fatal(err)
	}
	return root
}

func prependFakeGomplate(t *testing.T) {
	t.Helper()
	dir := t.TempDir()
	path := filepath.Join(dir, "gomplate")
	script := `#!/usr/bin/env bash
set -euo pipefail
template=""
out=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -f)
      template="$2"
      shift 2
      ;;
    -o)
      out="$2"
      shift 2
      ;;
    *)
      shift
      ;;
  esac
done
mkdir -p "$(dirname "$out")"
case "$(basename "$template")" in
  release.yml.tmpl|prerelease.yml.tmpl|prerelease-on-push.yml.tmpl)
    printf 'image: ghcr.io/$REPO/app\n\n\n' > "$out"
    ;;
  *)
    printf '%s\n\n' "$(basename "$template")" > "$out"
    ;;
esac
`
	if err := os.WriteFile(path, []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PATH", dir+string(os.PathListSeparator)+os.Getenv("PATH"))
}

func assertRenderLock(t *testing.T, target, renderedAgainst string) {
	t.Helper()
	content, err := os.ReadFile(filepath.Join(target, ".github/onboard.lock.json"))
	if err != nil {
		t.Fatal(err)
	}
	var lock struct {
		CatalogVersion  string            `json:"catalog_version"`
		RenderedAgainst string            `json:"rendered_against"`
		Files           map[string]string `json:"files"`
	}
	if err := json.Unmarshal(content, &lock); err != nil {
		t.Fatal(err)
	}
	if lock.CatalogVersion != "v4" || lock.RenderedAgainst != renderedAgainst {
		t.Fatalf("lock=%+v", lock)
	}
	if lock.Files[".github/workflows/ci.yml"] == "" || lock.Files["release-please-config.json"] == "" {
		t.Fatalf("files=%v", lock.Files)
	}
}
