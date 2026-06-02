package render

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/serverkraken/reusable-workflows/internal/domain"
	"github.com/serverkraken/reusable-workflows/internal/ports"
)

const (
	templateRoot = "docs/adopter-templates"
	lockPath     = ".github/onboard.lock.json"
)

type Service struct {
	Templates ports.TemplateExecutor
	Now       func() time.Time
	TempDir   func() (string, error)
}

type Request struct {
	CatalogPath     string
	TargetPath      string
	ProfileJSONPath string
	PinVersion      string
	RenderedAgainst string
}

type renderFile struct {
	Template string
	Output   string
}

func (s Service) Render(ctx context.Context, req Request) error {
	if err := validateRequest(req); err != nil {
		return err
	}
	if s.Templates == nil {
		return errors.New("template executor not configured")
	}
	rawProfile, profile, err := readProfile(req.ProfileJSONPath)
	if err != nil {
		return err
	}

	tempDir := os.MkdirTemp
	if s.TempDir != nil {
		tempDir = func(_, _ string) (string, error) { return s.TempDir() }
	}
	scratch, err := tempDir("", "sk-workflows-render-*")
	if err != nil {
		return err
	}
	defer os.RemoveAll(scratch)

	contextPath := filepath.Join(scratch, "ctx.json")
	if err := writeContext(contextPath, req.PinVersion, rawProfile); err != nil {
		return err
	}

	files := plannedFiles(profile)
	if err := os.MkdirAll(filepath.Join(req.TargetPath, ".github", "workflows"), 0o755); err != nil {
		return err
	}
	for _, file := range files {
		if err := s.renderOne(ctx, req, file, contextPath); err != nil {
			return err
		}
	}
	if err := substituteRepo(req.TargetPath, profile); err != nil {
		return err
	}
	renderedAgainst := req.RenderedAgainst
	if renderedAgainst == "" {
		renderedAgainst = req.PinVersion
	}
	return writeLock(req.TargetPath, req.PinVersion, renderedAgainst, renderedAt(s.Now), lockPaths(profile))
}

func validateRequest(req Request) error {
	if req.CatalogPath == "" || req.TargetPath == "" || req.ProfileJSONPath == "" || req.PinVersion == "" {
		return errors.New("usage: sk-workflows render <catalog-path> <target-path> <profile-json-path> <pin-version>")
	}
	return nil
}

func readProfile(path string) ([]byte, domain.Profile, error) {
	content, err := os.ReadFile(path)
	if err != nil {
		return nil, domain.Profile{}, fmt.Errorf("profile not found: %s", path)
	}
	var profile domain.Profile
	if err := json.Unmarshal(content, &profile); err != nil {
		return nil, domain.Profile{}, fmt.Errorf("invalid profile JSON: %w", err)
	}
	if len(profile.Components) == 0 {
		return nil, domain.Profile{}, errors.New("invalid profile JSON: components must not be empty")
	}
	return content, profile, nil
}

func writeContext(path, pin string, rawProfile []byte) error {
	payload := struct {
		Pin     string          `json:"pin"`
		Profile json.RawMessage `json:"profile"`
	}{
		Pin:     pin,
		Profile: rawProfile,
	}
	content, err := json.MarshalIndent(payload, "", "  ")
	if err != nil {
		return err
	}
	content = append(content, '\n')
	return os.WriteFile(path, content, 0o600)
}

func plannedFiles(profile domain.Profile) []renderFile {
	files := []renderFile{
		{Template: "skeletons/ci.yml.tmpl", Output: ".github/workflows/ci.yml"},
	}
	if profile.GitOps != nil {
		return files
	}
	files = append(files,
		renderFile{Template: "skeletons/release.yml.tmpl", Output: ".github/workflows/release.yml"},
		renderFile{Template: "skeletons/prerelease.yml.tmpl", Output: ".github/workflows/prerelease.yml"},
		renderFile{Template: "skeletons/cleanup.yml.tmpl", Output: ".github/workflows/cleanup.yml"},
	)
	if hasTopic(profile.Topics, "sk-prerelease-on-push") {
		files = append(files, renderFile{Template: "skeletons/prerelease-on-push.yml.tmpl", Output: ".github/workflows/prerelease-on-push.yml"})
	}
	configTemplate := "configs/release-please-config.json.tmpl"
	if profile.Monorepo {
		configTemplate = "configs/release-please-config.monorepo.json.tmpl"
	}
	files = append(files,
		renderFile{Template: configTemplate, Output: "release-please-config.json"},
		renderFile{Template: "configs/release-please-manifest.json.tmpl", Output: ".release-please-manifest.json"},
	)
	return files
}

func lockPaths(profile domain.Profile) []string {
	if profile.GitOps != nil {
		return []string{".github/workflows/ci.yml"}
	}
	files := []string{
		".github/workflows/ci.yml",
		".github/workflows/release.yml",
		".github/workflows/prerelease.yml",
		".github/workflows/cleanup.yml",
		"release-please-config.json",
		".release-please-manifest.json",
	}
	if hasTopic(profile.Topics, "sk-prerelease-on-push") {
		files = append(files, ".github/workflows/prerelease-on-push.yml")
	}
	return files
}

func (s Service) renderOne(ctx context.Context, req Request, file renderFile, contextPath string) error {
	templatePath := filepath.Join(req.CatalogPath, filepath.FromSlash(templateRoot), filepath.FromSlash(file.Template))
	if _, err := os.Stat(templatePath); errors.Is(err, os.ErrNotExist) {
		return fmt.Errorf("template missing: %s", templatePath)
	} else if err != nil {
		return err
	}
	outputPath := filepath.Join(req.TargetPath, filepath.FromSlash(file.Output))
	if err := os.MkdirAll(filepath.Dir(outputPath), 0o755); err != nil {
		return err
	}
	if err := s.Templates.Execute(ctx, templatePath, outputPath, contextPath); err != nil {
		return err
	}
	return normalizeTrailingNewline(outputPath)
}

func normalizeTrailingNewline(path string) error {
	content, err := os.ReadFile(path)
	if err != nil {
		return err
	}
	content = bytes.TrimRight(content, "\n")
	content = append(content, '\n')
	return os.WriteFile(path, content, 0o644)
}

func substituteRepo(targetPath string, profile domain.Profile) error {
	repo := repoName(targetPath, profile.TargetRepo)
	for _, rel := range []string{
		".github/workflows/release.yml",
		".github/workflows/prerelease.yml",
		".github/workflows/prerelease-on-push.yml",
	} {
		path := filepath.Join(targetPath, filepath.FromSlash(rel))
		content, err := os.ReadFile(path)
		if errors.Is(err, os.ErrNotExist) {
			continue
		}
		if err != nil {
			return err
		}
		if !bytes.Contains(content, []byte("$REPO")) {
			continue
		}
		replaced := strings.ReplaceAll(string(content), "$REPO", repo)
		if err := os.WriteFile(path, []byte(replaced), 0o644); err != nil {
			return err
		}
	}
	return nil
}

func repoName(targetPath, targetRepo string) string {
	if targetRepo != "" {
		return targetRepo
	}
	base := filepath.Base(targetPath)
	if base == "." || base == "" {
		if cwd, err := os.Getwd(); err == nil {
			return filepath.Base(cwd)
		}
	}
	return base
}

func writeLock(targetPath, pinVersion, renderedAgainst, renderedAt string, files []string) error {
	hashes := make(map[string]string, len(files))
	for _, rel := range files {
		path := filepath.Join(targetPath, filepath.FromSlash(rel))
		if _, err := os.Stat(path); errors.Is(err, os.ErrNotExist) {
			return fmt.Errorf("expected rendered file missing: %s", rel)
		} else if err != nil {
			return err
		}
		hash, err := sha256File(path)
		if err != nil {
			return err
		}
		hashes[rel] = "sha256:" + hash
	}
	content := encodeLock(pinVersion, renderedAgainst, renderedAt, files, hashes)
	return os.WriteFile(filepath.Join(targetPath, filepath.FromSlash(lockPath)), content, 0o644)
}

func encodeLock(pinVersion, renderedAgainst, renderedAt string, files []string, hashes map[string]string) []byte {
	var out bytes.Buffer
	out.WriteString("{\n")
	fmt.Fprintf(&out, "  \"schema_version\": 1,\n")
	writeStringField(&out, "catalog_version", pinVersion, true)
	writeStringField(&out, "rendered_against", renderedAgainst, true)
	writeStringField(&out, "rendered_at", renderedAt, true)
	out.WriteString("  \"files\": {")
	if len(files) == 0 {
		out.WriteString("}\n")
		out.WriteString("}\n")
		return out.Bytes()
	}
	for i, rel := range files {
		key, _ := json.Marshal(rel)
		value, _ := json.Marshal(hashes[rel])
		if i == 0 {
			out.WriteByte('\n')
		} else {
			out.WriteString(",\n")
		}
		fmt.Fprintf(&out, "    %s: %s", key, value)
	}
	out.WriteByte('\n')
	out.WriteString("  }\n")
	out.WriteString("}\n")
	return out.Bytes()
}

func writeStringField(out *bytes.Buffer, key, value string, comma bool) {
	encoded, _ := json.Marshal(value)
	fmt.Fprintf(out, "  %q: %s", key, encoded)
	if comma {
		out.WriteByte(',')
	}
	out.WriteByte('\n')
}

func renderedAt(now func() time.Time) string {
	if now == nil {
		now = time.Now
	}
	return now().UTC().Format(time.RFC3339)
}

func hasTopic(topics []string, topic string) bool {
	for _, candidate := range topics {
		if candidate == topic {
			return true
		}
	}
	return false
}

func sha256File(path string) (string, error) {
	content, err := os.ReadFile(path)
	if err != nil {
		return "", err
	}
	sum := sha256.Sum256(content)
	return hex.EncodeToString(sum[:]), nil
}
