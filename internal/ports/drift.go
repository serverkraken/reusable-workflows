package ports

import "context"

type ProfileDetector interface {
	ProfileJSON(ctx context.Context, catalogPath, repoPath, targetRepo string) ([]byte, error)
}

type TemplateRenderer interface {
	Render(ctx context.Context, catalogPath, targetPath, profilePath, pinVersion string) error
}

type GitRemote interface {
	OriginURL(ctx context.Context, repoPath string) (string, error)
}
