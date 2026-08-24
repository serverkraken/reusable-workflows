package manifest

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

const validManifest = `schema: 1
components:
  - path: .
    language: go
    dockerfiles:
      - path: images/tools/Dockerfile
        image: serverkraken/mailstack/tools
        context: .
  - path: images/postfix
    image: serverkraken/mailstack/postfix
    context: .
    platforms: linux/amd64
    release: true
  - path: charts/mailstack
    type: helm
    unittest: true
workflows:
  e2e:
    script: test/e2e/run.sh
    schedule: "0 3 * * *"
release:
  dispatch_trigger: true
gitops:
  - repo: serverkraken/homelab-mail-nue
    scope: [kubernetes/apps/mailstack/**]
  - repo: serverkraken/homelab-study
    mode: renovate
`

func TestParseValidManifest(t *testing.T) {
	m, err := Parse([]byte(validManifest))
	if err != nil {
		t.Fatal(err)
	}
	if m.Schema != 1 || len(m.Components) != 3 {
		t.Fatalf("m=%+v", m)
	}
	root := m.Components[0]
	if root.Path != "." || root.Language != "go" || len(root.Dockerfiles) != 1 || root.Dockerfiles[0].Context != "." || root.Dockerfiles[0].Line != 6 {
		t.Fatalf("root=%+v", root)
	}
	pf := m.Components[1]
	if pf.Image != "serverkraken/mailstack/postfix" || pf.Context != "." || pf.Platforms != "linux/amd64" || pf.Release == nil || !*pf.Release {
		t.Fatalf("postfix=%+v", pf)
	}
	if c := m.Components[2]; c.Type != "helm" || !c.Unittest {
		t.Fatalf("chart=%+v", c)
	}
	if m.Workflows == nil || m.Workflows.E2E == nil || m.Workflows.E2E.Script != "test/e2e/run.sh" || m.Workflows.E2E.Schedule != "0 3 * * *" {
		t.Fatalf("workflows=%+v", m.Workflows)
	}
	if m.Release == nil || !m.Release.DispatchTrigger {
		t.Fatalf("release=%+v", m.Release)
	}
	if len(m.GitOps) != 2 || m.GitOps[0].Scope[0] != "kubernetes/apps/mailstack/**" || m.GitOps[0].Mode != "renovate" || m.GitOps[1].Mode != "renovate" {
		t.Fatalf("gitops=%+v", m.GitOps)
	}
}

func TestParseManifestRejects(t *testing.T) {
	tests := map[string]struct{ src, want string }{
		"missing schema":     {"components:\n  - path: .\n", "line 1: `schema` is required"},
		"wrong schema":       {"schema: 2\n", "line 1: unsupported schema 2"},
		"unknown top key":    {"schema: 1\nfoo: 1\n", "line 2: unknown key \"foo\""},
		"unknown comp key":   {"schema: 1\ncomponents:\n  - path: .\n    platform: x\n", "line 4: unknown key \"platform\""},
		"empty components":   {"schema: 1\ncomponents: []\n", "line 2: `components` must not be empty"},
		"duplicate path":     {"schema: 1\ncomponents:\n  - path: a\n  - path: a\n", "line 4: duplicate component path \"a\""},
		"path escapes":       {"schema: 1\ncomponents:\n  - path: ../x\n", "line 3: path must stay inside the repository"},
		"absolute dockerfile": {"schema: 1\ncomponents:\n  - path: .\n    dockerfiles:\n      - path: /etc/Dockerfile\n", "line 5: path must stay inside the repository"},
		"bad image":          {"schema: 1\ncomponents:\n  - path: .\n    image: 'Bad Name'\n", "line 4: image must match"},
		"bad language":       {"schema: 1\ncomponents:\n  - path: .\n    language: cobol\n", "line 4: language must be one of"},
		"bad type":           {"schema: 1\ncomponents:\n  - path: .\n    type: kustomize\n", "line 4: type must be one of"},
		"bad bool":           {"schema: 1\ncomponents:\n  - path: .\n    unittest: yes\n", "line 4: expected true or false"},
		"mode push":          {"schema: 1\ngitops:\n  - repo: a/b\n    mode: push\n", "line 4: gitops mode push is not yet supported"},
		"bad mode":           {"schema: 1\ngitops:\n  - repo: a/b\n    mode: manual\n", "line 4: mode must be one of"},
		"bad repo":           {"schema: 1\ngitops:\n  - repo: nope\n", "line 3: repo must be owner/name"},
		"e2e no script":      {"schema: 1\nworkflows:\n  e2e:\n    schedule: \"0 3 * * *\"\n", "line 3: `script` is required"},
		"bad schedule":       {"schema: 1\nworkflows:\n  e2e:\n    script: run.sh\n    schedule: daily\n", "line 5: schedule must be a 5-field cron expression"},
		"scalar where map":   {"schema: 1\nrelease: true\n", "line 2: expected a mapping"},
		"yaml error":         {"schema: 1\n\tx: 1\n", "line 2: tabs"},
		"bad platforms": {"schema: 1\ncomponents:\n  - path: .\n    platforms: linux-amd64\n",
			`line 4: platforms must be a comma-separated list of os/arch[/variant], got "linux-amd64"`},
		"bad platforms trailing comma": {"schema: 1\ncomponents:\n  - path: .\n    platforms: linux/amd64,\n",
			`line 4: platforms must be a comma-separated list of os/arch[/variant], got "linux/amd64,"`},
		"bad dockerfile platforms": {"schema: 1\ncomponents:\n  - path: .\n    dockerfiles:\n      - path: Dockerfile\n        platforms: 'linux/amd64 linux/arm64'\n",
			`line 6: platforms must be a comma-separated list of os/arch[/variant], got "linux/amd64 linux/arm64"`},
		"script escapes repo": {"schema: 1\nworkflows:\n  e2e:\n    script: ../run.sh\n",
			"line 4: path must stay inside the repository"},
		"script bad charset": {"schema: 1\nworkflows:\n  e2e:\n    script: 'run script.sh'\n",
			`line 4: script must be a repo-relative path matching ^[A-Za-z0-9._/-]+$, got "run script.sh"`},
		"schedule punctuation": {"schema: 1\nworkflows:\n  e2e:\n    script: run.sh\n    schedule: \"0 3 * * mon;tue\"\n",
			"line 5: schedule must be a 5-field cron expression"},
		"schedule too few fields": {"schema: 1\nworkflows:\n  e2e:\n    script: run.sh\n    schedule: \"0 3 * *\"\n",
			"line 5: schedule must be a 5-field cron expression"},
		"duplicate package name": {"schema: 1\ncomponents:\n  - path: images/svc\n  - path: charts/svc\n",
			`line 4: component charts/svc: package name "svc" already used by images/svc`},
	}
	for name, tt := range tests {
		t.Run(name, func(t *testing.T) {
			_, err := Parse([]byte(tt.src))
			if err == nil || !strings.Contains(err.Error(), tt.want) || !strings.HasPrefix(err.Error(), FileName+": ") {
				t.Fatalf("err=%v want contains %q", err, tt.want)
			}
		})
	}
}

func TestParseManifestPlatformsAccepted(t *testing.T) {
	for _, p := range []string{"linux/amd64", "linux/amd64,linux/arm64", "linux/arm/v7", "linux/amd64,linux/arm64/v8,windows/amd64"} {
		src := fmt.Sprintf("schema: 1\ncomponents:\n  - path: .\n    platforms: %s\n", p)
		m, err := Parse([]byte(src))
		if err != nil {
			t.Fatalf("platforms=%s: %v", p, err)
		}
		if m.Components[0].Platforms != p {
			t.Fatalf("platforms=%s got %q", p, m.Components[0].Platforms)
		}
	}
}

// The root component's release-please package name is not derived from its
// basename (include-component-in-tag: false), so `.` never participates in the
// non-root basename uniqueness rule.
func TestParseManifestRootBasenameIsNotAPackageName(t *testing.T) {
	src := "schema: 1\ncomponents:\n  - path: .\n  - path: images/api\n  - path: charts/web\n"
	if _, err := Parse([]byte(src)); err != nil {
		t.Fatal(err)
	}
}

func TestParseManifestScriptAccepted(t *testing.T) {
	src := "schema: 1\nworkflows:\n  e2e:\n    script: ./test/e2e/run.sh\n"
	m, err := Parse([]byte(src))
	if err != nil {
		t.Fatal(err)
	}
	if m.Workflows.E2E.Script != "test/e2e/run.sh" {
		t.Fatalf("script=%q want cleaned test/e2e/run.sh", m.Workflows.E2E.Script)
	}
}

func TestLoad(t *testing.T) {
	tmp := t.TempDir()
	if _, _, found, err := Load(tmp); err != nil || found {
		t.Fatalf("found=%v err=%v", found, err)
	}
	if err := os.MkdirAll(filepath.Join(tmp, ".github"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(tmp, FileName), []byte(validManifest), 0o644); err != nil {
		t.Fatal(err)
	}
	m, sum, found, err := Load(tmp)
	if err != nil || !found || m == nil || len(sum) != 64 {
		t.Fatalf("m=%v sum=%q found=%v err=%v", m, sum, found, err)
	}
	if err := os.WriteFile(filepath.Join(tmp, FileName), []byte("schema: 3\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if _, _, _, err := Load(tmp); err == nil {
		t.Fatal("expected validation error")
	}
}

func TestParseManifestOptional(t *testing.T) {
	// Test manifest with only schema and no components
	src := `schema: 1
`
	m, err := Parse([]byte(src))
	if err != nil {
		t.Fatal(err)
	}
	if m.Schema != 1 || m.Components != nil || m.Workflows != nil || m.Release != nil || m.GitOps != nil {
		t.Fatalf("m=%+v", m)
	}
}

func TestParseManifestComponentRelease(t *testing.T) {
	src := `schema: 1
components:
  - path: .
    release: false
`
	m, err := Parse([]byte(src))
	if err != nil {
		t.Fatal(err)
	}
	if m.Components[0].Release == nil || *m.Components[0].Release != false {
		t.Fatalf("release=%v", m.Components[0].Release)
	}
}

func TestParseManifestDockerfileRelease(t *testing.T) {
	src := `schema: 1
components:
  - path: .
    dockerfiles:
      - path: Dockerfile
        release: true
`
	m, err := Parse([]byte(src))
	if err != nil {
		t.Fatal(err)
	}
	if m.Components[0].Dockerfiles[0].Release == nil || !*m.Components[0].Dockerfiles[0].Release {
		t.Fatalf("release=%v", m.Components[0].Dockerfiles[0].Release)
	}
}

func TestParseManifestE2E(t *testing.T) {
	src := `schema: 1
workflows:
  e2e:
    script: run.sh
`
	m, err := Parse([]byte(src))
	if err != nil {
		t.Fatal(err)
	}
	if m.Workflows == nil || m.Workflows.E2E == nil || m.Workflows.E2E.Script != "run.sh" || m.Workflows.E2E.Schedule != "" {
		t.Fatalf("e2e=%+v", m.Workflows.E2E)
	}
}

func TestParseManifestRelease(t *testing.T) {
	src := `schema: 1
release:
  dispatch_trigger: true
`
	m, err := Parse([]byte(src))
	if err != nil {
		t.Fatal(err)
	}
	if m.Release == nil || !m.Release.DispatchTrigger {
		t.Fatalf("release=%+v", m.Release)
	}
}

func TestParseManifestReleaseFalse(t *testing.T) {
	src := `schema: 1
release:
  dispatch_trigger: false
`
	m, err := Parse([]byte(src))
	if err != nil {
		t.Fatal(err)
	}
	if m.Release == nil || m.Release.DispatchTrigger {
		t.Fatalf("release=%+v", m.Release)
	}
}

func TestParseManifestGitOpsNoScope(t *testing.T) {
	src := `schema: 1
gitops:
  - repo: org/repo
`
	m, err := Parse([]byte(src))
	if err != nil {
		t.Fatal(err)
	}
	if len(m.GitOps) != 1 || m.GitOps[0].Repo != "org/repo" || m.GitOps[0].Scope != nil || m.GitOps[0].Mode != "renovate" {
		t.Fatalf("gitops=%+v", m.GitOps[0])
	}
}

func TestParseManifestGitOpsExplicitRenovate(t *testing.T) {
	src := `schema: 1
gitops:
  - repo: org/repo
    mode: renovate
`
	m, err := Parse([]byte(src))
	if err != nil {
		t.Fatal(err)
	}
	if len(m.GitOps) != 1 || m.GitOps[0].Mode != "renovate" {
		t.Fatalf("gitops=%+v", m.GitOps[0])
	}
}

func TestParseManifestComponentFull(t *testing.T) {
	src := `schema: 1
components:
  - path: .
    language: python
    type: helm
    image: myapp
    context: build
    platforms: linux/arm64
    release: true
    unittest: true
    dockerfiles:
      - path: Dockerfile.prod
        image: prod-image
        context: .
        platforms: linux/amd64
        release: false
`
	m, err := Parse([]byte(src))
	if err != nil {
		t.Fatal(err)
	}
	c := m.Components[0]
	if c.Path != "." || c.Language != "python" || c.Type != "helm" || c.Image != "myapp" || c.Context != "build" || c.Platforms != "linux/arm64" {
		t.Fatalf("component=%+v", c)
	}
	if c.Release == nil || !*c.Release || !c.Unittest {
		t.Fatalf("flags=%v %v", c.Release, c.Unittest)
	}
	if len(c.Dockerfiles) != 1 {
		t.Fatalf("dockerfiles=%v", c.Dockerfiles)
	}
	d := c.Dockerfiles[0]
	if d.Path != "Dockerfile.prod" || d.Image != "prod-image" || d.Context != "." || d.Platforms != "linux/amd64" {
		t.Fatalf("dockerfile=%+v", d)
	}
	if d.Release == nil || *d.Release {
		t.Fatalf("release=%v", d.Release)
	}
}

func TestParseManifestCleansRelPaths(t *testing.T) {
	src := `schema: 1
components:
  - path: ./foo/../bar
    context: .
`
	m, err := Parse([]byte(src))
	if err != nil {
		t.Fatal(err)
	}
	if m.Components[0].Path != "bar" {
		t.Fatalf("path=%q want bar", m.Components[0].Path)
	}
}

func TestParseManifestLanguageTypes(t *testing.T) {
	langs := []string{"go", "python", "rust", "helm", "flutter", "node", "generic"}
	for _, lang := range langs {
		src := fmt.Sprintf("schema: 1\ncomponents:\n  - path: .\n    language: %s\n", lang)
		m, err := Parse([]byte(src))
		if err != nil {
			t.Fatalf("lang=%s: %v", lang, err)
		}
		if m.Components[0].Language != lang {
			t.Fatalf("lang=%s got %s", lang, m.Components[0].Language)
		}
	}
}

func TestParseManifestMultipleGitOps(t *testing.T) {
	src := `schema: 1
gitops:
  - repo: org1/repo1
    scope: [path1/**, path2/**]
  - repo: org2/repo2
    mode: renovate
  - repo: org3/repo3
    scope: [single/path]
    mode: renovate
`
	m, err := Parse([]byte(src))
	if err != nil {
		t.Fatal(err)
	}
	if len(m.GitOps) != 3 {
		t.Fatalf("count=%d", len(m.GitOps))
	}
	if len(m.GitOps[0].Scope) != 2 || m.GitOps[0].Scope[0] != "path1/**" {
		t.Fatalf("scope=%v", m.GitOps[0].Scope)
	}
	if len(m.GitOps[2].Scope) != 1 {
		t.Fatalf("scope=%v", m.GitOps[2].Scope)
	}
}

func TestParseManifestMultipleDockerfiles(t *testing.T) {
	src := `schema: 1
components:
  - path: .
    dockerfiles:
      - path: Dockerfile.dev
        image: dev-image
      - path: Dockerfile.prod
        image: prod-image
        context: build
        platforms: linux/amd64,linux/arm64
`
	m, err := Parse([]byte(src))
	if err != nil {
		t.Fatal(err)
	}
	if len(m.Components[0].Dockerfiles) != 2 {
		t.Fatalf("count=%d", len(m.Components[0].Dockerfiles))
	}
	if m.Components[0].Dockerfiles[1].Image != "prod-image" {
		t.Fatalf("image=%s", m.Components[0].Dockerfiles[1].Image)
	}
}

func TestParseManifestEdgeCases(t *testing.T) {
	// Test component without image (all optional fields)
	src := `schema: 1
components:
  - path: libs/shared
`
	m, err := Parse([]byte(src))
	if err != nil {
		t.Fatal(err)
	}
	c := m.Components[0]
	if c.Path != "libs/shared" || c.Language != "" || c.Image != "" || c.Context != "" || c.Type != "" || c.Platforms != "" {
		t.Fatalf("component=%+v", c)
	}
	if c.Release != nil || c.Unittest {
		t.Fatalf("flags=%v %v", c.Release, c.Unittest)
	}
	if len(c.Dockerfiles) != 0 {
		t.Fatalf("dockerfiles=%v", c.Dockerfiles)
	}
}

func TestParseManifestComponentPathOnlyNoDockerfiles(t *testing.T) {
	src := `schema: 1
components:
  - path: api
  - path: web
    language: node
`
	m, err := Parse([]byte(src))
	if err != nil {
		t.Fatal(err)
	}
	if len(m.Components) != 2 {
		t.Fatalf("count=%d", len(m.Components))
	}
	if m.Components[0].Path != "api" || m.Components[0].Language != "" {
		t.Fatalf("c0=%+v", m.Components[0])
	}
	if m.Components[1].Path != "web" || m.Components[1].Language != "node" {
		t.Fatalf("c1=%+v", m.Components[1])
	}
}

func TestParseManifestInvalidError(t *testing.T) {
	tests := []struct {
		name string
		src  string
	}{
		{"dockerfile not list", "schema: 1\ncomponents:\n  - path: .\n    dockerfiles: single\n"},
		{"scope not list", "schema: 1\ngitops:\n  - repo: a/b\n    scope: single\n"},
		{"workflows not map", "schema: 1\nworkflows: notmap\n"},
		{"gitops not list", "schema: 1\ngitops: single\n"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			_, err := Parse([]byte(tt.src))
			if err == nil {
				t.Fatal("expected error")
			}
			if !strings.HasPrefix(err.Error(), FileName+": ") {
				t.Fatalf("prefix error=%v", err)
			}
		})
	}
}

func TestParseManifestDockerfileMissingPath(t *testing.T) {
	src := `schema: 1
components:
  - path: .
    dockerfiles:
      - image: myimage
`
	_, err := Parse([]byte(src))
	if err == nil || !strings.Contains(err.Error(), "`path` is required") {
		t.Fatalf("err=%v", err)
	}
}

func TestParseManifestComponentMissingPath(t *testing.T) {
	src := `schema: 1
components:
  - language: go
`
	_, err := Parse([]byte(src))
	if err == nil || !strings.Contains(err.Error(), "`path` is required") {
		t.Fatalf("err=%v", err)
	}
}

func TestParseManifestGitOpsMissingRepo(t *testing.T) {
	src := `schema: 1
gitops:
  - scope: [path]
`
	_, err := Parse([]byte(src))
	if err == nil || !strings.Contains(err.Error(), "`repo` is required") {
		t.Fatalf("err=%v", err)
	}
}

func TestParseManifestComponentPathNestedDir(t *testing.T) {
	src := `schema: 1
components:
  - path: internal/lib/core
    language: rust
`
	m, err := Parse([]byte(src))
	if err != nil {
		t.Fatal(err)
	}
	if m.Components[0].Path != "internal/lib/core" {
		t.Fatalf("path=%q", m.Components[0].Path)
	}
}

func TestParseManifestSchemaNotInt(t *testing.T) {
	src := `schema: notanint
`
	_, err := Parse([]byte(src))
	if err == nil || !strings.Contains(err.Error(), "expected an integer") {
		t.Fatalf("err=%v", err)
	}
}

func TestParseManifestComponentString(t *testing.T) {
	src := `schema: 1
components: notalist
`
	_, err := Parse([]byte(src))
	if err == nil || !strings.Contains(err.Error(), "expected a list") {
		t.Fatalf("err=%v", err)
	}
}

func TestParseManifestReleaseBadges(t *testing.T) {
	m, err := Parse([]byte("schema: 1\nrelease:\n  badges: true\n"))
	if err != nil {
		t.Fatal(err)
	}
	if m.Release == nil || !m.Release.Badges || m.Release.DispatchTrigger {
		t.Fatalf("release=%+v", m.Release)
	}
	if _, err := Parse([]byte("schema: 1\nrelease:\n  badges: yes\n")); err == nil || !strings.Contains(err.Error(), "line 3: expected true or false") {
		t.Fatalf("err=%v", err)
	}
}

// Scan options exist because an image that vendors third-party manifests
// cannot pass the atom's default scanner set: wartung's ansible image ships
// the kubernetes ansible collection, whose example manifests produce 41
// unfixable HIGH misconfig findings.
func TestParseManifestScanOptions(t *testing.T) {
	src := `schema: 1
components:
  - path: ansible
    image: acme/ansible
    context: .
    scanners: vuln,secret
    upload_sarif: false
  - path: worker
    dockerfiles:
      - path: Dockerfile
        image: acme/worker
        scanners: vuln,secret,misconfig,license
        upload_sarif: true
`
	m, err := Parse([]byte(src))
	if err != nil {
		t.Fatal(err)
	}
	c := m.Components[0]
	if c.Scanners != "vuln,secret" {
		t.Fatalf("component scanners=%q", c.Scanners)
	}
	if c.UploadSARIF == nil || *c.UploadSARIF {
		t.Fatalf("component upload_sarif=%v", c.UploadSARIF)
	}
	d := m.Components[1].Dockerfiles[0]
	if d.Scanners != "vuln,secret,misconfig,license" {
		t.Fatalf("dockerfile scanners=%q", d.Scanners)
	}
	if d.UploadSARIF == nil || !*d.UploadSARIF {
		t.Fatalf("dockerfile upload_sarif=%v", d.UploadSARIF)
	}
}

// Unset must stay distinguishable from false: the templates emit the input
// only when the key is present, so an omitted upload_sarif keeps every
// existing adopter's render byte-identical.
func TestParseManifestScanOptionsUnset(t *testing.T) {
	m, err := Parse([]byte("schema: 1\ncomponents:\n  - path: .\n    image: acme/app\n"))
	if err != nil {
		t.Fatal(err)
	}
	if c := m.Components[0]; c.Scanners != "" || c.UploadSARIF != nil {
		t.Fatalf("expected unset, got scanners=%q upload_sarif=%v", c.Scanners, c.UploadSARIF)
	}
}

func TestParseManifestScannersRejected(t *testing.T) {
	cases := map[string]string{
		"unknown scanner": "schema: 1\ncomponents:\n  - path: .\n    scanners: vuln,rootkit\n",
		"duplicate":       "schema: 1\ncomponents:\n  - path: .\n    scanners: vuln,vuln\n",
		"trailing comma":  "schema: 1\ncomponents:\n  - path: .\n    scanners: vuln,\n",
		"spaced":          "schema: 1\ncomponents:\n  - path: .\n    scanners: 'vuln, secret'\n",
	}
	for name, src := range cases {
		t.Run(name, func(t *testing.T) {
			if _, err := Parse([]byte(src)); err == nil {
				t.Fatal("expected an error")
			}
		})
	}
}
