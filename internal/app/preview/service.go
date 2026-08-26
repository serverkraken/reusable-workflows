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
	// Gleichheit allein reicht nicht (Audit B-7): der Riegel prueft seit
	// Einfuehrung des Befehls (#181) nur, ob --out GENAU der Quellpfad ist. Ein
	// UNTERVERZEICHNIS lief durch und legte acht Dateien im untersuchten Repo
	// ab.
	//
	// Schwerer wiegt der zweite Fall, der dabei auffiel: --out auf den KATALOG.
	// preview schreibt .github/workflows/release.yml, release-please-config.json
	// und .release-please-manifest.json - alle drei gibt es in diesem Repo
	// ebenfalls. Ein `preview --out .` im Katalog haette dessen eigene
	// Release-Maschinerie mit der eines Adopters ueberschrieben.
	//
	// Beides ist dieselbe Regel: nicht in einen Baum schreiben, aus dem gelesen
	// wird.
	for _, src := range []struct{ path, what string }{
		{req.RepoPath, "source repo"},
		{req.CatalogPath, "catalog"},
	} {
		if src.path == "" {
			continue
		}
		if err := outsideOf(req.OutPath, src.path, src.what); err != nil {
			return Result{}, err
		}
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

// outsideOf weist ab, wenn out UNTERHALB von src landet.
//
// Symlinks werden aufgeloest, sonst genuegte ein Link auf den Katalog, um am
// Riegel vorbeizukommen. out existiert beim ersten Lauf noch nicht - geprueft
// wird deshalb der tiefste bereits existierende Vorfahre, dieselbe Bauart wie
// render.ensureInsideTarget.
func outsideOf(out, src, what string) error {
	root, err := filepath.Abs(src)
	if err != nil {
		return err
	}
	if resolved, err := filepath.EvalSymlinks(root); err == nil {
		root = resolved
	}
	probe, err := filepath.Abs(out)
	if err != nil {
		return err
	}
	for {
		if _, err := os.Lstat(probe); err == nil {
			break
		}
		parent := filepath.Dir(probe)
		if parent == probe {
			break
		}
		probe = parent
	}
	if resolved, err := filepath.EvalSymlinks(probe); err == nil {
		probe = resolved
	}
	rel, err := filepath.Rel(root, probe)
	if err != nil {
		return nil
	}
	if rel == ".." || filepath.IsAbs(rel) || len(rel) > 2 && rel[:3] == ".."+string(filepath.Separator) {
		return nil
	}
	return fmt.Errorf("preview output must not be inside the %s (%s resolves under %s); "+
		"render into a directory outside it, e.g. \"$(mktemp -d)\"", what, out, root)
}

func sameCleanPath(a, b string) bool {
	absA, errA := filepath.Abs(a)
	absB, errB := filepath.Abs(b)
	if errA != nil || errB != nil {
		return filepath.Clean(a) == filepath.Clean(b)
	}
	return filepath.Clean(absA) == filepath.Clean(absB)
}
