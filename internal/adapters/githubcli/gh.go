package githubcli

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os/exec"
	"strings"

	"github.com/serverkraken/reusable-workflows/internal/domain"
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

func (Client) RepoMetadata(ctx context.Context, repo string) (domain.RepoMetadata, error) {
	out, err := api(ctx, "GET", "/repos/"+repo, nil)
	if err != nil {
		return domain.RepoMetadata{}, err
	}
	var meta domain.RepoMetadata
	if err := json.Unmarshal(out, &meta); err != nil {
		return domain.RepoMetadata{}, err
	}
	if meta.DefaultBranch == "" || meta.DefaultBranch == "null" {
		meta.DefaultBranch = "main"
	}
	return meta, nil
}

func (Client) BranchProtection(ctx context.Context, repo, branch string) (json.RawMessage, bool, error) {
	out, err := api(ctx, "GET", fmt.Sprintf("/repos/%s/branches/%s/protection", repo, branch), nil)
	if err != nil {
		return nil, true, nil
	}
	return json.RawMessage(bytes.TrimSpace(out)), false, nil
}

func (Client) UpdateBranchProtection(ctx context.Context, repo, branch string, payload []byte) error {
	_, err := api(ctx, "PUT", fmt.Sprintf("/repos/%s/branches/%s/protection", repo, branch), payload)
	return err
}

func (Client) ReplaceTopics(ctx context.Context, repo string, topics []string) error {
	payload, err := json.Marshal(struct {
		Names []string `json:"names"`
	}{Names: topics})
	if err != nil {
		return err
	}
	_, err = api(ctx, "PUT", "/repos/"+repo+"/topics", payload)
	return err
}

func (Client) PatchRepository(ctx context.Context, repo string, payload []byte) error {
	_, err := api(ctx, "PATCH", "/repos/"+repo, payload)
	return err
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

func api(ctx context.Context, method, endpoint string, input []byte) ([]byte, error) {
	args := []string{"api"}
	if method != "" && method != "GET" {
		args = append(args, "-X", method)
	}
	args = append(args, endpoint)
	if input != nil {
		args = append(args, "--input", "-")
	}
	cmd := exec.CommandContext(ctx, "gh", args...)
	if input != nil {
		cmd.Stdin = bytes.NewReader(input)
	}
	var stdout, stderr bytes.Buffer
	cmd.Stdout = &stdout
	cmd.Stderr = &stderr
	if err := cmd.Run(); err != nil {
		msg := strings.TrimSpace(stderr.String())
		if msg == "" {
			msg = strings.TrimSpace(stdout.String())
		}
		if msg == "" {
			msg = err.Error()
		}
		return stdout.Bytes(), errors.New(msg)
	}
	return stdout.Bytes(), nil
}
