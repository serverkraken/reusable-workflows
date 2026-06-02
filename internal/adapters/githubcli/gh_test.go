package githubcli

import (
	"context"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
)

func TestClientUsesGHExecutable(t *testing.T) {
	withFakeGH(t, `#!/usr/bin/env bash
set -euo pipefail
if [[ "$1 $2 $3" == "api /repos/o/r -q" ]]; then
  echo trunk
elif [[ "$1 $2 $3" == "release list --repo" ]]; then
  echo v1.2.3
elif [[ "$1 $2 $3" == "api /repos/o/r/topics -q" ]]; then
  echo '["a","b"]'
else
  echo "unexpected: $*" >&2
  exit 9
fi
`)
	c := Client{}
	branch, err := c.DefaultBranch(context.Background(), "o/r")
	if err != nil || branch != "trunk" {
		t.Fatalf("branch=%q err=%v", branch, err)
	}
	version, err := c.LatestStableRelease(context.Background(), "o/r")
	if err != nil || version != "1.2.3" {
		t.Fatalf("version=%q err=%v", version, err)
	}
	topics, err := c.Topics(context.Background(), "o/r")
	if err != nil || !reflect.DeepEqual(topics, []string{"a", "b"}) {
		t.Fatalf("topics=%v err=%v", topics, err)
	}
}

func TestClientFallbacksAndErrors(t *testing.T) {
	withFakeGH(t, `#!/usr/bin/env bash
set -euo pipefail
if [[ "$1" == "api" && "$2" == "/repos/o/r" ]]; then
  echo "boom" >&2
  exit 7
elif [[ "$1" == "release" ]]; then
  echo null
elif [[ "$1" == "api" && "$2" == "/repos/o/r/topics" ]]; then
  echo "forbidden" >&2
  exit 8
fi
`)
	c := Client{}
	if _, err := c.DefaultBranch(context.Background(), "o/r"); err == nil || !strings.Contains(err.Error(), "boom") {
		t.Fatalf("expected branch error, got %v", err)
	}
	if version, err := c.LatestStableRelease(context.Background(), "o/r"); err != nil || version != "0.0.0" {
		t.Fatalf("version=%q err=%v", version, err)
	}
	if topics, err := c.Topics(context.Background(), "o/r"); err != nil || len(topics) != 0 {
		t.Fatalf("topics=%v err=%v", topics, err)
	}
}

func TestClientNullAndEmptyFallbacks(t *testing.T) {
	withFakeGH(t, `#!/usr/bin/env bash
set -euo pipefail
if [[ "$1" == "api" && "$2" == "/repos/o/r" ]]; then
  echo null
elif [[ "$1" == "release" ]]; then
  echo ''
elif [[ "$1" == "api" && "$2" == "/repos/o/r/topics" ]]; then
  echo null
fi
`)
	c := Client{}
	if branch, err := c.DefaultBranch(context.Background(), "o/r"); err != nil || branch != "main" {
		t.Fatalf("branch=%q err=%v", branch, err)
	}
	if version, err := c.LatestStableRelease(context.Background(), "o/r"); err != nil || version != "0.0.0" {
		t.Fatalf("version=%q err=%v", version, err)
	}
	if topics, err := c.Topics(context.Background(), "o/r"); err != nil || len(topics) != 0 {
		t.Fatalf("topics=%v err=%v", topics, err)
	}
}

func TestRunReportsCommandLookupFailure(t *testing.T) {
	t.Setenv("PATH", t.TempDir())
	if _, err := run(context.Background(), "gh", "--version"); err == nil {
		t.Fatal("expected command lookup failure")
	}
}

func TestClientRejectsInvalidTopicsJSON(t *testing.T) {
	withFakeGH(t, `#!/usr/bin/env bash
set -euo pipefail
if [[ "$1" == "api" && "$2" == "/repos/o/r/topics" ]]; then
  echo '{'
else
  echo main
fi
`)
	if _, err := (Client{}).Topics(context.Background(), "o/r"); err == nil {
		t.Fatal("expected invalid JSON error")
	}
}

func withFakeGH(t *testing.T, script string) {
	t.Helper()
	dir := t.TempDir()
	path := filepath.Join(dir, "gh")
	if err := os.WriteFile(path, []byte(script), 0755); err != nil {
		t.Fatal(err)
	}
	old := os.Getenv("PATH")
	t.Setenv("PATH", dir+string(os.PathListSeparator)+old)
}
