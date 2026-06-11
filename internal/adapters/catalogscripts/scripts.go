package catalogscripts

import (
	"bytes"
	"context"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
)

type Adapter struct{}

func (Adapter) ProfileJSON(ctx context.Context, catalogPath, repoPath, targetRepo string) ([]byte, error) {
	cmd := exec.CommandContext(ctx, filepath.Join(catalogPath, "scripts", "onboard-detect.sh"), "--profile-json", repoPath)
	cmd.Env = os.Environ()
	if targetRepo != "" {
		cmd.Env = append(cmd.Env, "TARGET_REPO="+targetRepo)
	}
	var out, stderr bytes.Buffer
	cmd.Stdout = &out
	cmd.Stderr = &stderr
	if err := cmd.Run(); err != nil {
		return nil, fmt.Errorf("%w: %s", err, stderr.String())
	}
	return out.Bytes(), nil
}

func (Adapter) Render(ctx context.Context, catalogPath, targetPath, profilePath, pinVersion string) error {
	cmd := exec.CommandContext(ctx, filepath.Join(catalogPath, "scripts", "onboard-render.sh"), catalogPath, targetPath, profilePath, pinVersion)
	var stderr bytes.Buffer
	cmd.Stdout = nil
	cmd.Stderr = &stderr
	if err := cmd.Run(); err != nil {
		return fmt.Errorf("%w: %s", err, stderr.String())
	}
	return nil
}
