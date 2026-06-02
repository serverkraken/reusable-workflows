package ports

import (
	"context"
	"encoding/json"

	"github.com/serverkraken/reusable-workflows/internal/domain"
)

type RepoDefaultsGitHub interface {
	RepoMetadata(ctx context.Context, repo string) (domain.RepoMetadata, error)
	BranchProtection(ctx context.Context, repo, branch string) (json.RawMessage, bool, error)
	UpdateBranchProtection(ctx context.Context, repo, branch string, payload []byte) error
	Topics(ctx context.Context, repo string) ([]string, error)
	ReplaceTopics(ctx context.Context, repo string, topics []string) error
	PatchRepository(ctx context.Context, repo string, payload []byte) error
}

type RepoDefaultsStore interface {
	ReadDefaults(catalogPath string) (domain.RepoDefaults, error)
	TargetExists(targetPath string) (bool, error)
	LockExists(targetPath string) (bool, error)
	UpdateLockDefaultsMarker(targetPath, marker string) error
}
