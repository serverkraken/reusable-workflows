package catalogscripts

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestProfileJSONRunsDetectScriptWithTargetRepo(t *testing.T) {
	catalog := fakeCatalog(t)
	got, err := (Adapter{}).ProfileJSON(context.Background(), catalog, "/repo", "owner/name")
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(got), `"target_repo":"owner/name"`) {
		t.Fatalf("profile=%s", got)
	}
}

func TestRenderRunsRenderScript(t *testing.T) {
	catalog := fakeCatalog(t)
	out := t.TempDir()
	if err := (Adapter{}).Render(context.Background(), catalog, out, "/profile.json", "v4"); err != nil {
		t.Fatal(err)
	}
	content, err := os.ReadFile(filepath.Join(out, "rendered.txt"))
	if err != nil {
		t.Fatal(err)
	}
	if string(content) != "v4 /profile.json\n" {
		t.Fatalf("rendered=%q", content)
	}
}

func TestScriptErrorsIncludeStderr(t *testing.T) {
	catalog := fakeCatalog(t)
	if _, err := (Adapter{}).ProfileJSON(context.Background(), catalog, "fail", ""); err == nil || !strings.Contains(err.Error(), "detect failed") {
		t.Fatalf("detect err=%v", err)
	}
	if err := (Adapter{}).Render(context.Background(), catalog, "fail", "/profile.json", "v4"); err == nil || !strings.Contains(err.Error(), "render failed") {
		t.Fatalf("render err=%v", err)
	}
}

func fakeCatalog(t *testing.T) string {
	t.Helper()
	root := t.TempDir()
	scripts := filepath.Join(root, "scripts")
	if err := os.MkdirAll(scripts, 0o755); err != nil {
		t.Fatal(err)
	}
	writeExecutable(t, filepath.Join(scripts, "onboard-detect.sh"), `#!/usr/bin/env bash
set -euo pipefail
if [[ "${2:-}" == "fail" ]]; then
  echo "detect failed" >&2
  exit 3
fi
printf '{"target_repo":"%s"}\n' "${TARGET_REPO:-}"
`)
	writeExecutable(t, filepath.Join(scripts, "onboard-render.sh"), `#!/usr/bin/env bash
set -euo pipefail
target="$2"
profile="$3"
pin="$4"
if [[ "$target" == "fail" ]]; then
  echo "render failed" >&2
  exit 4
fi
mkdir -p "$target"
printf '%s %s\n' "$pin" "$profile" > "$target/rendered.txt"
`)
	return root
}

func writeExecutable(t *testing.T, path, content string) {
	t.Helper()
	if err := os.WriteFile(path, []byte(content), 0o755); err != nil {
		t.Fatal(err)
	}
}
