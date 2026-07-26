package detect

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"

	"github.com/serverkraken/reusable-workflows/internal/domain"
	"github.com/serverkraken/reusable-workflows/internal/ports"
)

func fixture(t *testing.T, parts ...string) string {
	t.Helper()
	all := append([]string{"..", "..", "..", "tests", "fixtures", "onboard"}, parts...)
	p, err := filepath.Abs(filepath.Join(all...))
	if err != nil {
		t.Fatal(err)
	}
	return p
}

func detectFixture(t *testing.T, name string) Result {
	t.Helper()
	res, err := (Service{}).Detect(context.Background(), Request{RepoPath: fixture(t, name)})
	if err != nil {
		t.Fatalf("Detect(%s): %v", name, err)
	}
	return res
}

func TestLegacyDetection(t *testing.T) {
	tests := []struct {
		fixture string
		lang    string
		relType string
	}{
		{"go-repo", "go", "go"},
		{"python-poetry", "python", "python"},
		{"rust-cargo", "rust", "rust"},
		{"cargo-workspace", "rust", "rust"},
		{"helm-chart", "helm", "helm"},
		{"node-package", "node", "node"},
		{"pnpm-workspace", "node", "node"},
		{"simple", "simple", "simple"},
		{"flutter-app", "flutter", "dart"},
		{"gitops-cluster", "gitops", "simple"},
	}
	for _, tt := range tests {
		t.Run(tt.fixture, func(t *testing.T) {
			res := detectFixture(t, tt.fixture)
			if res.Legacy.Language != tt.lang || res.Legacy.ReleaseType != tt.relType {
				t.Fatalf("legacy=%+v, want lang=%s release_type=%s", res.Legacy, tt.lang, tt.relType)
			}
			if res.Legacy.CurrentVersion != "0.0.0" || res.Legacy.DefaultBranch != "main" {
				t.Fatalf("defaults not preserved: %+v", res.Legacy)
			}
		})
	}
}

func TestLegacyAmbiguousAndOverride(t *testing.T) {
	_, err := (Service{}).Detect(context.Background(), Request{RepoPath: fixture(t, "ambiguous")})
	if err == nil || !strings.Contains(err.Error(), "ambiguous language signals") {
		t.Fatalf("expected ambiguous error, got %v", err)
	}
	res, err := (Service{}).Detect(context.Background(), Request{RepoPath: fixture(t, "ambiguous"), LanguageOverride: "go"})
	if err != nil {
		t.Fatal(err)
	}
	if res.Legacy.Language != "go" {
		t.Fatalf("override ignored: %+v", res.Legacy)
	}
}

func TestMissingRepoPath(t *testing.T) {
	if _, err := (Service{}).Detect(context.Background(), Request{}); err == nil {
		t.Fatal("expected missing repo path error")
	}
	if _, err := (Service{}).Detect(context.Background(), Request{RepoPath: "/nonexistent/path"}); err == nil {
		t.Fatal("expected nonexistent path error")
	}
}

func TestGitHubMetadataIsInjected(t *testing.T) {
	res, err := (Service{GitHub: ports.StaticGitHubMetadata{
		Branch:  "trunk",
		Version: "v1.2.3",
		Names:   []string{"sk-prerelease-on-push", "service"},
	}}).Detect(context.Background(), Request{RepoPath: fixture(t, "go-repo"), TargetRepo: "serverkraken/example"})
	if err != nil {
		t.Fatal(err)
	}
	if res.Profile.DefaultBranch != "trunk" || res.Profile.CurrentVersion != "1.2.3" || res.Profile.TargetRepo != "serverkraken/example" {
		t.Fatalf("metadata mismatch: %+v", res.Profile)
	}
	if !reflect.DeepEqual(res.Profile.Topics, []string{"sk-prerelease-on-push", "service"}) {
		t.Fatalf("topics mismatch: %#v", res.Profile.Topics)
	}
}

func TestGitHubMetadataDefaultBranchFailureIsFatal(t *testing.T) {
	_, err := (Service{GitHub: failingMetadata{}}).Detect(context.Background(), Request{RepoPath: fixture(t, "go-repo"), TargetRepo: "serverkraken/missing"})
	if err == nil || !strings.Contains(err.Error(), "repo not accessible") {
		t.Fatalf("expected repo accessibility error, got %v", err)
	}
}

func TestProfileSingleGoRepo(t *testing.T) {
	p := detectFixture(t, "go-repo").Profile
	if p.SchemaVersion != 1 || p.Monorepo {
		t.Fatalf("bad profile header: %+v", p)
	}
	assertComponent(t, p.Components[0], ".", []string{"go"}, "go", "go", "library", false)
	if len(p.Components[0].Dockerfiles) != 0 {
		t.Fatalf("unexpected dockerfiles: %+v", p.Components[0].Dockerfiles)
	}
	assertJSONRoundTrip(t, p)
}

func TestMonorepoDetection(t *testing.T) {
	p := detectFixture(t, "monorepo-go").Profile
	if !p.Monorepo || len(p.Components) != 2 {
		t.Fatalf("expected 2-component monorepo, got %+v", p.Components)
	}
	got := []string{p.Components[0].Path, p.Components[1].Path}
	want := []string{"services/api", "services/worker"}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("paths=%v, want %v", got, want)
	}
	for _, c := range p.Components {
		if c.PrimaryLanguage != "go" || c.Role != "service" || len(c.Dockerfiles) != 1 {
			t.Fatalf("bad component: %+v", c)
		}
	}
}

func TestCargoAndPNPMWorkspaceDetection(t *testing.T) {
	cargo := detectFixture(t, "cargo-workspace").Profile
	if got := componentPaths(cargo.Components); !reflect.DeepEqual(got, []string{"pkg-a", "pkg-b"}) {
		t.Fatalf("cargo paths=%v", got)
	}
	pnpm := detectFixture(t, "pnpm-workspace").Profile
	if got := componentPaths(pnpm.Components); !reflect.DeepEqual(got, []string{"apps/api", "apps/web", "packages/shared"}) {
		t.Fatalf("pnpm paths=%v", got)
	}
}

func TestDockerfileInventoryAndWarnings(t *testing.T) {
	p := detectFixture(t, "multi-dockerfile").Profile
	dfs := p.Components[0].Dockerfiles
	if len(dfs) != 2 {
		t.Fatalf("dockerfiles=%+v", dfs)
	}
	if dfs[0].Path != "Dockerfile" || dfs[0].ImageName != "$REPO" || !dfs[0].ReleaseEligible {
		t.Fatalf("bad root dockerfile: %+v", dfs[0])
	}
	if dfs[1].Path != "Dockerfile.worker" || dfs[1].ImageName == "" || !dfs[1].ReleaseEligible || dfs[1].ImageNameSource != "override" {
		t.Fatalf("bad worker dockerfile: %+v", dfs[1])
	}

	tmp := t.TempDir()
	if err := os.WriteFile(filepath.Join(tmp, "Dockerfile.dev"), []byte("FROM scratch\n"), 0644); err != nil {
		t.Fatal(err)
	}
	res, err := (Service{}).Detect(context.Background(), Request{RepoPath: tmp})
	if err != nil {
		t.Fatal(err)
	}
	if len(res.Profile.Warnings) != 2 {
		t.Fatalf("expected generic + no-release warnings, got %+v", res.Profile.Warnings)
	}
}

func TestReleaseSignalsAndRoles(t *testing.T) {
	cli := detectFixture(t, "cli-go-with-goreleaser").Profile.Components[0]
	if cli.Role != "cli" || cli.ReleaseSignals.GoReleaserConfig == nil {
		t.Fatalf("bad cli signals: %+v", cli)
	}
	helm := detectFixture(t, "helm-chart").Profile.Components[0]
	if helm.Role != "helm-app" || helm.PrimaryLanguage != "helm" {
		t.Fatalf("bad helm role: %+v", helm)
	}
	serviceHelm := detectFixture(t, "service-with-helm").Profile.Components[0]
	if serviceHelm.Role != "service" || serviceHelm.ReleaseSignals.ChartYAML == nil {
		t.Fatalf("bad service chart signal: %+v", serviceHelm)
	}
	flutterApp := detectFixture(t, "flutter-app").Profile.Components[0]
	if flutterApp.Role != "mobile-app" || !flutterApp.ReleaseSignals.FlutterAndroid || flutterApp.ReleasePleaseType != "dart" {
		t.Fatalf("bad flutter app: %+v", flutterApp)
	}
	flutterPackage := detectFixture(t, "flutter-package").Profile.Components[0]
	if flutterPackage.Role != "library" || flutterPackage.ReleaseSignals.FlutterAndroid {
		t.Fatalf("bad flutter package: %+v", flutterPackage)
	}
}

func TestCGODetection(t *testing.T) {
	if !detectFixture(t, "go-cgo").Profile.Components[0].CGO {
		t.Fatal("expected direct cgo")
	}
	if !detectFixture(t, "go-cgo-transitive").Profile.Components[0].CGO {
		t.Fatal("expected transitive cgo")
	}
	if detectFixture(t, "go-repo").Profile.Components[0].CGO {
		t.Fatal("did not expect cgo")
	}
}

func TestGitOpsProfile(t *testing.T) {
	p := detectFixture(t, "gitops-cluster").Profile
	if p.GitOps == nil {
		t.Fatal("expected gitops object")
	}
	c := p.Components[0]
	assertComponent(t, c, ".", []string{}, "gitops", "simple", "gitops", false)
	if !reflect.DeepEqual(p.GitOps.ManifestPaths, []string{"kubernetes/apps", "kubernetes/argo"}) {
		t.Fatalf("manifest paths=%v", p.GitOps.ManifestPaths)
	}
	if !p.GitOps.HasKubeLinterConfig || !p.GitOps.HasGitleaksConfig || !p.GitOps.SOPS {
		t.Fatalf("bad gitops flags: %+v", p.GitOps)
	}
	if len(p.Warnings) != 0 {
		t.Fatalf("gitops should not warn: %+v", p.Warnings)
	}
}

func TestLegacyCIClassification(t *testing.T) {
	p := detectFixture(t, "legacy-ci").Profile
	if len(p.LegacyCI) != 2 {
		t.Fatalf("legacy entries=%+v", p.LegacyCI)
	}
	for _, e := range p.LegacyCI {
		if len(e.ReplacedBy) == 0 {
			t.Fatalf("expected confident replacement: %+v", e)
		}
	}
}

func TestFallbackDockerfileMonorepo(t *testing.T) {
	tmp := t.TempDir()
	mustMkdir(t, filepath.Join(tmp, "services", "api"))
	mustMkdir(t, filepath.Join(tmp, "services", "worker"))
	mustWrite(t, filepath.Join(tmp, "services", "api", "Dockerfile"), "FROM scratch\n")
	mustWrite(t, filepath.Join(tmp, "services", "worker", "Containerfile"), "FROM scratch\n")
	p, err := (Service{}).Detect(context.Background(), Request{RepoPath: tmp})
	if err != nil {
		t.Fatal(err)
	}
	if got := componentPaths(p.Profile.Components); !reflect.DeepEqual(got, []string{"services/api", "services/worker"}) {
		t.Fatalf("paths=%v", got)
	}
	for _, c := range p.Profile.Components {
		if c.PrimaryLanguage != "generic" || c.ReleasePleaseType != "simple" || c.Role != "service" {
			t.Fatalf("bad fallback component: %+v", c)
		}
	}
}

func TestFallbackMarkerMonorepo(t *testing.T) {
	tmp := t.TempDir()
	mustMkdir(t, filepath.Join(tmp, "services", "api"))
	mustMkdir(t, filepath.Join(tmp, "services", "worker"))
	mustWrite(t, filepath.Join(tmp, "services", "api", "go.mod"), "module api\n")
	mustWrite(t, filepath.Join(tmp, "services", "worker", "pyproject.toml"), "[project]\n")
	res, err := (Service{}).Detect(context.Background(), Request{RepoPath: tmp})
	if err != nil {
		t.Fatal(err)
	}
	if got := componentPaths(res.Profile.Components); !reflect.DeepEqual(got, []string{"services/api", "services/worker"}) {
		t.Fatalf("paths=%v", got)
	}
}

func TestDetectorEdgeCases(t *testing.T) {
	tmp := t.TempDir()
	mustWrite(t, filepath.Join(tmp, "go.work"), `go 1.22
use ./svc
`)
	mustMkdir(t, filepath.Join(tmp, "svc"))
	mustWrite(t, filepath.Join(tmp, "svc", "go.mod"), "module svc\n")
	res, err := (Service{}).Detect(context.Background(), Request{RepoPath: tmp})
	if err != nil {
		t.Fatal(err)
	}
	if got := componentPaths(res.Profile.Components); !reflect.DeepEqual(got, []string{"svc"}) {
		t.Fatalf("single-line go.work paths=%v", got)
	}

	emptyCargo := parseCargoWorkspace("[workspace]\nresolver = \"2\"\n")
	if len(emptyCargo) != 0 {
		t.Fatalf("empty cargo workspace=%v", emptyCargo)
	}
	if got := dedupe([]string{"./a", "a", "", "b"}); !reflect.DeepEqual(got, []string{"a", "b"}) {
		t.Fatalf("dedupe=%v", got)
	}
	if got := ensureStrings(nil); got == nil || len(got) != 0 {
		t.Fatalf("ensureStrings nil=%v", got)
	}
	if got := ensureStrings([]string{"x"}); !reflect.DeepEqual(got, []string{"x"}) {
		t.Fatalf("ensureStrings value=%v", got)
	}
	if lines := firstLines(filepath.Join(tmp, "missing"), 5); len(lines) != 1 || lines[0] != "" {
		t.Fatalf("firstLines missing=%v", lines)
	}
}

func TestDockerfileHeaderOverrides(t *testing.T) {
	tmp := t.TempDir()
	mustWrite(t, filepath.Join(tmp, "Dockerfile"), "# onboard:image=bad image\n# onboard:release=false\nFROM scratch\n")
	mustWrite(t, filepath.Join(tmp, "Dockerfile.dev"), "# comment\n# onboard:release=true\nFROM scratch\n")
	mustWrite(t, filepath.Join(tmp, "Containerfile.debug"), "FROM scratch\n")
	res, err := (Service{}).Detect(context.Background(), Request{RepoPath: tmp})
	if err != nil {
		t.Fatal(err)
	}
	dfs := res.Profile.Components[0].Dockerfiles
	if len(dfs) != 3 {
		t.Fatalf("dockerfiles=%+v", dfs)
	}
	if dfs[1].Path != "Dockerfile" || dfs[1].ImageName != "$REPO" || dfs[1].ReleaseEligible {
		t.Fatalf("invalid Dockerfile override handling: %+v", dfs[1])
	}
	if dfs[2].Path != "Dockerfile.dev" || !dfs[2].ReleaseEligible {
		t.Fatalf("release=true handling: %+v", dfs[2])
	}
}

func TestGitOpsNonMatches(t *testing.T) {
	tmp := t.TempDir()
	mustMkdir(t, filepath.Join(tmp, "kubernetes", "bootstrap"))
	mustMkdir(t, filepath.Join(tmp, "kubernetes", "components"))
	mustWrite(t, filepath.Join(tmp, ".sops.yaml"), "creation_rules: []\n")
	mustWrite(t, filepath.Join(tmp, "makejinja.toml"), "")
	res, err := (Service{}).Detect(context.Background(), Request{RepoPath: tmp})
	if err != nil {
		t.Fatal(err)
	}
	if res.Profile.GitOps == nil || len(res.Profile.GitOps.ManifestPaths) != 0 {
		t.Fatalf("expected gitops with no workloads, got %+v", res.Profile.GitOps)
	}

	withGo := t.TempDir()
	mustMkdir(t, filepath.Join(withGo, "kubernetes", "apps"))
	mustWrite(t, filepath.Join(withGo, ".sops.yaml"), "")
	mustWrite(t, filepath.Join(withGo, "makejinja.toml"), "")
	mustWrite(t, filepath.Join(withGo, "go.mod"), "module x\n")
	res, err = (Service{}).Detect(context.Background(), Request{RepoPath: withGo})
	if err != nil {
		t.Fatal(err)
	}
	if res.Profile.GitOps != nil || res.Profile.Components[0].PrimaryLanguage != "go" {
		t.Fatalf("buildable gitops-like repo should stay go: %+v", res.Profile)
	}
}

func TestLegacyCIAllClassifiers(t *testing.T) {
	cases := []struct {
		name    string
		content string
		want    string
	}{
		{"trivy-action.yml", "uses: aquasecurity/trivy-action@v1", "trivy-fs.yml"},
		{"docker-action.yml", "uses: docker/build-push-action@v6", "docker-build.yml"},
		{"docker-cli.yml", "run: docker buildx build --push .", "docker-build.yml"},
		{"rust.yml", "run: cargo-llvm-cov", "test-rust.yml"},
		{"python.yml", "run: pytest", "test-python.yml"},
		{"go.yml", "run: go test ./... -cover", "test-go.yml"},
		{"semantic.yml", "run: semantic-release", "release-please.yml"},
		{"kubeconform.yml", "run: kubeconform .", "kube-validate.yml"},
		{"kube-linter.yml", "run: kube-linter lint", "kube-lint.yml"},
		{"gitleaks.yml", "run: gitleaks detect", "secret-scan.yml"},
		{"trivy-cli.yml", "run: trivy fs .", "trivy-fs.yml"},
		{"unknown.yml", "run: echo hi", ""},
	}
	tmp := t.TempDir()
	dir := filepath.Join(tmp, ".github", "workflows")
	mustMkdir(t, dir)
	for _, c := range cases {
		mustWrite(t, filepath.Join(dir, c.name), c.content)
	}
	entries, err := detectLegacyCI(tmp)
	if err != nil {
		t.Fatal(err)
	}
	if len(entries) != len(cases) {
		t.Fatalf("entries=%+v", entries)
	}
	byPath := map[string]domain.LegacyCI{}
	for _, e := range entries {
		byPath[filepath.Base(e.Path)] = e
	}
	for _, c := range cases {
		got := byPath[c.name]
		if c.want == "" {
			if len(got.ReplacedBy) != 0 {
				t.Fatalf("%s replacement=%v", c.name, got.ReplacedBy)
			}
			continue
		}
		if !contains(got.ReplacedBy, c.want) {
			t.Fatalf("%s replacement=%v, want %s", c.name, got.ReplacedBy, c.want)
		}
	}
}

func TestSmallHelpers(t *testing.T) {
	if releasePleaseType("flutter") != "dart" || releasePleaseType("generic") != "simple" || releasePleaseType("go") != "go" {
		t.Fatal("release type mapping regressed")
	}
	if deriveImageName("Dockerfile.worker", ".") != "$REPO-worker" ||
		deriveImageName("Containerfile", "services/api") != "$REPO-api" ||
		deriveImageName("Containerfile.debug", "services/api") != "$REPO-api-debug" {
		t.Fatal("image derivation regressed")
	}
}

type failingMetadata struct{}

func (failingMetadata) DefaultBranch(context.Context, string) (string, error) {
	return "", os.ErrNotExist
}

func (failingMetadata) LatestStableRelease(context.Context, string) (string, error) {
	return "", os.ErrNotExist
}

func (failingMetadata) Topics(context.Context, string) ([]string, error) {
	return nil, os.ErrNotExist
}

func assertComponent(t *testing.T, c domain.Component, path string, languages []string, primary, releaseType, role string, cgo bool) {
	t.Helper()
	if c.Path != path || !sameStrings(c.Languages, languages) || c.PrimaryLanguage != primary || c.ReleasePleaseType != releaseType || c.Role != role || c.CGO != cgo {
		t.Fatalf("component=%+v", c)
	}
}

func sameStrings(a, b []string) bool {
	if len(a) != len(b) {
		return false
	}
	for i := range a {
		if a[i] != b[i] {
			return false
		}
	}
	return true
}

func componentPaths(components []domain.Component) []string {
	out := make([]string, len(components))
	for i, c := range components {
		out[i] = c.Path
	}
	return out
}

func assertJSONRoundTrip(t *testing.T, p domain.Profile) {
	t.Helper()
	b, err := json.Marshal(p)
	if err != nil {
		t.Fatal(err)
	}
	var got domain.Profile
	if err := json.Unmarshal(b, &got); err != nil {
		t.Fatal(err)
	}
	if got.SchemaVersion != p.SchemaVersion || len(got.Components) != len(p.Components) {
		t.Fatalf("round-trip mismatch: %+v", got)
	}
}

func mustMkdir(t *testing.T, path string) {
	t.Helper()
	if err := os.MkdirAll(path, 0755); err != nil {
		t.Fatal(err)
	}
}

func mustWrite(t *testing.T, path, content string) {
	t.Helper()
	if err := os.WriteFile(path, []byte(content), 0644); err != nil {
		t.Fatal(err)
	}
}

func contains(values []string, want string) bool {
	for _, v := range values {
		if v == want {
			return true
		}
	}
	return false
}
