package gitcli

import (
	"context"
	"os/exec"
	"strings"
	"testing"
)

func TestOriginURLRequiresGitRepo(t *testing.T) {
	if _, err := exec.LookPath("git"); err != nil {
		t.Skip("git not installed")
	}
	_, err := (Client{}).OriginURL(context.Background(), t.TempDir())
	if err == nil {
		t.Fatal("expected git config error outside a git repository")
	}
	if !strings.Contains(err.Error(), "exit status") {
		t.Fatalf("err=%v", err)
	}
}

func TestOriginURLReadsConfiguredRemote(t *testing.T) {
	if _, err := exec.LookPath("git"); err != nil {
		t.Skip("git not installed")
	}
	repo := t.TempDir()
	runGit(t, repo, "init")
	runGit(t, repo, "remote", "add", "origin", "git@github.com:serverkraken/example.git")
	got, err := (Client{}).OriginURL(context.Background(), repo)
	if err != nil {
		t.Fatal(err)
	}
	if got != "git@github.com:serverkraken/example.git" {
		t.Fatalf("origin=%q", got)
	}
}

func runGit(t *testing.T, repo string, args ...string) {
	t.Helper()
	cmd := exec.Command("git", args...)
	cmd.Dir = repo
	if out, err := cmd.CombinedOutput(); err != nil {
		t.Fatalf("git %v: %v\n%s", args, err, out)
	}
}
