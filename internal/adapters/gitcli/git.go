package gitcli

import (
	"bytes"
	"context"
	"fmt"
	"os/exec"
)

type Client struct{}

func (Client) OriginURL(ctx context.Context, repoPath string) (string, error) {
	cmd := exec.CommandContext(ctx, "git", "-C", repoPath, "config", "--get", "remote.origin.url")
	var out, stderr bytes.Buffer
	cmd.Stdout = &out
	cmd.Stderr = &stderr
	if err := cmd.Run(); err != nil {
		return "", fmt.Errorf("%w: %s", err, stderr.String())
	}
	return string(bytes.TrimSpace(out.Bytes())), nil
}
