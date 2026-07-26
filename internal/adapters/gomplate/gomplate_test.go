package gomplate

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestExecuteInvokesGomplate(t *testing.T) {
	bin := fakeGomplate(t, 0)
	out := filepath.Join(t.TempDir(), "out.yml")
	err := (Adapter{Binary: bin}).Execute(context.Background(), "/template.yml.tmpl", out, "/ctx.json")
	if err != nil {
		t.Fatal(err)
	}
	got, err := os.ReadFile(out)
	if err != nil {
		t.Fatal(err)
	}
	want := "-c .=/ctx.json -f /template.yml.tmpl -o " + out + "\n"
	if string(got) != want {
		t.Fatalf("output=%q want %q", got, want)
	}
}

func TestExecuteIncludesStderrOnFailure(t *testing.T) {
	bin := fakeGomplate(t, 7)
	err := (Adapter{Binary: bin}).Execute(context.Background(), "/template", "/out", "/ctx")
	if err == nil || !strings.Contains(err.Error(), "gomplate failed") {
		t.Fatalf("err=%v", err)
	}
}

func TestExecuteUsesDefaultBinaryFromPath(t *testing.T) {
	dir := t.TempDir()
	bin := fakeGomplateAt(t, filepath.Join(dir, "gomplate"), 0)
	t.Setenv("PATH", filepath.Dir(bin)+string(os.PathListSeparator)+os.Getenv("PATH"))
	out := filepath.Join(t.TempDir(), "out.yml")
	if err := (Adapter{}).Execute(context.Background(), "/template", out, "/ctx"); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(out); err != nil {
		t.Fatal(err)
	}
}

func fakeGomplate(t *testing.T, exitCode int) string {
	t.Helper()
	return fakeGomplateAt(t, filepath.Join(t.TempDir(), "gomplate"), exitCode)
}

func fakeGomplateAt(t *testing.T, path string, exitCode int) string {
	t.Helper()
	failure := ""
	if exitCode != 0 {
		failure = fmt.Sprintf("echo \"gomplate failed\" >&2\nexit %d\n", exitCode)
	}
	script := `#!/usr/bin/env bash
set -euo pipefail
` + failure + `
out=""
for ((i=1; i<=$#; i++)); do
  if [[ "${!i}" == "-o" ]]; then
    j=$((i+1))
    out="${!j}"
  fi
done
mkdir -p "$(dirname "$out")"
printf '%s\n' "$*" > "$out"
`
	if err := os.WriteFile(path, []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}
	return path
}
