package cli

import (
	"bytes"
	"context"
	"encoding/json"
	"path/filepath"
	"strings"
	"testing"
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

func TestDelimiterAvoidsPayloadCollision(t *testing.T) {
	payload := []byte("EOF_MTI_0")
	if got := delimiter(payload); strings.Contains(string(payload), got) {
		t.Fatalf("delimiter collides: %s", got)
	}
}
