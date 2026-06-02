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
