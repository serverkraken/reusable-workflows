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

func TestRootMarkerWinsOverSubdirDockerfiles(t *testing.T) {
	p := detectFixture(t, "go-root-subdir-dockerfile").Profile
	if p.Monorepo || len(p.Components) != 1 || p.Components[0].Path != "." || p.Components[0].PrimaryLanguage != "go" {
		t.Fatalf("components=%+v", p.Components)
	}
	if len(p.Components[0].Dockerfiles) != 0 {
		t.Fatalf("root must not silently adopt sub-directory Dockerfiles: %+v", p.Components[0].Dockerfiles)
	}
	var w *domain.Warning
	for i := range p.Warnings {
		if p.Warnings[i].Code == "subdir_dockerfiles_unassigned" {
			w = &p.Warnings[i]
		}
	}
	if w == nil || w.Path != "images/api/Dockerfile,images/worker/Dockerfile" || !strings.Contains(w.Message, ".github/onboard.yml") {
		t.Fatalf("warning=%+v all=%+v", w, p.Warnings)
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
	entries, err := detectLegacyCI(tmp, nil)
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

func (failingMetadata) ReleaseTags(context.Context, string) ([]string, error) {
	return nil, os.ErrNotExist
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

func TestManifestDrivesComponents(t *testing.T) {
	p := detectFixture(t, "go-root-multi-image").Profile
	if len(p.ManifestSHA256) != 64 || !p.Monorepo || len(p.Components) != 4 {
		t.Fatalf("profile=%+v", p)
	}
	want := []string{".", "images/api", "images/worker", "charts/demo"}
	if got := componentPaths(p.Components); !reflect.DeepEqual(got, want) {
		t.Fatalf("paths=%v want %v", got, want)
	}
	root := p.Components[0]
	// Zwei Dockerfiles an EINER Komponente — das ist die Konstellation, in der
	// die Templates ein $imgSuffix an den Job-Namen haengen. Vorher hatte die
	// Fixture nur eines, und der zweite Herleitungsort dieses Suffix in
	// release.yml.tmpl wurde von keinem Test je gerendert (Audit J-0c).
	if root.PrimaryLanguage != "go" || len(root.Dockerfiles) != 2 {
		t.Fatalf("root=%+v", root)
	}
	if d := root.Dockerfiles[0]; d.Path != "images/tools/Dockerfile" || d.ImageName != "acme/multi/tools" || d.ImageNameSource != "manifest" || d.Context != "" || !d.ReleaseEligible {
		t.Fatalf("tools=%+v", d)
	}
	// `Dockerfile.debug` ist per Vorgabe NICHT release-faehig (nur `Dockerfile`
	// und `Containerfile` sind es); die Fixture hebt das mit der Annotation
	// `# onboard:release=true` auf. Ohne dieses Flag faellt das Image aus der
	// Release-Menge und das Suffix entstuende gar nicht.
	if d := root.Dockerfiles[1]; d.Path != "images/tools/Dockerfile.debug" || d.ImageName != "acme/multi/tools-debug" || d.ImageNameSource != "manifest" || !d.ReleaseEligible {
		t.Fatalf("tools-debug=%+v", d)
	}
	if root.ReleaseSignals.ChartYAML != nil {
		t.Fatalf("chart owned by charts/demo must not be a root signal: %+v", root.ReleaseSignals)
	}
	api := p.Components[1]
	if api.PrimaryLanguage != "generic" || len(api.Dockerfiles) != 1 || api.Dockerfiles[0].Path != "Dockerfile" || api.Dockerfiles[0].ImageName != "acme/multi/api" || api.Dockerfiles[0].Context != "" {
		t.Fatalf("api=%+v", api)
	}
	if w := p.Components[2]; w.Dockerfiles[0].Platforms != "linux/amd64" || w.Dockerfiles[0].Context != "." {
		t.Fatalf("worker=%+v", w)
	}
	chart := p.Components[3]
	if chart.PrimaryLanguage != "helm" || chart.ReleasePleaseType != "helm" || chart.Role != "helm-app" || !chart.Unittest || chart.Version != "0.3.0" {
		t.Fatalf("chart=%+v", chart)
	}
	if p.Workflows == nil || p.Workflows.E2E == nil || p.Workflows.E2E.Script != "test/e2e/run.sh" || p.Release == nil || !p.Release.DispatchTrigger {
		t.Fatalf("workflows=%+v release=%+v", p.Workflows, p.Release)
	}
	if len(p.Consumers) != 2 || p.Consumers[0].Repo != "acme/gitops-prod" || p.Consumers[1].Mode != "renovate" {
		t.Fatalf("consumers=%+v", p.Consumers)
	}
	for _, l := range p.LegacyCI {
		if l.Path == ".github/workflows/e2e.yml" {
			t.Fatalf("manifest-declared e2e.yml reported as legacy: %+v", l)
		}
	}
	for _, w := range p.Warnings {
		if w.Code == "subdir_dockerfiles_unassigned" || w.Code == "no_lint_test_atom" {
			t.Fatalf("unexpected warning %+v", w)
		}
	}
}

func TestManifestErrors(t *testing.T) {
	write := func(t *testing.T, manifest string, files map[string]string) string {
		tmp := t.TempDir()
		mustMkdir(t, filepath.Join(tmp, ".github"))
		mustWrite(t, filepath.Join(tmp, ".github", "onboard.yml"), manifest)
		for p, c := range files {
			mustMkdir(t, filepath.Dir(filepath.Join(tmp, p)))
			mustWrite(t, filepath.Join(tmp, p), c)
		}
		return tmp
	}
	tests := []struct {
		name, manifest string
		files          map[string]string
		want           string
	}{
		{"missing attached dockerfile", "schema: 1\ncomponents:\n  - path: .\n    dockerfiles:\n      - path: images/x/Dockerfile\n", map[string]string{"go.mod": "module x\n"}, "images/x/Dockerfile: no such file"},
		{"shorthand without dockerfile", "schema: 1\ncomponents:\n  - path: svc\n    image: a/b\n", map[string]string{"svc/go.mod": "module x\n"}, "but has 0 Dockerfiles"},
		{"mixed contexts", "schema: 1\ncomponents:\n  - path: .\n    dockerfiles:\n      - path: a/Dockerfile\n        context: a\n      - path: b/Dockerfile\n", map[string]string{"go.mod": "module x\n", "a/Dockerfile": "FROM scratch\n", "b/Dockerfile": "FROM scratch\n"}, "must share one build context"},
		{"missing component dir", "schema: 1\ncomponents:\n  - path: nope\n", nil, "component path nope does not exist"},
		{"schema error surfaces", "schema: 1\nfoo: 1\n", nil, "line 2: unknown key"},
		{"dockerfile already inventoried", "schema: 1\ncomponents:\n  - path: .\n    dockerfiles:\n      - path: Dockerfile\n", map[string]string{"go.mod": "module x\n", "Dockerfile": "FROM scratch\n"}, "already inventoried from the component directory"},
		{"dockerfile outside component", "schema: 1\ncomponents:\n  - path: svc\n    dockerfiles:\n      - path: other/Dockerfile\n", map[string]string{"svc/go.mod": "module x\n", "other/Dockerfile": "FROM scratch\n"}, "is outside component"},
		{
			"mixed platforms",
			"schema: 1\ncomponents:\n  - path: .\n    dockerfiles:\n      - path: a/Dockerfile\n        platforms: linux/amd64\n      - path: b/Dockerfile\n",
			map[string]string{"go.mod": "module x\n", "a/Dockerfile": "FROM scratch\n", "b/Dockerfile": "FROM scratch\n"},
			"Dockerfiles of component . must share one platforms value (docker-build-multi has a single platforms), got linux/amd64 vs (atom default)",
		},
		{
			"dockerfile claimed twice",
			"schema: 1\ncomponents:\n  - path: .\n    language: go\n    dockerfiles:\n      - path: images/api/Dockerfile\n  - path: images/api\n",
			map[string]string{"go.mod": "module x\n", "images/api/Dockerfile": "FROM scratch\n"},
			"line 7: Dockerfile images/api/Dockerfile is claimed by both component . and component images/api",
		},
		{
			"shorthand with attached dockerfiles only",
			"schema: 1\ncomponents:\n  - path: svc\n    image: a/b\n    dockerfiles:\n      - path: svc/sub/Dockerfile\n",
			map[string]string{"svc/go.mod": "module x\n", "svc/sub/Dockerfile": "FROM scratch\n"},
			"component svc has no Dockerfile in its directory; the shorthand fields apply to that file only",
		},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			repo := write(t, tt.manifest, tt.files)
			_, err := (Service{}).Detect(context.Background(), Request{RepoPath: repo})
			if err == nil || !strings.Contains(err.Error(), tt.want) {
				t.Fatalf("err=%v want %q", err, tt.want)
			}
			if !strings.HasPrefix(err.Error(), ".github/onboard.yml: line ") {
				t.Fatalf("err=%v missing manifest line-number prefix", err)
			}
		})
	}
}

// The "no Dockerfile in its directory" variant must not tell the adopter to
// "use dockerfiles[] instead" — they already did, and the shorthand simply has
// no own-directory file to apply to.
func TestManifestShorthandErrorDoesNotSuggestDockerfilesWhenPresent(t *testing.T) {
	tmp := t.TempDir()
	mustMkdir(t, filepath.Join(tmp, ".github"))
	mustMkdir(t, filepath.Join(tmp, "svc", "sub"))
	mustWrite(t, filepath.Join(tmp, ".github", "onboard.yml"),
		"schema: 1\ncomponents:\n  - path: svc\n    image: a/b\n    dockerfiles:\n      - path: svc/sub/Dockerfile\n")
	mustWrite(t, filepath.Join(tmp, "svc", "go.mod"), "module x\n")
	mustWrite(t, filepath.Join(tmp, "svc", "sub", "Dockerfile"), "FROM scratch\n")
	_, err := (Service{}).Detect(context.Background(), Request{RepoPath: tmp})
	if err == nil {
		t.Fatal("expected error")
	}
	if strings.Contains(err.Error(), "use dockerfiles[] instead") {
		t.Fatalf("stale suggestion in %v", err)
	}
}

// TestWalkersSkipHiddenDirectories pins that the file-system walkers ignore
// dot-directories: a `.worktrees/` checkout of this very repo, an editor's
// `.cache/`, or a vendored `.hidden/` build tree must never contribute a chart
// signal or an "unassigned Dockerfile" warning.
func TestWalkersSkipHiddenDirectories(t *testing.T) {
	tmp := t.TempDir()
	mustWrite(t, filepath.Join(tmp, "go.mod"), "module x\n")
	mustMkdir(t, filepath.Join(tmp, ".worktrees", "wt", "charts", "decoy"))
	mustWrite(t, filepath.Join(tmp, ".worktrees", "wt", "charts", "decoy", "Chart.yaml"),
		"apiVersion: v2\nname: decoy\nversion: 9.9.9\n")
	mustMkdir(t, filepath.Join(tmp, ".hidden"))
	mustWrite(t, filepath.Join(tmp, ".hidden", "Dockerfile"), "FROM scratch\n")

	res, err := (Service{}).Detect(context.Background(), Request{RepoPath: tmp})
	if err != nil {
		t.Fatal(err)
	}
	p := res.Profile
	if got := componentPaths(p.Components); !reflect.DeepEqual(got, []string{"."}) {
		t.Fatalf("paths=%v want [.]", got)
	}
	if sig := p.Components[0].ReleaseSignals.ChartYAML; sig != nil {
		t.Fatalf("hidden chart leaked into release signals: %q", *sig)
	}
	for _, w := range p.Warnings {
		if w.Code == "subdir_dockerfiles_unassigned" {
			t.Fatalf("hidden Dockerfile reported as orphan: %+v", w)
		}
	}
}

// TestManifestTypeHelmOverridesLanguage guards against type: helm being a
// no-op when another language marker (go.mod) already sorts ahead of helm
// in languagesAt's output: the manifest's type: helm must still win.
func TestManifestTypeHelmOverridesLanguage(t *testing.T) {
	tmp := t.TempDir()
	mustMkdir(t, filepath.Join(tmp, ".github"))
	mustMkdir(t, filepath.Join(tmp, "chart"))
	mustWrite(t, filepath.Join(tmp, ".github", "onboard.yml"), "schema: 1\ncomponents:\n  - path: chart\n    type: helm\n")
	mustWrite(t, filepath.Join(tmp, "chart", "go.mod"), "module chart\n")
	mustWrite(t, filepath.Join(tmp, "chart", "Chart.yaml"), "apiVersion: v2\nname: chart\nversion: 1.2.3\ntype: application\n")
	res, err := (Service{}).Detect(context.Background(), Request{RepoPath: tmp})
	if err != nil {
		t.Fatal(err)
	}
	c := res.Profile.Components[0]
	if c.PrimaryLanguage != "helm" || c.ReleasePleaseType != "helm" || c.Version != "1.2.3" {
		t.Fatalf("component=%+v", c)
	}
}

func TestProfileJSONHasNoNewKeysWithoutManifest(t *testing.T) {
	p := detectFixture(t, "go-repo").Profile
	raw, err := json.Marshal(p)
	if err != nil {
		t.Fatal(err)
	}
	for _, key := range []string{"manifest_sha256", "workflows", "gitops_consumers", "\"release\"", "unittest", "\"version\"", "\"context\"", "platforms"} {
		if strings.Contains(string(raw), key) {
			t.Fatalf("profile for a manifest-less repo leaks key %s: %s", key, raw)
		}
	}
}

// `gh release list` is ordered by date, so in a monorepo the newest release is
// whatever component shipped last. Seeding the root from it wrote a TAG NAME
// where a version belongs — wartung would have received
// {".": "ansible-v2.6.0", "controller": "ansible-v2.6.0", …}.
func TestLatestRootVersionIgnoresComponentTags(t *testing.T) {
	tags := []string{"ansible-v2.6.0", "v2.7.0", "controller-v2.5.2", "v2.6.0"}
	if got := latestRootVersion(tags); got != "2.7.0" {
		t.Fatalf("root version = %q, want 2.7.0", got)
	}
	if got := latestRootVersion([]string{"ansible-v2.6.0"}); got != "" {
		t.Fatalf("component-only repo returned %q, want empty", got)
	}
}

func TestLatestComponentVersion(t *testing.T) {
	tags := []string{"ansible-v2.6.0", "v2.7.0", "controller-v2.5.2", "ansible-v2.5.2"}
	for pkg, want := range map[string]string{
		"ansible":    "2.6.0", // newest of the two ansible tags
		"controller": "2.5.2",
		"unknown":    "",
	} {
		if got := latestComponentVersion(tags, pkg); got != want {
			t.Fatalf("%s = %q, want %q", pkg, got, want)
		}
	}
	// A root tag must never be mistaken for a component release.
	if got := latestComponentVersion([]string{"v2.7.0"}, "v2"); got != "" {
		t.Fatalf("root tag matched a component: %q", got)
	}
}

// End to end: a monorepo that already released per component must re-detect
// with each component on ITS OWN version, so re-onboarding is idempotent
// instead of dragging everything up to the root version.
func TestDetectSeedsComponentVersionsFromTheirOwnTags(t *testing.T) {
	repo := t.TempDir()
	write := func(p, body string) {
		t.Helper()
		full := filepath.Join(repo, filepath.FromSlash(p))
		if err := os.MkdirAll(filepath.Dir(full), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(full, []byte(body), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	write(".github/onboard.yml", "schema: 1\ncomponents:\n  - path: .\n  - path: controller\n    language: go\n    image: acme/controller\n    context: .\n  - path: ansible\n    image: acme/ansible\n    context: .\n")
	write("controller/go.mod", "module x\n")
	write("controller/Dockerfile", "FROM scratch\n")
	write("ansible/Dockerfile", "FROM scratch\n")

	svc := Service{GitHub: ports.StaticGitHubMetadata{
		Branch: "main",
		Tags:   []string{"ansible-v2.6.0", "v2.7.0", "controller-v2.5.2"},
	}}
	res, err := svc.Detect(context.Background(), Request{RepoPath: repo, TargetRepo: "acme/repo"})
	if err != nil {
		t.Fatal(err)
	}
	if res.Profile.CurrentVersion != "2.7.0" {
		t.Fatalf("current_version = %q, want 2.7.0", res.Profile.CurrentVersion)
	}
	got := map[string]string{}
	for _, c := range res.Profile.Components {
		got[c.Path] = c.Version
	}
	want := map[string]string{".": "", "controller": "2.5.2", "ansible": "2.6.0"}
	for path, wantVersion := range want {
		if got[path] != wantVersion {
			t.Fatalf("component %s version = %q, want %q (all: %v)", path, got[path], wantVersion, got)
		}
	}
}

// Tag listings have no meaningful order, and string comparison would rank
// 2.10.0 below 2.9.0 — pick the highest version numerically.
func TestVersionSelectionIsNumericAndOrderIndependent(t *testing.T) {
	tags := []string{"v2.9.0", "v2.10.0", "v2", "v2.10", "api-v1.9.0", "api-v1.10.0"}
	if got := latestRootVersion(tags); got != "2.10.0" {
		t.Fatalf("root = %q, want 2.10.0 (floating v2/v2.10 must not match)", got)
	}
	if got := latestComponentVersion(tags, "api"); got != "1.10.0" {
		t.Fatalf("api = %q, want 1.10.0", got)
	}
}

// writeManifestRepo builds a throwaway repo carrying an adopter manifest and
// the Dockerfiles it names.
func writeManifestRepo(t *testing.T, manifestYAML string, dockerfiles ...string) string {
	t.Helper()
	repo := t.TempDir()
	if err := os.MkdirAll(filepath.Join(repo, ".github"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(repo, ".github", "onboard.yml"), []byte(manifestYAML), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(repo, "go.mod"), []byte("module example.com/app\n\ngo 1.25\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	for _, df := range dockerfiles {
		full := filepath.Join(repo, filepath.FromSlash(df))
		if err := os.MkdirAll(filepath.Dir(full), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(full, []byte("FROM scratch\n"), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	return repo
}

func dockerfileByPath(t *testing.T, res Result, path string) domain.Dockerfile {
	t.Helper()
	for _, c := range res.Profile.Components {
		for _, df := range c.Dockerfiles {
			if df.Path == path {
				return df
			}
		}
	}
	t.Fatalf("no Dockerfile %q in profile", path)
	return domain.Dockerfile{}
}

// The gate settings have to survive the trip from the manifest into the
// profile — the templates read them from there, and nothing else would notice
// if they were dropped on the way.
func TestGateOptionsReachTheProfile(t *testing.T) {
	repo := writeManifestRepo(t, `schema: 1
components:
  - path: .
    language: go
    dockerfiles:
      - path: images/gated/Dockerfile
        image: acme/gated
        severity: CRITICAL
        fail_on_findings: false
      - path: images/plain/Dockerfile
        image: acme/plain
`, "images/gated/Dockerfile", "images/plain/Dockerfile")

	res, err := (Service{}).Detect(context.Background(), Request{RepoPath: repo})
	if err != nil {
		t.Fatalf("Detect: %v", err)
	}

	gated := dockerfileByPath(t, res, "images/gated/Dockerfile")
	if gated.Severity != "CRITICAL" {
		t.Errorf("severity=%q, want CRITICAL", gated.Severity)
	}
	if gated.FailOnFindings == nil || *gated.FailOnFindings {
		t.Errorf("fail_on_findings=%v, want an explicit false", gated.FailOnFindings)
	}

	// The neighbouring image must stay untouched, or one image's exemption
	// would quietly relax the gate for the whole component.
	plain := dockerfileByPath(t, res, "images/plain/Dockerfile")
	if plain.Severity != "" || plain.FailOnFindings != nil {
		t.Errorf("plain image picked up gate settings: severity=%q fail_on_findings=%v", plain.Severity, plain.FailOnFindings)
	}
}

// The component-level shorthand covers the common single-Dockerfile case.
func TestGateOptionsViaComponentShorthand(t *testing.T) {
	repo := writeManifestRepo(t, `schema: 1
components:
  - path: .
    language: go
    image: acme/app
    severity: HIGH,CRITICAL
    fail_on_findings: false
`, "Dockerfile")

	res, err := (Service{}).Detect(context.Background(), Request{RepoPath: repo})
	if err != nil {
		t.Fatalf("Detect: %v", err)
	}
	df := dockerfileByPath(t, res, "Dockerfile")
	if df.Severity != "HIGH,CRITICAL" {
		t.Errorf("severity=%q", df.Severity)
	}
	if df.FailOnFindings == nil || *df.FailOnFindings {
		t.Errorf("fail_on_findings=%v, want an explicit false", df.FailOnFindings)
	}
}

// Omitting the keys must leave them absent, not zero: the profile is
// serialised with omitempty and the templates emit the input only when
// present, so a false-instead-of-absent would change every adopter's render.
func TestGateOptionsOmittedStayAbsentInJSON(t *testing.T) {
	repo := writeManifestRepo(t, `schema: 1
components:
  - path: .
    language: go
    image: acme/app
`, "Dockerfile")

	res, err := (Service{}).Detect(context.Background(), Request{RepoPath: repo})
	if err != nil {
		t.Fatalf("Detect: %v", err)
	}
	raw, err := json.Marshal(res.Profile)
	if err != nil {
		t.Fatal(err)
	}
	for _, key := range []string{"severity", "fail_on_findings"} {
		if strings.Contains(string(raw), key) {
			t.Errorf("profile JSON carries %q although the manifest omits it", key)
		}
	}
}

// Audit J-8. `app_version` und `unittest` wirken ausschliesslich an einer
// Helm-Komponente. An einer anderen gesetzt passierte NICHTS - kein Eintrag,
// keine Meldung. Der Adopter erklaert etwas und bekommt Schweigen.
//
// Die Gegenprobe ist der wichtigere Teil des Tests: an einem erkannten Chart
// OHNE `type: helm` im Manifest darf nicht gewarnt werden. Genau dieser Fall
// waere zerbrochen, haette die Pruefung im Parser statt nach der Erkennung
// gesessen.
func TestHelmOnlyKeysOnNonHelmComponentWarn(t *testing.T) {
	build := func(t *testing.T, man string, files map[string]string) domain.Profile {
		t.Helper()
		tmp := t.TempDir()
		mustMkdir(t, filepath.Join(tmp, ".github"))
		mustWrite(t, filepath.Join(tmp, ".github", "onboard.yml"), man)
		for p, c := range files {
			mustMkdir(t, filepath.Dir(filepath.Join(tmp, p)))
			mustWrite(t, filepath.Join(tmp, p), c)
		}
		res, err := (Service{}).Detect(context.Background(), Request{RepoPath: tmp})
		if err != nil {
			t.Fatalf("detect: %v", err)
		}
		return res.Profile
	}
	codes := func(p domain.Profile) []string {
		var out []string
		for _, w := range p.Warnings {
			if w.Code == "helm_only_key_on_non_helm" {
				out = append(out, w.Path+": "+w.Message)
			}
		}
		return out
	}

	t.Run("app_version auf einer Go-Komponente warnt", func(t *testing.T) {
		p := build(t,
			"schema: 1\ncomponents:\n  - path: .\n    language: go\n    app_version: true\n",
			map[string]string{"go.mod": "module x\n"})
		got := codes(p)
		if len(got) != 1 || !strings.Contains(got[0], "app_version") {
			t.Fatalf("warnings=%v", got)
		}
	})

	t.Run("unittest auf einer Go-Komponente warnt", func(t *testing.T) {
		p := build(t,
			"schema: 1\ncomponents:\n  - path: .\n    language: go\n    unittest: true\n",
			map[string]string{"go.mod": "module x\n"})
		got := codes(p)
		if len(got) != 1 || !strings.Contains(got[0], "unittest") {
			t.Fatalf("warnings=%v", got)
		}
	})

	t.Run("beide Schluessel warnen einzeln", func(t *testing.T) {
		p := build(t,
			"schema: 1\ncomponents:\n  - path: .\n    language: go\n    app_version: true\n    unittest: true\n",
			map[string]string{"go.mod": "module x\n"})
		if got := codes(p); len(got) != 2 {
			t.Fatalf("want 2 warnings, got %v", got)
		}
	})

	t.Run("type: helm warnt nicht", func(t *testing.T) {
		p := build(t,
			"schema: 1\ncomponents:\n  - path: charts/app\n    type: helm\n    app_version: true\n    unittest: true\n",
			map[string]string{"charts/app/Chart.yaml": "apiVersion: v2\nname: app\nversion: 0.1.0\n"})
		if got := codes(p); len(got) != 0 {
			t.Fatalf("helm component must not warn: %v", got)
		}
	})

	// Der Fall, der einen Parser-Fix zerbrochen haette: Chart nur ERKANNT,
	// nicht deklariert. primary_language wird trotzdem helm.
	t.Run("erkanntes Chart ohne type: helm warnt nicht", func(t *testing.T) {
		p := build(t,
			"schema: 1\ncomponents:\n  - path: charts/app\n    app_version: true\n    unittest: true\n",
			map[string]string{"charts/app/Chart.yaml": "apiVersion: v2\nname: app\nversion: 0.1.0\n"})
		if len(p.Components) != 1 || p.Components[0].PrimaryLanguage != "helm" {
			t.Fatalf("Vorbedingung verfehlt, primary_language=%q", p.Components[0].PrimaryLanguage)
		}
		if got := codes(p); len(got) != 0 {
			t.Fatalf("erkanntes Chart muss ohne Warnung durchgehen: %v", got)
		}
	})
}
