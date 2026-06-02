package ports

import "context"

type TemplateExecutor interface {
	Execute(ctx context.Context, templatePath, outputPath, contextPath string) error
}
