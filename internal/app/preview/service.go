package preview

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"sort"

	"github.com/serverkraken/reusable-workflows/internal/app/detect"
	"github.com/serverkraken/reusable-workflows/internal/app/render"
	"github.com/serverkraken/reusable-workflows/internal/domain"
)

type Detector interface {
	Detect(ctx context.Context, req detect.Request) (detect.Result, error)
}

type Renderer interface {
	Render(ctx context.Context, req render.Request) error
}

type Service struct {
	Detector Detector
	Renderer Renderer
}

type Request struct {
	CatalogPath      string
	RepoPath         string
	OutPath          string
	TargetRepo       string
	LanguageOverride string
	PinVersion       string
	RenderedAgainst  string
}

type Result struct {
	OutPath         string
	ProfileJSONPath string
	Legacy          domain.LegacyOutputs
	Profile         domain.Profile
	RenderedFiles   []string
}

func (s Service) Preview(ctx context.Context, req Request) (Result, error) {
	if err := validateRequest(req); err != nil {
		return Result{}, err
	}
	if s.Detector == nil {
		return Result{}, errors.New("detector not configured")
	}
	if s.Renderer == nil {
		return Result{}, errors.New("renderer not configured")
	}
	if sameCleanPath(req.RepoPath, req.OutPath) {
		return Result{}, errors.New("preview output must not be the source repo path")
	}
	if err := os.MkdirAll(req.OutPath, 0o755); err != nil {
		return Result{}, err
	}

	detected, err := s.Detector.Detect(ctx, detect.Request{
		RepoPath:         req.RepoPath,
		LanguageOverride: req.LanguageOverride,
		TargetRepo:       req.TargetRepo,
	})
	if err != nil {
		return Result{}, err
	}
	profile := detected.Profile
	if profile.TargetRepo == "" {
		profile.TargetRepo = filepath.Base(filepath.Clean(req.RepoPath))
	}

	profilePath := filepath.Join(req.OutPath, "profile.json")
	if err := writeProfile(profilePath, profile); err != nil {
		return Result{}, err
	}
	if err := s.Renderer.Render(ctx, render.Request{
		CatalogPath:     req.CatalogPath,
		TargetPath:      req.OutPath,
		ProfileJSONPath: profilePath,
		PinVersion:      req.PinVersion,
		RenderedAgainst: req.RenderedAgainst,
	}); err != nil {
		return Result{}, err
	}
	files, err := renderedFiles(req.OutPath)
	if err != nil {
		return Result{}, err
	}
	return Result{
		OutPath:         req.OutPath,
		ProfileJSONPath: profilePath,
		Legacy:          detected.Legacy,
		Profile:         profile,
		RenderedFiles:   files,
	}, nil
}

func validateRequest(req Request) error {
	if req.CatalogPath == "" || req.RepoPath == "" || req.OutPath == "" || req.PinVersion == "" {
		return errors.New("usage: sk-workflows preview --catalog-path <dir> --repo-path <dir> --out <dir> --pin-version vN")
	}
	return nil
}

func writeProfile(path string, profile domain.Profile) error {
	content, err := json.MarshalIndent(profile, "", "  ")
	if err != nil {
		return err
	}
	content = append(content, '\n')
	return os.WriteFile(path, content, 0o644)
}

func renderedFiles(outPath string) ([]string, error) {
	content, err := os.ReadFile(filepath.Join(outPath, ".github", "onboard.lock.json"))
	if err != nil {
		return nil, fmt.Errorf("preview lock not found: %w", err)
	}
	var lock domain.OnboardLock
	if err := json.Unmarshal(content, &lock); err != nil {
		return nil, fmt.Errorf("invalid preview lock: %w", err)
	}
	files := make([]string, 0, len(lock.Files))
	for file := range lock.Files {
		files = append(files, file)
	}
	sort.Strings(files)
	return files, nil
}

func sameCleanPath(a, b string) bool {
	absA, errA := filepath.Abs(a)
	absB, errB := filepath.Abs(b)
	if errA != nil || errB != nil {
		return filepath.Clean(a) == filepath.Clean(b)
	}
	return filepath.Clean(absA) == filepath.Clean(absB)
}
