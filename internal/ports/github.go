package ports

import "context"

type GitHubMetadata interface {
	DefaultBranch(ctx context.Context, repo string) (string, error)
	LatestStableRelease(ctx context.Context, repo string) (string, error)
	// ReleaseTags lists the repo's stable release tags, newest first. A
	// monorepo carries both root tags (`v1.2.3`) and per-component tags
	// (`postfix-v1.2.3`); the caller decides which shape it wants.
	ReleaseTags(ctx context.Context, repo string) ([]string, error)
	Topics(ctx context.Context, repo string) ([]string, error)
}

type StaticGitHubMetadata struct {
	Branch  string
	Version string
	Names   []string
	Tags    []string
}

func (s StaticGitHubMetadata) DefaultBranch(context.Context, string) (string, error) {
	if s.Branch == "" {
		return "main", nil
	}
	return s.Branch, nil
}

func (s StaticGitHubMetadata) LatestStableRelease(context.Context, string) (string, error) {
	if s.Version == "" {
		return "0.0.0", nil
	}
	return s.Version, nil
}

func (s StaticGitHubMetadata) ReleaseTags(context.Context, string) ([]string, error) {
	return append([]string(nil), s.Tags...), nil
}

func (s StaticGitHubMetadata) Topics(context.Context, string) ([]string, error) {
	return append([]string(nil), s.Names...), nil
}
