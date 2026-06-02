package githubcli

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"os/exec"
	"strings"
)

type Client struct{}

func (Client) DefaultBranch(ctx context.Context, repo string) (string, error) {
	out, err := run(ctx, "gh", "api", "/repos/"+repo, "-q", ".default_branch")
	if err != nil {
		return "", err
	}
	branch := strings.TrimSpace(string(out))
	if branch == "" || branch == "null" {
		return "main", nil
	}
	return branch, nil
}

func (Client) LatestStableRelease(ctx context.Context, repo string) (string, error) {
	out, err := run(ctx, "gh", "release", "list", "--repo", repo, "--exclude-pre-releases", "--limit", "1", "--json", "tagName", "-q", ".[0].tagName")
	if err != nil {
		return "0.0.0", nil
	}
	tag := strings.TrimSpace(string(out))
	tag = strings.TrimPrefix(tag, "v")
	if tag == "" || tag == "null" {
		return "0.0.0", nil
	}
	return tag, nil
}

func (Client) Topics(ctx context.Context, repo string) ([]string, error) {
	out, err := run(ctx, "gh", "api", "/repos/"+repo+"/topics", "-q", ".names")
	if err != nil {
		return nil, nil
	}
	raw := strings.TrimSpace(string(out))
	if raw == "" || raw == "null" {
		return nil, nil
	}
	var topics []string
	if err := json.Unmarshal([]byte(raw), &topics); err != nil {
		return nil, err
	}
	return topics, nil
}

func run(ctx context.Context, name string, args ...string) ([]byte, error) {
	cmd := exec.CommandContext(ctx, name, args...)
	var stderr bytes.Buffer
	cmd.Stderr = &stderr
	out, err := cmd.Output()
	if err != nil {
		msg := strings.TrimSpace(stderr.String())
		if msg == "" {
			msg = err.Error()
		}
		return nil, errors.New(msg)
	}
	return out, nil
}
