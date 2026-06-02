package detect

import (
	"context"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"

	"github.com/serverkraken/reusable-workflows/internal/domain"
	"github.com/serverkraken/reusable-workflows/internal/ports"
)

const (
	supportedLintTestLanguages = "go|python|rust|helm|flutter"
	warningExemptLanguages     = supportedLintTestLanguages + "|gitops"
)

var cgoPackages = []string{
	"github.com/mattn/go-sqlite3",
	"github.com/mattn/go-oci8",
	"github.com/godror/godror",
	"github.com/microsoft/go-mssqldb",
	"crawshaw.io/sqlite",
	"github.com/containerd/btrfs",
}

type Service struct {
	GitHub ports.GitHubMetadata
}

type Request struct {
	RepoPath         string
	LanguageOverride string
	TargetRepo       string
}

type Result struct {
	Legacy  domain.LegacyOutputs
	Profile domain.Profile
}

func (s Service) Detect(ctx context.Context, req Request) (Result, error) {
	if req.RepoPath == "" {
		return Result{}, errors.New("repo path is required")
	}
	info, err := os.Stat(req.RepoPath)
	if err != nil || !info.IsDir() {
		return Result{}, fmt.Errorf("repo path does not exist: %s", req.RepoPath)
	}
	gh := s.GitHub
	if gh == nil {
		gh = ports.StaticGitHubMetadata{}
	}

	branch, version, topics := "main", "0.0.0", []string(nil)
	if req.TargetRepo != "" {
		if b, err := gh.DefaultBranch(ctx, req.TargetRepo); err != nil {
			return Result{}, fmt.Errorf("repo not accessible: %s", req.TargetRepo)
		} else if b != "" {
			branch = b
		}
		if v, err := gh.LatestStableRelease(ctx, req.TargetRepo); err == nil && v != "" {
			version = strings.TrimPrefix(v, "v")
		}
		if t, err := gh.Topics(ctx, req.TargetRepo); err == nil {
			topics = t
		}
	}

	components, err := detectComponents(req.RepoPath)
	if err != nil {
		return Result{}, err
	}
	gitops := classifyGitOps(req.RepoPath, components)
	if gitops != nil {
		components[0].PrimaryLanguage = "gitops"
		components[0].ReleasePleaseType = "simple"
		components[0].Role = "gitops"
	}
	legacy, err := detectLegacyCI(req.RepoPath)
	if err != nil {
		return Result{}, err
	}
	if legacy == nil {
		legacy = []domain.LegacyCI{}
	}
	if topics == nil {
		topics = []string{}
	}

	profile := domain.Profile{
		SchemaVersion:  1,
		TargetRepo:     req.TargetRepo,
		DefaultBranch:  branch,
		CurrentVersion: version,
		Monorepo:       len(components) > 1,
		Components:     components,
		LegacyCI:       legacy,
		Topics:         topics,
		Warnings:       []domain.Warning{},
		GitOps:         gitops,
	}
	profile.Warnings = append(profile.Warnings, unsupportedLanguageWarnings(profile.Components)...)
	profile.Warnings = append(profile.Warnings, noReleaseEligibleWarnings(profile.Components)...)

	legacyLanguage, err := legacyLanguage(req.RepoPath, req.LanguageOverride)
	if err != nil {
		return Result{}, err
	}
	return Result{
		Legacy: domain.LegacyOutputs{
			Language:       legacyLanguage,
			ReleaseType:    releasePleaseType(legacyLanguage),
			CurrentVersion: version,
			DefaultBranch:  branch,
		},
		Profile: profile,
	}, nil
}

func legacyLanguage(repo, override string) (string, error) {
	if override == "" {
		override = "auto"
	}
	if override != "auto" {
		return override, nil
	}
	matches := rootLanguageSignals(repo)
	if len(matches) == 0 {
		if detectGitOpsKubernetes(repo) {
			return "gitops", nil
		}
		return "simple", nil
	}
	if len(matches) > 1 {
		return "", fmt.Errorf("ambiguous language signals: %s; rerun with explicit language input", strings.Join(matches, " "))
	}
	return matches[0], nil
}

func detectComponents(repo string) ([]domain.Component, error) {
	paths := explicitMonorepoPaths(repo)
	rootHasMarker := hasAny(repo, "go.mod", "pyproject.toml", "Cargo.toml", "Chart.yaml", "Dockerfile", "Containerfile", "package.json", "pubspec.yaml")
	if len(paths) == 0 && !rootHasMarker {
		paths = fallbackMarkerPaths(repo)
	}
	if len(paths) == 0 {
		paths = fallbackDockerfilePaths(repo)
	}
	if len(paths) == 0 {
		paths = []string{"."}
	}
	paths = dedupe(paths)

	components := make([]domain.Component, 0, len(paths))
	for _, p := range paths {
		langs := languagesAt(filepath.Join(repo, p))
		if langs == nil {
			langs = []string{}
		}
		primary := "generic"
		if len(langs) > 0 {
			primary = langs[0]
		}
		dockerfiles := inventoryDockerfiles(repo, p)
		if dockerfiles == nil {
			dockerfiles = []domain.Dockerfile{}
		}
		components = append(components, domain.Component{
			Path:              p,
			Languages:         langs,
			PrimaryLanguage:   primary,
			ReleasePleaseType: releasePleaseType(primary),
			Role:              role(repo, p, dockerfiles),
			Dockerfiles:       dockerfiles,
			ReleaseSignals:    releaseSignals(repo, p),
			CGO:               detectCGO(repo, p, primary),
		})
	}
	return components, nil
}

func explicitMonorepoPaths(repo string) []string {
	if has(repo, "go.work") {
		return parseGoWork(mustRead(filepath.Join(repo, "go.work")))
	}
	if has(repo, "Cargo.toml") && strings.Contains(mustRead(filepath.Join(repo, "Cargo.toml")), "[workspace]") {
		return parseCargoWorkspace(mustRead(filepath.Join(repo, "Cargo.toml")))
	}
	if has(repo, "pnpm-workspace.yaml") {
		return expandPNPM(repo, mustRead(filepath.Join(repo, "pnpm-workspace.yaml")))
	}
	return nil
}

func parseGoWork(content string) []string {
	var out []string
	inBlock := false
	for _, raw := range strings.Split(content, "\n") {
		line := strings.TrimSpace(raw)
		if line == "" {
			continue
		}
		if strings.HasPrefix(line, "use (") {
			inBlock = true
			continue
		}
		if inBlock && line == ")" {
			inBlock = false
			continue
		}
		if inBlock || strings.HasPrefix(line, "use ") {
			line = strings.TrimPrefix(line, "use ")
			line = strings.Trim(line, `"()	 `)
			line = strings.TrimPrefix(line, "./")
			if line != "" {
				out = append(out, line)
			}
		}
	}
	return out
}

func parseCargoWorkspace(content string) []string {
	re := regexp.MustCompile(`(?s)members\s*=\s*\[(.*?)\]`)
	m := re.FindStringSubmatch(content)
	if len(m) != 2 {
		return nil
	}
	var out []string
	for _, part := range strings.Split(m[1], ",") {
		part = strings.Trim(part, " \t\r\n\"'")
		if part != "" {
			out = append(out, part)
		}
	}
	return out
}

func expandPNPM(repo, content string) []string {
	var patterns []string
	inPackages := false
	for _, raw := range strings.Split(content, "\n") {
		line := strings.TrimSpace(raw)
		if line == "packages:" {
			inPackages = true
			continue
		}
		if inPackages && strings.HasPrefix(line, "-") {
			pat := strings.TrimSpace(strings.TrimPrefix(line, "-"))
			pat = strings.Trim(pat, "\"'")
			patterns = append(patterns, pat)
			continue
		}
		if inPackages && line != "" && !strings.HasPrefix(raw, " ") && !strings.HasPrefix(raw, "\t") {
			inPackages = false
		}
	}
	var out []string
	for _, pat := range patterns {
		matches, _ := filepath.Glob(filepath.Join(repo, pat))
		sort.Strings(matches)
		for _, m := range matches {
			if st, err := os.Stat(m); err == nil && st.IsDir() {
				if rel, err := filepath.Rel(repo, m); err == nil {
					out = append(out, filepath.ToSlash(rel))
				}
			}
		}
	}
	return out
}

func fallbackMarkerPaths(repo string) []string {
	var out []string
	_ = filepath.WalkDir(repo, func(path string, d fs.DirEntry, err error) error {
		if err != nil || d.IsDir() {
			return nil
		}
		base := d.Name()
		if base != "go.mod" && base != "pyproject.toml" && base != "Cargo.toml" && base != "Chart.yaml" {
			return nil
		}
		rel, _ := filepath.Rel(repo, filepath.Dir(path))
		depth := len(strings.Split(filepath.ToSlash(rel), "/"))
		if rel != "." && depth >= 1 && depth <= 3 {
			out = append(out, filepath.ToSlash(rel))
		}
		return nil
	})
	sort.Strings(out)
	return out
}

func fallbackDockerfilePaths(repo string) []string {
	var out []string
	_ = filepath.WalkDir(repo, func(path string, d fs.DirEntry, err error) error {
		if err != nil || d.IsDir() {
			return nil
		}
		name := d.Name()
		if name != "Dockerfile" && name != "Containerfile" {
			return nil
		}
		rel, _ := filepath.Rel(repo, filepath.Dir(path))
		depth := len(strings.Split(filepath.ToSlash(rel), "/"))
		if rel != "." && depth >= 1 && depth <= 3 {
			out = append(out, filepath.ToSlash(rel))
		}
		return nil
	})
	sort.Strings(out)
	if len(out) < 2 {
		return nil
	}
	return out
}

func rootLanguageSignals(repo string) []string {
	return languagesAt(repo)
}

func languagesAt(dir string) []string {
	var langs []string
	if has(dir, "go.mod") {
		langs = append(langs, "go")
	}
	if has(dir, "pyproject.toml") {
		langs = append(langs, "python")
	}
	if has(dir, "Cargo.toml") {
		langs = append(langs, "rust")
	}
	if has(dir, "Chart.yaml") {
		langs = append(langs, "helm")
	}
	if isFlutter(dir) {
		langs = append(langs, "flutter")
	}
	if has(dir, "package.json") {
		langs = append(langs, "node")
	}
	return langs
}

func isFlutter(dir string) bool {
	return has(dir, "pubspec.yaml") && strings.Contains(mustRead(filepath.Join(dir, "pubspec.yaml")), "sdk: flutter")
}

func inventoryDockerfiles(repo, componentPath string) []domain.Dockerfile {
	dir := filepath.Join(repo, componentPath)
	entries, err := os.ReadDir(dir)
	if err != nil {
		return []domain.Dockerfile{}
	}
	var names []string
	for _, e := range entries {
		if e.IsDir() {
			continue
		}
		n := e.Name()
		if n == "Dockerfile" || n == "Containerfile" || strings.HasPrefix(n, "Dockerfile.") || strings.HasPrefix(n, "Containerfile.") {
			names = append(names, n)
		}
	}
	sort.Strings(names)
	out := make([]domain.Dockerfile, 0, len(names))
	for _, name := range names {
		full := filepath.Join(dir, name)
		image := readImageOverride(full)
		source := "override"
		if image == "" {
			image = deriveImageName(name, componentPath)
			source = "derived"
		}
		eligible := name == "Dockerfile" || name == "Containerfile"
		if override := readReleaseOverride(full); override != nil {
			eligible = *override
		}
		out = append(out, domain.Dockerfile{Path: name, ImageName: image, ImageNameSource: source, ReleaseEligible: eligible})
	}
	return out
}

func readImageOverride(file string) string {
	for i, line := range firstLines(file, 5) {
		if i >= 5 {
			break
		}
		if strings.HasPrefix(line, "# onboard:image=") {
			v := strings.TrimPrefix(line, "# onboard:image=")
			if regexp.MustCompile(`^[A-Za-z0-9._/-]+$`).MatchString(v) {
				return v
			}
		}
	}
	return ""
}

func readReleaseOverride(file string) *bool {
	for _, line := range firstLines(file, 5) {
		switch line {
		case "# onboard:release=true":
			v := true
			return &v
		case "# onboard:release=false":
			v := false
			return &v
		}
	}
	return nil
}

func deriveImageName(filename, componentPath string) string {
	suffix := ""
	for _, p := range []string{"Dockerfile.", "Containerfile."} {
		if strings.HasPrefix(filename, p) {
			suffix = strings.TrimPrefix(filename, p)
		}
	}
	seg := ""
	if componentPath != "." {
		seg = filepath.Base(componentPath)
	}
	switch {
	case seg != "" && suffix != "":
		return "$REPO-" + seg + "-" + suffix
	case seg != "":
		return "$REPO-" + seg
	case suffix != "":
		return "$REPO-" + suffix
	default:
		return "$REPO"
	}
}

func role(repo, componentPath string, dockerfiles []domain.Dockerfile) string {
	dir := filepath.Join(repo, componentPath)
	if len(dockerfiles) > 0 {
		return "service"
	}
	if hasMainUnderCmd(dir) || hasCargoBin(dir) || hasPythonScripts(dir) {
		return "cli"
	}
	if has(dir, "Chart.yaml") {
		return "helm-app"
	}
	if isFlutter(dir) && dirExists(filepath.Join(dir, "android")) {
		return "mobile-app"
	}
	return "library"
}

func releaseSignals(repo, componentPath string) domain.ReleaseSignal {
	dir := filepath.Join(repo, componentPath)
	var sig domain.ReleaseSignal
	for _, f := range []string{".goreleaser.yaml", ".goreleaser.yml", "goreleaser.yaml", "goreleaser.yml"} {
		if has(dir, f) {
			rel := f
			if componentPath != "." {
				rel = filepath.ToSlash(filepath.Join(componentPath, f))
			}
			sig.GoReleaserConfig = &rel
			break
		}
	}
	if chart := firstNestedChart(dir); chart != "" {
		rel := chart
		if componentPath != "." {
			rel = filepath.ToSlash(filepath.Join(componentPath, chart))
		}
		sig.ChartYAML = &rel
	}
	sig.FlutterAndroid = isFlutter(dir) && dirExists(filepath.Join(dir, "android"))
	return sig
}

func detectCGO(repo, componentPath, primary string) bool {
	if primary != "go" {
		return false
	}
	dir := filepath.Join(repo, componentPath)
	found := false
	_ = filepath.WalkDir(dir, func(path string, d fs.DirEntry, err error) error {
		if err != nil || d.IsDir() || !strings.HasSuffix(d.Name(), ".go") {
			return nil
		}
		content := mustRead(path)
		for _, line := range strings.Split(content, "\n") {
			t := strings.TrimSpace(line)
			if t == `"C"` || t == `import "C"` {
				found = true
				return fs.SkipAll
			}
		}
		return nil
	})
	if found {
		return true
	}
	mod := mustRead(filepath.Join(dir, "go.mod"))
	for _, pkg := range cgoPackages {
		if strings.Contains(mod, pkg) {
			return true
		}
	}
	return false
}

func classifyGitOps(repo string, components []domain.Component) *domain.GitOpsSignal {
	if !detectGitOpsKubernetes(repo) {
		return nil
	}
	for _, c := range components {
		if regexp.MustCompile("^(" + supportedLintTestLanguages + ")$").MatchString(c.PrimaryLanguage) {
			return nil
		}
	}
	return &domain.GitOpsSignal{
		ManifestPaths:       ensureStrings(gitOpsManifestPaths(repo)),
		HasKubeLinterConfig: has(repo, ".kube-linter.yaml"),
		HasGitleaksConfig:   has(repo, ".gitleaks.toml"),
		SOPS:                has(repo, ".sops.yaml"),
	}
}

func detectGitOpsKubernetes(repo string) bool {
	return dirExists(filepath.Join(repo, "kubernetes")) &&
		has(repo, ".sops.yaml") &&
		(has(repo, "makejinja.toml") || dirExists(filepath.Join(repo, "bootstrap", "templates")))
}

func gitOpsManifestPaths(repo string) []string {
	base := filepath.Join(repo, "kubernetes")
	entries, err := os.ReadDir(base)
	if err != nil {
		return []string{}
	}
	var out []string
	for _, e := range entries {
		if !e.IsDir() {
			continue
		}
		switch e.Name() {
		case "bootstrap", "components", "flux-system":
			continue
		default:
			out = append(out, filepath.ToSlash(filepath.Join("kubernetes", e.Name())))
		}
	}
	sort.Strings(out)
	return out
}

func detectLegacyCI(repo string) ([]domain.LegacyCI, error) {
	dir := filepath.Join(repo, ".github", "workflows")
	entries, err := os.ReadDir(dir)
	if errors.Is(err, os.ErrNotExist) {
		return []domain.LegacyCI{}, nil
	}
	if err != nil {
		return nil, err
	}
	owned := map[string]bool{"ci.yml": true, "release.yml": true, "prerelease.yml": true, "prerelease-on-push.yml": true, "cleanup.yml": true}
	var out []domain.LegacyCI
	for _, e := range entries {
		if e.IsDir() || owned[e.Name()] || !(strings.HasSuffix(e.Name(), ".yml") || strings.HasSuffix(e.Name(), ".yaml")) {
			continue
		}
		rel := filepath.ToSlash(filepath.Join(".github", "workflows", e.Name()))
		content := mustRead(filepath.Join(dir, e.Name()))
		out = append(out, classifyLegacy(rel, content))
	}
	sort.Slice(out, func(i, j int) bool { return out[i].Path < out[j].Path })
	return out, nil
}

func classifyLegacy(path, content string) domain.LegacyCI {
	checks := []struct {
		needle string
		re     *regexp.Regexp
		msg    string
		repl   []string
	}{
		{needle: "aquasecurity/trivy-action", msg: "trivy-action (deprecated); replace with trivy-fs.yml or trivy-image.yml", repl: []string{"trivy-fs.yml", "trivy-image.yml"}},
		{needle: "docker/build-push-action", msg: "docker/build-push-action; replaced by docker-build.yml", repl: []string{"docker-build.yml"}},
		{re: regexp.MustCompile(`docker (build|buildx).*--push|docker push `), msg: "ad-hoc docker buildx + push; replaced by docker-build.yml", repl: []string{"docker-build.yml"}},
		{needle: "cargo-llvm-cov", msg: "cargo-llvm-cov test pipeline; replaced by test-rust.yml", repl: []string{"test-rust.yml"}},
		{re: regexp.MustCompile(`pytest|coverage run`), msg: "python test pipeline (pytest/coverage); replaced by test-python.yml", repl: []string{"test-python.yml"}},
		{re: regexp.MustCompile(`go test.*(-cover|-coverprofile|-race)`), msg: "go test pipeline; replaced by test-go.yml", repl: []string{"test-go.yml"}},
		{needle: "semantic-release", msg: "hand-rolled semantic-release; replaced by release-please.yml", repl: []string{"release-please.yml"}},
		{needle: "kubeconform", msg: "kubeconform manifest validation; replaced by kube-validate.yml", repl: []string{"kube-validate.yml"}},
		{re: regexp.MustCompile(`kube-linter|stackrox/kube-linter`), msg: "kube-linter; replaced by kube-lint.yml", repl: []string{"kube-lint.yml"}},
		{needle: "gitleaks", msg: "gitleaks secret scan; replaced by secret-scan.yml", repl: []string{"secret-scan.yml"}},
		{re: regexp.MustCompile(`trivy (fs|filesystem|rootfs)`), msg: "trivy filesystem scan (CLI); replaced by trivy-fs.yml", repl: []string{"trivy-fs.yml"}},
	}
	for _, c := range checks {
		if (c.needle != "" && strings.Contains(content, c.needle)) || (c.re != nil && c.re.MatchString(content)) {
			return domain.LegacyCI{Path: path, Summary: c.msg, ReplacedBy: c.repl}
		}
	}
	return domain.LegacyCI{Path: path, Summary: "unrecognized legacy workflow; manual review needed", ReplacedBy: []string{}}
}

func unsupportedLanguageWarnings(components []domain.Component) []domain.Warning {
	seen := map[string]bool{}
	re := regexp.MustCompile("^(" + warningExemptLanguages + ")$")
	var out []domain.Warning
	for _, c := range components {
		if seen[c.PrimaryLanguage] || re.MatchString(c.PrimaryLanguage) {
			continue
		}
		seen[c.PrimaryLanguage] = true
		out = append(out, domain.Warning{
			Code:            "no_lint_test_atom",
			PrimaryLanguage: c.PrimaryLanguage,
			Message:         "no lint/test atom for primary_language=" + c.PrimaryLanguage + "; rendered ci.yml will fall back to secscan only",
		})
	}
	return out
}

func noReleaseEligibleWarnings(components []domain.Component) []domain.Warning {
	var out []domain.Warning
	for _, c := range components {
		if len(c.Dockerfiles) == 0 {
			continue
		}
		eligible := false
		for _, d := range c.Dockerfiles {
			if d.ReleaseEligible {
				eligible = true
				break
			}
		}
		if !eligible {
			out = append(out, domain.Warning{
				Code:    "no_release_eligible",
				Path:    c.Path,
				Message: fmt.Sprintf("component at %s has %d Dockerfile(s) but none are release-eligible; rendered release.yml will skip docker-build. Set `# onboard:release=true` on the Dockerfile(s) to ship.", c.Path, len(c.Dockerfiles)),
			})
		}
	}
	return out
}

func releasePleaseType(primary string) string {
	switch primary {
	case "generic", "gitops", "simple":
		return "simple"
	case "flutter":
		return "dart"
	default:
		return primary
	}
}

func has(dir, name string) bool {
	st, err := os.Stat(filepath.Join(dir, name))
	return err == nil && !st.IsDir()
}

func hasAny(dir string, names ...string) bool {
	for _, n := range names {
		if has(dir, n) {
			return true
		}
	}
	return false
}

func dirExists(path string) bool {
	st, err := os.Stat(path)
	return err == nil && st.IsDir()
}

func mustRead(path string) string {
	b, err := os.ReadFile(path)
	if err != nil {
		return ""
	}
	return string(b)
}

func firstLines(path string, n int) []string {
	lines := strings.Split(mustRead(path), "\n")
	if len(lines) > n {
		return lines[:n]
	}
	return lines
}

func dedupe(in []string) []string {
	seen := map[string]bool{}
	var out []string
	for _, v := range in {
		v = filepath.ToSlash(strings.TrimPrefix(v, "./"))
		if v == "" || seen[v] {
			continue
		}
		seen[v] = true
		out = append(out, v)
	}
	return out
}

func ensureStrings(values []string) []string {
	if values == nil {
		return []string{}
	}
	return values
}

func hasMainUnderCmd(dir string) bool {
	found := false
	_ = filepath.WalkDir(filepath.Join(dir, "cmd"), func(path string, d fs.DirEntry, err error) error {
		if err == nil && !d.IsDir() && d.Name() == "main.go" {
			found = true
			return fs.SkipAll
		}
		return nil
	})
	return found
}

func hasCargoBin(dir string) bool {
	return strings.Contains(mustRead(filepath.Join(dir, "Cargo.toml")), "[[bin]]")
}

func hasPythonScripts(dir string) bool {
	content := mustRead(filepath.Join(dir, "pyproject.toml"))
	return strings.Contains(content, "[project.scripts]") || strings.Contains(content, "[tool.poetry.scripts]")
}

func firstNestedChart(dir string) string {
	var found string
	_ = filepath.WalkDir(dir, func(path string, d fs.DirEntry, err error) error {
		if err != nil || d.IsDir() || d.Name() != "Chart.yaml" || path == filepath.Join(dir, "Chart.yaml") {
			return nil
		}
		rel, _ := filepath.Rel(dir, path)
		depth := len(strings.Split(filepath.ToSlash(rel), "/"))
		if depth >= 3 && depth <= 5 {
			found = filepath.ToSlash(rel)
			return fs.SkipAll
		}
		return nil
	})
	return found
}
