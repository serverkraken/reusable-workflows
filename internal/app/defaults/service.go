package defaults

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"reflect"
	"strings"
	"time"

	"github.com/serverkraken/reusable-workflows/internal/domain"
	"github.com/serverkraken/reusable-workflows/internal/ports"
)

type Request struct {
	CatalogPath string
	Repo        string
	TargetPath  string
	PrevMarker  string
	DryRun      bool
}

type Service struct {
	GitHub ports.RepoDefaultsGitHub
	Store  ports.RepoDefaultsStore
	Now    func() time.Time
}

func (s Service) Apply(ctx context.Context, req Request) (domain.RepoDefaultsResult, error) {
	if err := s.validate(req); err != nil {
		return domain.RepoDefaultsResult{}, err
	}
	cfg, err := s.Store.ReadDefaults(req.CatalogPath)
	if err != nil {
		return domain.RepoDefaultsResult{}, err
	}
	meta, err := s.GitHub.RepoMetadata(ctx, req.Repo)
	if err != nil {
		return domain.RepoDefaultsResult{}, fmt.Errorf("failed to fetch /repos/%s: %w", req.Repo, err)
	}
	if meta.DefaultBranch == "" {
		meta.DefaultBranch = "main"
	}

	res := domain.RepoDefaultsResult{
		DefaultsApplied: !req.DryRun,
		Tier2Applied:    !req.DryRun && req.PrevMarker == "",
	}
	if err := s.applyBranchProtection(ctx, req, cfg, meta, &res); err != nil {
		return domain.RepoDefaultsResult{}, err
	}
	if err := s.applyDeleteBranch(ctx, req, cfg, meta, &res); err != nil {
		return domain.RepoDefaultsResult{}, err
	}
	if err := s.applyTopics(ctx, req, cfg, &res); err != nil {
		return domain.RepoDefaultsResult{}, err
	}
	if req.PrevMarker == "" {
		if err := s.applyTier2(ctx, req, cfg, meta, &res); err != nil {
			return domain.RepoDefaultsResult{}, err
		}
	}
	if err := s.mutateLock(req, &res); err != nil {
		return domain.RepoDefaultsResult{}, err
	}
	return res, nil
}

func (s Service) validate(req Request) error {
	if req.Repo == "" {
		return errors.New("usage: sk-workflows apply-defaults --repo <owner/repo> --target-path <dir>")
	}
	if req.TargetPath == "" {
		return errors.New("usage: sk-workflows apply-defaults --repo <owner/repo> --target-path <dir>")
	}
	if req.CatalogPath == "" {
		return errors.New("catalog path is required")
	}
	if s.GitHub == nil {
		return errors.New("repo-defaults GitHub port not configured")
	}
	if s.Store == nil {
		return errors.New("repo-defaults store port not configured")
	}
	ok, err := s.Store.TargetExists(req.TargetPath)
	if err != nil {
		return err
	}
	if !ok {
		return fmt.Errorf("target path does not exist: %s", req.TargetPath)
	}
	return nil
}

func (s Service) applyBranchProtection(ctx context.Context, req Request, cfg domain.RepoDefaults, meta domain.RepoMetadata, res *domain.RepoDefaultsResult) error {
	current, missing, err := s.GitHub.BranchProtection(ctx, req.Repo, meta.DefaultBranch)
	if err != nil {
		missing = true
		current = nil
	}
	diff, err := domain.DiffBranchProtection(current, missing, cfg.BranchProtection)
	if err != nil {
		return err
	}
	if diff == "" {
		return nil
	}
	addCategory(req.DryRun, res, "branch_protection")
	payload, err := domain.BranchProtectionPayload(cfg.BranchProtection)
	if err != nil {
		return err
	}
	if req.DryRun {
		res.Notices = append(res.Notices, "::notice::dry-run: would PUT branch protection ("+diff+")")
		return nil
	}
	if err := s.GitHub.UpdateBranchProtection(ctx, req.Repo, meta.DefaultBranch, payload); err != nil {
		return err
	}
	return nil
}

func (s Service) applyDeleteBranch(ctx context.Context, req Request, cfg domain.RepoDefaults, meta domain.RepoMetadata, res *domain.RepoDefaultsResult) error {
	target := cfg.MergeHygiene.DeleteBranchOnMerge
	if meta.DeleteBranchOnMerge == target {
		return nil
	}
	addCategory(req.DryRun, res, "delete_branch_on_merge")
	payload := domain.DeleteBranchPatch(target)
	if req.DryRun {
		res.Notices = append(res.Notices, fmt.Sprintf("::notice::dry-run: would PATCH delete_branch_on_merge=%t", target))
		return nil
	}
	return s.GitHub.PatchRepository(ctx, req.Repo, payload)
}

func (s Service) applyTopics(ctx context.Context, req Request, cfg domain.RepoDefaults, res *domain.RepoDefaultsResult) error {
	current, err := s.GitHub.Topics(ctx, req.Repo)
	if err != nil {
		current = nil
	}
	next := domain.ComputeTopicsUnion(current, cfg.TopicsAdditive)
	if reflect.DeepEqual(current, next) {
		return nil
	}
	addCategory(req.DryRun, res, "topics")
	if req.DryRun {
		payload, err := json.Marshal(next)
		if err != nil {
			return err
		}
		res.Notices = append(res.Notices, "::notice::dry-run: would PUT topics="+string(payload))
		return nil
	}
	return s.GitHub.ReplaceTopics(ctx, req.Repo, next)
}

func (s Service) applyTier2(ctx context.Context, req Request, cfg domain.RepoDefaults, meta domain.RepoMetadata, res *domain.RepoDefaultsResult) error {
	mergeDiff := domain.DiffMergeHygiene(meta, cfg.MergeHygiene)
	settingsDiff := domain.DiffRepoSettings(meta, cfg.RepoSettings)
	if len(mergeDiff) == 0 && len(settingsDiff) == 0 {
		return nil
	}
	payload, err := domain.MergeAndRepoSettingsPatch(cfg.MergeHygiene, cfg.RepoSettings)
	if err != nil {
		return err
	}
	if req.DryRun {
		if len(mergeDiff) > 0 {
			addCategory(true, res, "merge_hygiene")
		}
		if len(settingsDiff) > 0 {
			addCategory(true, res, "repo_settings")
		}
		res.Notices = append(res.Notices, fmt.Sprintf("::notice::dry-run: would PATCH /repos/%s with %s", req.Repo, payload))
		return nil
	}
	if err := s.GitHub.PatchRepository(ctx, req.Repo, payload); err != nil {
		return err
	}
	if len(mergeDiff) > 0 {
		addCategory(false, res, "merge_hygiene")
	}
	if len(settingsDiff) > 0 {
		addCategory(false, res, "repo_settings")
	}
	return nil
}

func (s Service) mutateLock(req Request, res *domain.RepoDefaultsResult) error {
	exists, err := s.Store.LockExists(req.TargetPath)
	if err != nil {
		return err
	}
	if !exists {
		return nil
	}
	marker := req.PrevMarker
	if marker == "" {
		marker = now(s.Now)
	}
	if req.DryRun {
		res.Notices = append(res.Notices, "::notice::dry-run: would mutate lock - schema_version=2, defaults_applied_at="+marker)
		return nil
	}
	return s.Store.UpdateLockDefaultsMarker(req.TargetPath, marker)
}

func addCategory(dryRun bool, res *domain.RepoDefaultsResult, category string) {
	if dryRun {
		res.WouldChange = append(res.WouldChange, category)
	} else {
		res.Modified = append(res.Modified, category)
	}
}

func now(clock func() time.Time) string {
	if clock == nil {
		return time.Now().UTC().Format(time.RFC3339)
	}
	return clock().UTC().Format(time.RFC3339)
}

func CategoriesCSV(categories []string) string {
	return strings.Join(categories, ",")
}
