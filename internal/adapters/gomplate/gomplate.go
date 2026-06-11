package gomplate

import (
	"bytes"
	"context"
	"fmt"
	"os/exec"
)

type Adapter struct {
	Binary string
}

func (a Adapter) Execute(ctx context.Context, templatePath, outputPath, contextPath string) error {
	binary := a.Binary
	if binary == "" {
		binary = "gomplate"
	}
	cmd := exec.CommandContext(ctx, binary, "-c", ".="+contextPath, "-f", templatePath, "-o", outputPath)
	var stderr bytes.Buffer
	cmd.Stderr = &stderr
	if err := cmd.Run(); err != nil {
		return fmt.Errorf("%w: %s", err, stderr.String())
	}
	return nil
}
