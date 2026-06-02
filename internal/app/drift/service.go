package drift

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"

	"github.com/serverkraken/reusable-workflows/internal/domain"
	"github.com/serverkraken/reusable-workflows/internal/ports"
)

const (
	lockPath         = ".github/onboard.lock.json"
	manifestPath     = ".release-please-manifest.json"
	renderErrorLimit = 80
)

type Service struct {
	Detector ports.ProfileDetector
	Renderer ports.TemplateRenderer
	Git      ports.GitRemote
	TempDir  func() (string, error)
}

type Request struct {
	TargetPath     string
	CatalogPath    string
	CurrentVersion string
}

func (s Service) Drift(ctx context.Context, req Request) (domain.DriftResult, error) {
	if req.TargetPath == "" || req.CatalogPath == "" || !isDir(req.TargetPath) || !isDir(req.CatalogPath) {
		return domain.DriftResult{}, errors.New("usage: sk-workflows drift <target-path> <catalog-path>")
	}
	lockFile := filepath.Join(req.TargetPath, lockPath)
	if _, err := os.Stat(lockFile); errors.Is(err, os.ErrNotExist) {
		return domain.DriftResult{Status: domain.DriftNoLock}, nil
	} else if err != nil {
		return domain.DriftResult{}, err
	}

	lock, err := readLock(lockFile)
	if err != nil {
		return domain.DriftResult{}, err
	}
	res := domain.DriftResult{
		LockVersion:    lock.CatalogVersion,
		CurrentVersion: req.CurrentVersion,
	}

	behind := req.CurrentVersion != "" && lock.CatalogVersion != req.CurrentVersion
	modified, err := modifiedFiles(req.TargetPath, lock)
	if err != nil {
		return domain.DriftResult{}, err
	}
	res.Modified = modified
	switch {
	case behind && len(modified) > 0:
		res.Status = domain.DriftBehindModified
	case behind:
		res.Status = domain.DriftBehind
	case len(modified) > 0:
		res.Status = domain.DriftModified
	default:
		res.Status = domain.DriftClean
	}

	if res.Status == domain.DriftClean {
		s.renderCompare(ctx, req, lock, &res)
	}
	return res, nil
}

func (s Service) renderCompare(ctx context.Context, req Request, lock domain.OnboardLock, res *domain.DriftResult) {
	if s.Detector == nil {
		res.RenderError = renderError("detect-failed", errors.New("profile detector not configured"))
		return
	}
	if s.Renderer == nil {
		res.RenderError = renderError("render-failed", errors.New("template renderer not configured"))
		return
	}
	tempDir := os.MkdirTemp
	if s.TempDir != nil {
		tempDir = func(_ string, _ string) (string, error) { return s.TempDir() }
	}
	scratch, err := tempDir("", "sk-workflows-drift-*")
	if err != nil {
		res.RenderError = renderError("render-failed", err)
		return
	}
	defer os.RemoveAll(scratch)

	targetRepo := ""
	if s.Git != nil {
		if origin, err := s.Git.OriginURL(ctx, req.TargetPath); err == nil {
			targetRepo = NormalizeGitHubOrigin(origin)
		}
	}
	profile, err := s.Detector.ProfileJSON(ctx, req.CatalogPath, req.TargetPath, targetRepo)
	if err != nil {
		res.RenderError = renderError("detect-failed", err)
		return
	}
	profilePath := filepath.Join(scratch, "profile.json")
	if err := os.WriteFile(profilePath, profile, 0o600); err != nil {
		res.RenderError = renderError("detect-failed", err)
		return
	}
	renderedPath := filepath.Join(scratch, "rendered")
	if err := s.Renderer.Render(ctx, req.CatalogPath, renderedPath, profilePath, req.CurrentVersion); err != nil {
		res.RenderError = renderError("render-failed", err)
		return
	}

	stale, err := staleFiles(req.TargetPath, renderedPath, lock)
	if err != nil {
		res.RenderError = renderError("render-failed", err)
		return
	}
	if len(stale) > 0 {
		res.Status = domain.DriftStaleLock
		res.Modified = stale
	}
}

func readLock(path string) (domain.OnboardLock, error) {
	content, err := os.ReadFile(path)
	if err != nil {
		return domain.OnboardLock{}, err
	}
	var lock domain.OnboardLock
	if err := json.Unmarshal(content, &lock); err != nil {
		return domain.OnboardLock{}, err
	}
	if lock.Files == nil {
		lock.Files = map[string]string{}
	}
	return lock, nil
}

func modifiedFiles(targetPath string, lock domain.OnboardLock) ([]string, error) {
	var out []string
	for _, p := range sortedKeys(lock.Files) {
		if p == manifestPath {
			continue
		}
		full := filepath.Join(targetPath, filepath.FromSlash(p))
		if _, err := os.Stat(full); errors.Is(err, os.ErrNotExist) {
			out = append(out, p+"(missing)")
			continue
		} else if err != nil {
			return nil, err
		}
		actual, err := sha256File(full)
		if err != nil {
			return nil, err
		}
		if lock.Files[p] != "sha256:"+actual {
			out = append(out, p)
		}
	}
	return out, nil
}

func staleFiles(targetPath, renderedPath string, lock domain.OnboardLock) ([]string, error) {
	var out []string
	for _, p := range sortedKeys(lock.Files) {
		if p == lockPath || p == manifestPath {
			continue
		}
		rendered := filepath.Join(renderedPath, filepath.FromSlash(p))
		if _, err := os.Stat(rendered); errors.Is(err, os.ErrNotExist) {
			continue
		} else if err != nil {
			return nil, err
		}
		same, err := sameBytes(filepath.Join(targetPath, filepath.FromSlash(p)), rendered)
		if err != nil {
			return nil, err
		}
		if !same {
			out = append(out, p)
		}
	}
	return out, nil
}

func sameBytes(a, b string) (bool, error) {
	left, err := os.ReadFile(a)
	if err != nil {
		return false, err
	}
	right, err := os.ReadFile(b)
	if err != nil {
		return false, err
	}
	return string(left) == string(right), nil
}

func sha256File(path string) (string, error) {
	content, err := os.ReadFile(path)
	if err != nil {
		return "", err
	}
	sum := sha256.Sum256(content)
	return hex.EncodeToString(sum[:]), nil
}

func sortedKeys(values map[string]string) []string {
	keys := make([]string, 0, len(values))
	for key := range values {
		keys = append(keys, key)
	}
	sort.Strings(keys)
	return keys
}

func renderError(phase string, err error) string {
	msg := strings.Join(strings.Fields(err.Error()), " ")
	if len(msg) > renderErrorLimit {
		msg = msg[:renderErrorLimit]
	}
	return fmt.Sprintf("%s:%s", phase, msg)
}

func isDir(path string) bool {
	info, err := os.Stat(path)
	return err == nil && info.IsDir()
}

func NormalizeGitHubOrigin(origin string) string {
	origin = strings.TrimSpace(origin)
	if origin == "" {
		return ""
	}
	if i := strings.Index(origin, "github.com:"); i >= 0 {
		origin = origin[i+len("github.com:"):]
	} else if i := strings.Index(origin, "github.com/"); i >= 0 {
		origin = origin[i+len("github.com/"):]
	} else {
		return ""
	}
	origin = strings.TrimSuffix(origin, ".git")
	if strings.Contains(origin, "/") {
		return origin
	}
	return ""
}
