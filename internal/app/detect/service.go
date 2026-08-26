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
	"strconv"
	"strings"

	"github.com/serverkraken/reusable-workflows/internal/domain"
	"github.com/serverkraken/reusable-workflows/internal/manifest"
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
	var releaseTags []string
	if req.TargetRepo != "" {
		if b, err := gh.DefaultBranch(ctx, req.TargetRepo); err != nil {
			return Result{}, fmt.Errorf("repo not accessible: %s", req.TargetRepo)
		} else if b != "" {
			branch = b
		}
		// `err == nil &&` liess einen API-Fehler wie "das Repo hat keine
		// Releases" aussehen (Audit C-4, C-5). Aus `version` wird
		// `.release-please-manifest.json` geseedet: ein Repo auf 1.10.0, dessen
		// Abfrage an einem Rate-Limit scheitert, haette dort 0.0.0 bekommen und
		// beim naechsten Release rueckwaerts versioniert.
		//
		// Ein Repo OHNE Releases ist etwas anderes und bleibt gueltig: die API
		// antwortet dann erfolgreich mit einer leeren Liste. Der Bash-Pfad
		// unterscheidet inzwischen genauso (H-5) - beide Engines muessen bei
		// derselben Frage dieselbe Antwort geben.
		t, err := gh.ReleaseTags(ctx, req.TargetRepo)
		if err != nil {
			return Result{}, fmt.Errorf("could not list releases for %s: %w", req.TargetRepo, err)
		}
		releaseTags = t

		// The root version must come from a ROOT tag. `gh release list` is
		// ordered by date, so in a monorepo its newest entry is whatever
		// component released last (`ansible-v2.6.0`) — seeding from that wrote
		// a tag name where a version belongs, for every package at once.
		if v := latestRootVersion(releaseTags); v != "" {
			version = v
		} else {
			v, err := gh.LatestStableRelease(ctx, req.TargetRepo)
			if err != nil {
				return Result{}, fmt.Errorf("could not read the latest release of %s: %w", req.TargetRepo, err)
			}
			if v != "" && rootTagRe.MatchString("v"+strings.TrimPrefix(v, "v")) {
				version = strings.TrimPrefix(v, "v")
			}
		}

		// Topics steuern Opt-ins, allen voran `sk-prerelease-on-push`. Ein
		// verschluckter Fehler hiess "keine Topics" und damit "das Opt-in gilt
		// nicht" — der Adopter haette prerelease-on-push.yml still verloren.
		tp, err := gh.Topics(ctx, req.TargetRepo)
		if err != nil {
			return Result{}, fmt.Errorf("could not read topics for %s: %w", req.TargetRepo, err)
		}
		topics = tp
	}

	man, manifestSHA, hasManifest, err := manifest.Load(req.RepoPath)
	if err != nil {
		return Result{}, err
	}
	manifestComponents := hasManifest && man.Components != nil
	fe := &fsErrors{}
	var components []domain.Component
	if manifestComponents {
		components, err = componentsFromManifest(req.RepoPath, man, fe)
	} else {
		components, err = detectComponents(req.RepoPath, fe)
	}
	if err != nil {
		return Result{}, err
	}
	// Seed each non-root component from its own `<package>-vX.Y.Z` tags. The
	// manifest template falls back to current_version, which is the ROOT
	// version — without this a re-onboard would drag every component up to it
	// and jump their next releases forward. A helm component keeps the version
	// release-please already wrote into its Chart.yaml.
	for i := range components {
		if components[i].Path == "." || components[i].Version != "" {
			continue
		}
		if v := latestComponentVersion(releaseTags, filepath.Base(components[i].Path)); v != "" {
			components[i].Version = v
		}
	}
	// Sobald die Komponenten stehen und bevor irgendetwas daraus gerendert
	// wird: zwei Dockerfiles duerfen nicht denselben Image-Namen tragen.
	if err := checkImageNameCollisions(components); err != nil {
		return Result{}, err
	}
	if err := checkPackageNameCollisions(components); err != nil {
		return Result{}, err
	}

	var declared []string
	// Workflows the adopter maintains itself are not legacy: the scan would
	// otherwise propose deleting them, and its signatures produce false
	// positives (a hand-written quality gate containing `go test -race` reads
	// as "replaced by test-go.yml" even when it also runs ansible-lint,
	// shellcheck and a test suite the catalog has no atom for).
	if man != nil && man.Workflows != nil {
		declared = append(declared, man.Workflows.Keep...)
	}
	if hasManifest && man.Workflows != nil && man.Workflows.E2E != nil {
		declared = append(declared, "e2e.yml")
	}
	var gitops *domain.GitOpsSignal
	if !manifestComponents {
		gitops = classifyGitOps(req.RepoPath, components)
	}
	if gitops != nil {
		components[0].PrimaryLanguage = "gitops"
		components[0].ReleasePleaseType = "simple"
		components[0].Role = "gitops"
	}
	legacy, err := detectLegacyCI(req.RepoPath, declared)
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
	if hasManifest {
		profile.ManifestSHA256 = manifestSHA
		if man.Workflows != nil && man.Workflows.E2E != nil {
			profile.Workflows = &domain.WorkflowsSpec{E2E: &domain.E2ESpec{Script: man.Workflows.E2E.Script, Schedule: man.Workflows.E2E.Schedule}}
		}
		if man.Release != nil {
			profile.Release = &domain.ReleaseSpec{DispatchTrigger: man.Release.DispatchTrigger, Badges: man.Release.Badges}
			if cp := man.Release.ChartPins; cp != nil {
				profile.Release.ChartPins = &domain.ChartPinsSpec{Values: cp.Values, Key: cp.Key}
			}
		}
		for _, c := range man.GitOps {
			profile.Consumers = append(profile.Consumers, domain.GitOpsConsumer{Repo: c.Repo, Scope: c.Scope, Mode: c.Mode})
		}
	}
	// Zuerst die Dateisystemfehler: wenn ein Verzeichnis nicht gelesen werden
	// konnte, sind alle folgenden Aussagen ueber das Repo unter Vorbehalt.
	profile.Warnings = append(profile.Warnings, fe.seen...)
	profile.Warnings = append(profile.Warnings, unsupportedLanguageWarnings(profile.Components, manifestComponents)...)
	profile.Warnings = append(profile.Warnings, noReleaseEligibleWarnings(profile.Components)...)
	if !hasManifest {
		profile.Warnings = append(profile.Warnings, unassignedSubdirDockerfileWarnings(req.RepoPath, profile.Components, fe)...)
	}

	// `--language-override` muss das PROFIL erreichen, nicht nur die
	// Legacy-Zeilen (Audit B-4).
	//
	// Der Eingang ist beschrieben als "auto = detect, otherwise force
	// release-type". Gemessen an einem go-Repo mit `--language-override python`:
	//
	//	Legacy   language=python  release_type=python
	//	Profil   primary_language=go  release_please_type=go
	//
	// Gerendert wird aus dem PROFIL: release-please-config.json trug weiter
	// `"release-type": "go"`. Der Schalter war fuer alles, was der Adopter
	// hinterher sieht, ein stiller Leerlauf.
	//
	// Bewusst nur release_please_type, nicht primary_language: der Eingang
	// verspricht den Release-Typ. Wuerde er auch die Sprachwahl erzwingen,
	// rendere ein erzwungenes `python` auf einem reinen Go-Repo Python-Jobs
	// gegen ein Repo ohne pyproject.toml - CI, die sofort scheitert. Ein
	// Versprechen einloesen, keins dazuerfinden.
	//
	// Nur die Wurzelkomponente, dieselbe Begruendung wie bei
	// manifestRootLanguage: ein repo-weiter Einzelwert kann sinnvoll nur die
	// Wurzel meinen. Trifft er keine, sagt eine Warnung das - sonst waere der
	// Schalter im Monorepo wieder stumm wirkungslos, also genau der Fehler,
	// den dieser Fix behebt.
	if ov := strings.TrimSpace(req.LanguageOverride); ov != "" && ov != "auto" {
		applied := false
		for i := range profile.Components {
			if profile.Components[i].Path == "." {
				profile.Components[i].ReleasePleaseType = releasePleaseType(ov)
				applied = true
			}
		}
		if !applied {
			profile.Warnings = append(profile.Warnings, domain.Warning{
				Code: "language_override_not_applied",
				Path: ".",
				Message: fmt.Sprintf("language override %q was not applied: this repo has no root component, "+
					"and a repo-wide release type cannot be assigned to sub-components; declare release types "+
					"per component in .github/onboard.yml instead", ov),
			})
		}
	}

	// Das Manifest schlaegt die Wurzelsignale. Ohne diesen Vorrang war die
	// Mehrdeutigkeits-Absage fuer den Adopter UNENTRINNBAR, gemessen:
	//
	//	go.mod + pyproject.toml im Wurzelverzeichnis,
	//	.github/onboard.yml mit `components: [{path: ., language: python}]`
	//	-> "ambiguous language signals: go python; rerun with explicit
	//	    language input"
	//
	// Der Adopter hat genau das getan, wozu die Meldung raet - im dokumentierten
	// Feld `components[].language` - und wurde trotzdem abgewiesen. legacyLanguage
	// leitet aus den Wurzelsignalen ab und sah das Manifest nie.
	//
	// Dazu kommt: an dieser Stelle ist das PROFIL laengst fertig gebaut. Der
	// Abbruch warf es weg wegen eines Feldes, das nur die Legacy-Ausgabe
	// (`language=`/`release_type=`) braucht und das der Profilpfad nicht nutzt.
	lang := req.LanguageOverride
	if lang == "" || lang == "auto" {
		if declared := manifestRootLanguage(man, manifestComponents); declared != "" {
			lang = declared
		}
	}
	legacyLanguage, err := legacyLanguage(req.RepoPath, lang)
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

// manifestRootLanguage liefert die im Manifest fuer die Wurzelkomponente
// deklarierte Sprache, sonst "".
//
// Nur die Wurzel: `language=`/`release_type=` sind Repo-weite Legacy-Felder mit
// genau einem Wert. Die Sprache einer Unterkomponente dafuer zu nehmen waere
// geraten - und Raten ist genau das, was hier abgestellt wird.
func manifestRootLanguage(man *manifest.Manifest, manifestComponents bool) string {
	if !manifestComponents || man == nil {
		return ""
	}
	for _, c := range man.Components {
		if c.Path == "." && c.Language != "" {
			return c.Language
		}
	}
	return ""
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

func detectComponents(repo string, fe *fsErrors) ([]domain.Component, error) {
	paths := explicitMonorepoPaths(repo)
	rootHasMarker := hasAny(repo, "go.mod", "pyproject.toml", "Cargo.toml", "Chart.yaml", "Dockerfile", "Containerfile", "package.json", "pubspec.yaml")
	if len(paths) == 0 && !rootHasMarker {
		paths = fallbackMarkerPaths(repo, fe)
	}
	if len(paths) == 0 && !rootHasMarker {
		paths = fallbackDockerfilePaths(repo, fe)
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
		dockerfiles := inventoryDockerfiles(repo, p, "", fe)
		if dockerfiles == nil {
			dockerfiles = []domain.Dockerfile{}
		}
		components = append(components, domain.Component{
			Path:              p,
			Languages:         langs,
			PrimaryLanguage:   primary,
			ReleasePleaseType: releasePleaseType(primary),
			Role:              role(repo, p, dockerfiles, fe),
			Dockerfiles:       dockerfiles,
			ReleaseSignals:    releaseSignals(repo, p),
			CGO:               detectCGO(repo, p, primary, fe),
		})
	}
	return components, nil
}

// componentsFromManifest builds the component list from an authoritative
// manifest. Per component, anything the manifest leaves out is detected the
// same way detectComponents would (languages, Dockerfiles in the component
// directory, release signals, cgo).
func componentsFromManifest(repo string, m *manifest.Manifest, fe *fsErrors) ([]domain.Component, error) {
	paths := map[string]bool{}
	for _, mc := range m.Components {
		paths[mc.Path] = true
	}
	out := make([]domain.Component, 0, len(m.Components))
	// owner maps a repo-relative Dockerfile path to the component that already
	// claimed it — either through its own-directory inventory or through an
	// explicit dockerfiles[] entry. Two components building the same file would
	// push two images from one build context.
	owner := map[string]string{}
	for _, mc := range m.Components {
		dir := filepath.Join(repo, mc.Path)
		if !dirExists(dir) {
			return nil, fmt.Errorf("%s: line %d: component path %s does not exist", manifest.FileName, mc.Line, mc.Path)
		}
		langs := languagesAt(dir)
		if mc.Language != "" {
			langs = append([]string{mc.Language}, without(langs, mc.Language)...)
		}
		if mc.Type == "helm" {
			langs = append([]string{"helm"}, without(langs, "helm")...)
		}
		if langs == nil {
			langs = []string{}
		}
		primary := "generic"
		if len(langs) > 0 {
			primary = langs[0]
		}

		dockerfiles := inventoryDockerfiles(repo, mc.Path, mc.Image, fe)
		mcOverrides := imageOverrides{
			context: mc.Context, platforms: mc.Platforms, scanners: mc.Scanners, severity: mc.Severity,
			uploadSARIF: mc.UploadSARIF, failOnFindings: mc.FailOnFindings, release: mc.Release,
		}
		if mc.Image != "" || mcOverrides.set() {
			// The shorthand always targets the single Dockerfile in the
			// component's own directory. When dockerfiles[] is already carrying
			// the images, pointing at it as the fix is misleading — the real
			// problem is that there is no own-directory file to apply it to.
			if len(dockerfiles) == 0 && len(mc.Dockerfiles) > 0 {
				return nil, fmt.Errorf("%s: line %d: component %s has no Dockerfile in its directory; the shorthand fields apply to that file only", manifest.FileName, mc.Line, mc.Path)
			}
			if len(dockerfiles) != 1 {
				return nil, fmt.Errorf("%s: line %d: component %s declares image/context/platforms/release but has %d Dockerfiles; use dockerfiles[] instead", manifest.FileName, mc.Line, mc.Path, len(dockerfiles))
			}
			applyDockerfileSpec(&dockerfiles[0], mcOverrides)
		}
		seen := map[string]bool{}
		for _, d := range dockerfiles {
			seen[d.Path] = true
		}
		for _, spec := range mc.Dockerfiles {
			full := filepath.Join(repo, spec.Path)
			if !has(filepath.Dir(full), filepath.Base(full)) {
				return nil, fmt.Errorf("%s: line %d: %s: no such file", manifest.FileName, spec.Line, spec.Path)
			}
			rel, err := filepath.Rel(mc.Path, spec.Path)
			if err != nil || rel == ".." || strings.HasPrefix(rel, "../") {
				return nil, fmt.Errorf("%s: line %d: %s is outside component %s", manifest.FileName, spec.Line, spec.Path, mc.Path)
			}
			relSlash := filepath.ToSlash(rel)
			if seen[relSlash] {
				return nil, fmt.Errorf("%s: line %d: %s is already inventoried from the component directory; use the component-level image/context/platforms/release shorthand instead", manifest.FileName, spec.Line, spec.Path)
			}
			seen[relSlash] = true
			df := resolveDockerfile(full, filepath.Base(spec.Path), filepath.ToSlash(filepath.Dir(spec.Path)), spec.Image)
			df.Path = relSlash
			applyDockerfileSpec(&df, imageOverrides{
				context: spec.Context, platforms: spec.Platforms, scanners: spec.Scanners, severity: spec.Severity,
				uploadSARIF: spec.UploadSARIF, failOnFindings: spec.FailOnFindings, release: spec.Release,
			})
			dockerfiles = append(dockerfiles, df)
		}
		sort.Slice(dockerfiles, func(i, j int) bool { return dockerfiles[i].Path < dockerfiles[j].Path })
		if ctx, ok := sharedContext(mc.Path, dockerfiles); !ok {
			return nil, fmt.Errorf("%s: line %d: Dockerfiles of component %s must share one build context (docker-build-multi has a single context), got %s", manifest.FileName, mc.Line, mc.Path, ctx)
		}
		if pf, ok := sharedPlatforms(dockerfiles); !ok {
			return nil, fmt.Errorf("%s: line %d: Dockerfiles of component %s must share one platforms value (docker-build-multi has a single platforms), got %s", manifest.FileName, mc.Line, mc.Path, pf)
		}
		for _, d := range dockerfiles {
			rel := d.Path
			if mc.Path != "." {
				rel = filepath.ToSlash(filepath.Join(mc.Path, d.Path))
			}
			if prev, dup := owner[rel]; dup {
				return nil, fmt.Errorf("%s: line %d: Dockerfile %s is claimed by both component %s and component %s", manifest.FileName, mc.Line, rel, prev, mc.Path)
			}
			owner[rel] = mc.Path
		}

		signals := releaseSignals(repo, mc.Path)
		if signals.ChartYAML != nil && paths[filepath.ToSlash(filepath.Dir(*signals.ChartYAML))] {
			signals.ChartYAML = nil // the chart is its own component
		}
		c := domain.Component{
			Path:              mc.Path,
			Languages:         langs,
			PrimaryLanguage:   primary,
			ReleasePleaseType: releasePleaseType(primary),
			Role:              role(repo, mc.Path, dockerfiles, fe),
			Dockerfiles:       dockerfiles,
			ReleaseSignals:    signals,
			CGO:               detectCGO(repo, mc.Path, primary, fe),
			Unittest:          mc.Unittest,
			AppVersion:        mc.AppVersion,
		}
		if primary == "helm" {
			c.Version = chartVersion(filepath.Join(dir, "Chart.yaml"))
		}
		out = append(out, c)
	}
	return out, nil
}

// imageOverrides carries the per-image manifest fields that the component
// shorthand and dockerfiles[] both accept. A struct rather than a row of
// positional arguments: they are nearly all strings, so a new key added in the
// wrong slot would compile and silently configure something else.
type imageOverrides struct {
	context, platforms, scanners, severity string
	uploadSARIF, failOnFindings, release   *bool
}

func (o imageOverrides) set() bool {
	return o.context != "" || o.platforms != "" || o.scanners != "" || o.severity != "" ||
		o.uploadSARIF != nil || o.failOnFindings != nil || o.release != nil
}

func applyDockerfileSpec(df *domain.Dockerfile, o imageOverrides) {
	if o.context != "" {
		df.Context = o.context
	}
	if o.platforms != "" {
		df.Platforms = o.platforms
	}
	if o.scanners != "" {
		df.Scanners = o.scanners
	}
	if o.severity != "" {
		df.Severity = o.severity
	}
	if o.uploadSARIF != nil {
		df.UploadSARIF = o.uploadSARIF
	}
	if o.failOnFindings != nil {
		df.FailOnFindings = o.failOnFindings
	}
	if o.release != nil {
		df.ReleaseEligible = *o.release
	}
}

// sharedContext returns the effective build context of a component's
// Dockerfiles and whether they all agree. Empty Context means the component
// path.
func sharedContext(componentPath string, dfs []domain.Dockerfile) (string, bool) {
	effective := func(d domain.Dockerfile) string {
		if d.Context != "" {
			return d.Context
		}
		return componentPath
	}
	if len(dfs) == 0 {
		return componentPath, true
	}
	first := effective(dfs[0])
	for _, d := range dfs[1:] {
		if effective(d) != first {
			return first + " vs " + effective(d), false
		}
	}
	return first, true
}

var (
	// rootTagRe matches a root release tag: `v1.2.3`, no component prefix.
	rootTagRe = regexp.MustCompile(`^v[0-9]+\.[0-9]+\.[0-9]+$`)
	// componentTagRe splits `<package>-v1.2.3` into package and version.
	componentTagRe = regexp.MustCompile(`^(.+)-v([0-9]+\.[0-9]+\.[0-9]+)$`)
)

// latestRootVersion returns the highest root release version (no leading `v`),
// ignoring per-component tags and the floating `v1`/`v1.2` aliases.
func latestRootVersion(tags []string) string {
	best := ""
	for _, t := range tags {
		if rootTagRe.MatchString(t) {
			best = higherVersion(best, strings.TrimPrefix(t, "v"))
		}
	}
	return best
}

// higherVersion compares two dotted triples numerically and returns the larger.
// Sorting matters because the tag listing has no meaningful order — and string
// comparison would rank 2.10.0 below 2.9.0.
func higherVersion(a, b string) string {
	if a == "" {
		return b
	}
	if b == "" {
		return a
	}
	pa, pb := strings.Split(a, "."), strings.Split(b, ".")
	for i := 0; i < 3; i++ {
		x, _ := strconv.Atoi(pa[i])
		y, _ := strconv.Atoi(pb[i])
		if x != y {
			if x > y {
				return a
			}
			return b
		}
	}
	return a
}

// latestComponentVersion returns the newest release version of one package,
// read from its `<package>-vX.Y.Z` tags. Without it a re-onboard would seed
// every component from the ROOT version and silently jump their next releases
// forward — mailstack's postfix would go from 1.6.7 to the root's 1.7.0.
func latestComponentVersion(tags []string, packageName string) string {
	best := ""
	for _, t := range tags {
		if m := componentTagRe.FindStringSubmatch(t); m != nil && m[1] == packageName {
			best = higherVersion(best, m[2])
		}
	}
	return best
}

// sharedPlatforms returns the effective platforms list of a component's
// Dockerfiles and whether they all agree. Empty means "the atom's default", so
// mixing an explicit list with an implicit default is a mismatch too —
// docker-build-multi forwards one platforms value to every image it builds.
func sharedPlatforms(dfs []domain.Dockerfile) (string, bool) {
	if len(dfs) == 0 {
		return "", true
	}
	first := dfs[0].Platforms
	for _, d := range dfs[1:] {
		if d.Platforms != first {
			return displayPlatforms(first) + " vs " + displayPlatforms(d.Platforms), false
		}
	}
	return first, true
}

func displayPlatforms(p string) string {
	if p == "" {
		return "(atom default)"
	}
	return p
}

// chartVersion reads `version:` from a Chart.yaml; empty when absent.
func chartVersion(path string) string {
	for _, l := range strings.Split(mustRead(path), "\n") {
		l = strings.TrimSpace(l)
		if !strings.HasPrefix(l, "version:") {
			continue
		}
		v := strings.TrimSpace(strings.TrimPrefix(l, "version:"))
		if i := strings.Index(v, " #"); i >= 0 {
			v = strings.TrimSpace(v[:i])
		}
		return strings.Trim(v, `"'`)
	}
	return ""
}

func without(list []string, v string) []string {
	var out []string
	for _, x := range list {
		if x != v {
			out = append(out, x)
		}
	}
	return out
}

func explicitMonorepoPaths(repo string) []string {
	if has(repo, "go.work") {
		// Auch hier eingrenzen (Audit B-11): ein `use ../nachbar` zeigte aus
		// dem Checkout heraus und wurde woertlich zur Komponente. Beim
		// Cargo-Fix (#308) hatte ich das im PR-Text als miterledigt bezeichnet
		// - es war es nicht, `parseGoWork` blieb unangetastet. Nachgemessen:
		// beide Engines lieferten `["../nachbar"]`.
		return expandWorkspacePatterns(repo, parseGoWork(mustRead(filepath.Join(repo, "go.work"))))
	}
	if has(repo, "Cargo.toml") && strings.Contains(mustRead(filepath.Join(repo, "Cargo.toml")), "[workspace]") {
		return expandWorkspacePatterns(repo, parseCargoWorkspace(mustRead(filepath.Join(repo, "Cargo.toml"))))
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

// expandWorkspacePatterns loest Workspace-Muster gegen das Repo auf und laesst
// nur Verzeichnisse INNERHALB des Repos durch.
//
// Zwei Funde in einer Funktion:
//
//	B-8/H-8: Cargo-Member wurden woertlich uebernommen. `members = ["crates/*"]`
//	ergab eine Komponente mit dem Pfad `crates/*` — ein Verzeichnis, das es
//	nicht gibt. Die echten Crates bekamen dadurch KEINE Jobs: kein Lint, kein
//	Test, kein Scan. `crates/*` ist das uebliche Cargo-Layout. In beiden
//	Engines nachgestellt; der pnpm-Zweig direkt daneben expandierte laengst.
//
//	B-11/H-7: ein Member-Pfad kann aus dem Checkout herausfuehren
//	(`../nachbar`). Was danach als Komponente gilt, wuerde ausserhalb des
//	ausgecheckten Repos gesucht — und die gerenderten Workflows trugen einen
//	`working_directory`, der beim Adopter woanders hinzeigt.
func expandWorkspacePatterns(repo string, patterns []string) []string {
	var out []string
	for _, pat := range patterns {
		matches, err := filepath.Glob(filepath.Join(repo, pat))
		if err != nil {
			// Ein ungueltiges Muster ist kein Treffer, aber auch kein Grund,
			// die Erkennung abzubrechen.
			continue
		}
		sort.Strings(matches)
		for _, m := range matches {
			st, err := os.Stat(m)
			if err != nil || !st.IsDir() {
				continue
			}
			rel, err := filepath.Rel(repo, m)
			if err != nil || rel == ".." || strings.HasPrefix(rel, ".."+string(filepath.Separator)) {
				continue
			}
			out = append(out, filepath.ToSlash(rel))
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
	return expandWorkspacePatterns(repo, patterns)
}

// fsErrors sammelt Dateisystemfehler, die waehrend der Erkennung auftreten.
//
// Vorher wurden sie an drei Stellen zweifach verworfen (Audit B-6, B-10): der
// WalkDirFunc gab bei `err != nil` einfach `nil` zurueck, und der Rueckgabewert
// von WalkDir landete in `_`. Gemessen an einem Repo mit zwei Go-Komponenten,
// von denen eine per `chmod 000` unlesbar war:
//
//	lesbar:            ["services/api", "services/worker"]
//	worker unlesbar:   ["services/api"]        warnings: []   rc=0
//
// Die Komponente verschwand also lautlos aus dem Profil, und die gerenderten
// Workflows haetten fuer sie keinen einzigen Job gehabt - kein Lint, kein Test,
// kein Scan. Dasselbe fuer Dockerfiles: eine unlesbare Komponente ergab
// `dockerfiles: []`, das Image waere nie gebaut und nie gescannt worden.
//
// Gesammelt statt abgebrochen: ein einzelnes unlesbares Verzeichnis (etwa ein
// root-eigenes Artefaktverzeichnis auf einem self-hosted Runner) soll das
// Onboarding nicht unmoeglich machen. Es soll nur nicht unsichtbar sein. Die
// Warnungen erscheinen im Onboarding-PR-Body, wo ein Mensch sie sieht.
type fsErrors struct {
	seen []domain.Warning
	// Mehrere Walker laufen ueber dieselben Verzeichnisse; ohne Entdopplung
	// erscheint derselbe Pfad mehrfach in den Warnungen und das Signal geht im
	// Rauschen unter. Gemessen: ein unlesbares `cmd/` ergab zwei identische
	// Eintraege.
	byPath map[string]bool
}

func (e *fsErrors) note(repo, path string, err error) {
	if e == nil || err == nil {
		return
	}
	// "Existiert nicht" ist an mehreren Aufrufstellen der NORMALFALL - ein
	// Repo ohne `cmd/` etwa. Nur Fehler melden, die tatsaechlich bedeuten,
	// dass etwas da ist, aber nicht gelesen werden konnte.
	if errors.Is(err, fs.ErrNotExist) {
		return
	}
	rel, rerr := filepath.Rel(repo, path)
	if rerr != nil || strings.HasPrefix(rel, "..") {
		rel = path
	}
	slash := filepath.ToSlash(rel)
	if e.byPath == nil {
		e.byPath = map[string]bool{}
	}
	if e.byPath[slash] {
		return
	}
	e.byPath[slash] = true
	e.seen = append(e.seen, domain.Warning{
		Code:    "path_unreadable",
		Path:    slash,
		Message: "could not be read during detection, so anything below it is missing from this profile: " + err.Error(),
	})
}

// skipHidden is the shared WalkDirFunc preamble for every repo walker: it
// prunes dot-directories (`.git/`, `.worktrees/`, `.venv/`, editor caches, …)
// so a nested checkout or build tree can never contribute a component, a chart
// signal, or an orphan-Dockerfile warning. `root` itself is never pruned — the
// repo path may legitimately live under a dot-directory.
func skipHidden(root, path string, d fs.DirEntry) error {
	if !d.IsDir() || path == root {
		return nil
	}
	if strings.HasPrefix(d.Name(), ".") {
		return fs.SkipDir
	}
	return nil
}

func fallbackMarkerPaths(repo string, fe *fsErrors) []string {
	var out []string
	if err := filepath.WalkDir(repo, func(path string, d fs.DirEntry, err error) error {
		if err != nil {
			fe.note(repo, path, err)
			return nil
		}
		if skip := skipHidden(repo, path, d); skip != nil {
			return skip
		}
		if d.IsDir() {
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
	}); err != nil {
		fe.note(repo, repo, err)
	}
	sort.Strings(out)
	return out
}

func fallbackDockerfilePaths(repo string, fe *fsErrors) []string {
	var out []string
	if err := filepath.WalkDir(repo, func(path string, d fs.DirEntry, err error) error {
		if err != nil {
			fe.note(repo, path, err)
			return nil
		}
		if skip := skipHidden(repo, path, d); skip != nil {
			return skip
		}
		if d.IsDir() {
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
	}); err != nil {
		fe.note(repo, repo, err)
	}
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

// FlutterSDKDepPattern ist woertlich dasselbe Muster, das
// `_component_is_flutter` in scripts/lib/onboard-detect-lib.sh an `grep -E`
// uebergibt. Dass es sich um dieselbe Zeichenkette handelt, ist keine
// Bequemlichkeit, sondern der Kern des Fixes: die beiden Detektoren sind
// auseinandergelaufen (Audit M-1), und ein Test vergleicht diese Konstante
// jetzt mit der Bash-Quelle, damit sie nicht erneut auseinanderlaufen koennen.
//
// Die fruehere Go-Fassung verglich woertlich mit "sdk: flutter" und uebersah
// dadurch `sdk:  flutter` und `sdk:\tflutter` — beides gueltiges YAML mit
// genau derselben Bedeutung. Weil `use_go_cli` standardmaessig an ist, wurde
// ein solches Flutter-Repo als `simple` gerendert, also ganz ohne Flutter-Job.
//
// `[[:blank:]]` und nicht `\s`: `\s` schliesst den Zeilenumbruch ein, das
// zeilenweise arbeitende `grep` kann ihn nie treffen. `[[:blank:]]` ist auf
// beiden Seiten exakt Space und Tab.
//
// Ein Plus, kein Stern: `sdk:flutter` ohne Leerzeichen ist in YAML gar kein
// Mapping, sondern ein Skalar — die Datei erklaert damit keine Abhaengigkeit.
// Die alte Bash-Fassung (`*`) hat sie faelschlich als Flutter gelesen.
const FlutterSDKDepPattern = `sdk:[[:blank:]]+flutter`

var flutterSDKDep = regexp.MustCompile(FlutterSDKDepPattern)

func isFlutter(dir string) bool {
	return has(dir, "pubspec.yaml") && flutterSDKDep.MatchString(mustRead(filepath.Join(dir, "pubspec.yaml")))
}

func inventoryDockerfiles(repo, componentPath, imageOverride string, fe *fsErrors) []domain.Dockerfile {
	dir := filepath.Join(repo, componentPath)
	entries, err := os.ReadDir(dir)
	if err != nil {
		// Nicht mit "keine Dockerfiles" verwechseln (Audit B-10): ein
		// unlesbares Komponentenverzeichnis ergab `dockerfiles: []`, und das
		// Image waere nie gebaut und nie gescannt worden.
		fe.note(repo, dir, err)
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
		out = append(out, resolveDockerfile(full, name, componentPath, imageOverride))
	}
	return out
}

// resolveDockerfile resolves the image name, its source, and release
// eligibility for a single Dockerfile file. Shared by the component-directory
// inventory (inventoryDockerfiles) and manifest-attached dockerfile specs
// (componentsFromManifest): imageOverride wins when set (source "manifest"),
// else the `# onboard:image=` header (source "override"), else a derived
// name (source "derived"). derivePath feeds deriveImageName's component-path
// segment. The returned Path is name; callers needing a different Path (e.g.
// component-relative for attached specs) overwrite it afterwards.
func resolveDockerfile(full, name, derivePath, imageOverride string) domain.Dockerfile {
	image, source := imageOverride, "manifest"
	if image == "" {
		image = readImageOverride(full)
		source = "override"
		if image == "" {
			image = deriveImageName(name, derivePath)
			source = "derived"
		}
	}
	eligible := name == "Dockerfile" || name == "Containerfile"
	if override := readReleaseOverride(full); override != nil {
		eligible = *override
	}
	return domain.Dockerfile{Path: name, ImageName: image, ImageNameSource: source, ReleaseEligible: eligible}
}

// Einmal kompiliert statt bei jedem Dockerfile neu.
var imageOverrideRe = regexp.MustCompile(manifest.ImagePattern)

func readImageOverride(file string) string {
	for i, line := range firstLines(file, 5) {
		if i >= 5 {
			break
		}
		if strings.HasPrefix(line, "# onboard:image=") {
			v := strings.TrimPrefix(line, "# onboard:image=")
			// Dieselbe Regel wie fuer `image:` im Manifest - eine Definition,
			// beide Aufrufstellen (Audit A-7/H-17). Hier stand eine woertliche
			// Kopie des alten, grossbuchstaben-tolerantem Musters; nach dem
			// Verschaerfen der Manifest-Fassung nahm sie `Acme/UPPER` weiter an.
			if imageOverrideRe.MatchString(v) {
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

// checkPackageNameCollisions weist ein Profil ab, in dem zwei Komponenten
// denselben release-please-Paketnamen bekommen.
//
// Gefunden ueber das Suchmuster "nicht-injektive Abbildung", nicht ueber die
// Fundliste. checkImageNameCollisions (Audit H-4) fing den Fall nur, wenn
// beide Komponenten ein Dockerfile tragen - ueber den daraus abgeleiteten
// Image-Namen. Ohne Dockerfiles gab es nichts zu vergleichen, und die
// gerenderte release-please-config.json sah so aus:
//
//	apps/api      -> package-name: api
//	services/api  -> package-name: api
//
// release-please erzeugt daraus fuer beide Tags `api-vX.Y.Z`. Zwei Komponenten
// teilen sich damit eine Versionsreihe: ein Release der einen verschiebt die
// Tag-Folge der anderen, und `latestComponentVersion` liest beim naechsten
// Onboarding die fremde Version.
//
// Das Manifest verbietet dieselbe Konstellation laengst (manifest.go, "package
// name %q already used by"). Fuer auto-erkannte Repos fehlte die Regel - wieder
// das Muster "Faehigkeit da, aber nicht ueberall angewandt".
//
// Die Wurzelkomponente ist ausgenommen, genau wie im Manifest: sie traegt
// keinen Paketnamen aus dem Pfad.
func checkPackageNameCollisions(components []domain.Component) error {
	seen := map[string]string{}
	for _, c := range components {
		if c.Path == "." {
			continue
		}
		base := filepath.Base(c.Path)
		if prev, dup := seen[base]; dup {
			return fmt.Errorf(
				"duplicate release-please package name %q: %s and %s both map to it — "+
					"rename one of the directories; the last path segment becomes the "+
					"package name and must be unique",
				base, prev, c.Path)
		}
		seen[base] = c.Path
	}
	return nil
}

// checkImageNameCollisions weist ein Profil ab, in dem zwei Dockerfiles
// denselben Image-Namen bekommen (Audit H-4).
//
// Der abgeleitete Name nimmt nur das LETZTE Pfadsegment: `apps/api` und
// `services/api` ergeben beide `$REPO-api`. Nachgestellt in beiden Engines.
// Beide Komponenten wuerden dann in dasselbe GHCR-Image pushen; derselbe
// Versionstag zeigt danach auf den Build, der zufaellig zuletzt lief, und
// cleanup-images sieht ein Paket statt zweier.
//
// Abgewiesen statt automatisch entschaerft — dieselbe Entscheidung wie bei den
// kollidierenden Job-IDs (J-0b): ein angehaengter Hash muesste fuer alle
// bestehenden Adopter stabil bleiben und waere fuer den Menschen, der die
// Registry liest, nicht mehr zuzuordnen.
//
// Der Ausweg ist Umbenennen, NICHT ein `image:` im Manifest. Der Validator dort
// weist dieselbe Konstellation bereits mit einer eigenen Regel ab
// ("package name %q already used by"), weil das letzte Pfadsegment zugleich der
// release-please-Paketname ist. Eine erste Fassung dieser Meldung riet zu
// `image:` und haette Adopter auf einen Weg geschickt, der gar nicht existiert;
// ein Test hat das gefangen.
//
// Fuer Manifest-Repos greift also die Manifest-Regel, fuer auto-erkannte diese
// hier — zusammen decken sie beide Wege ab.
func checkImageNameCollisions(components []domain.Component) error {
	type origin struct{ component, dockerfile string }
	seen := map[string]origin{}
	for _, c := range components {
		for _, d := range c.Dockerfiles {
			if d.ImageName == "" {
				continue
			}
			cur := origin{c.Path, d.Path}
			if prev, dup := seen[d.ImageName]; dup {
				return fmt.Errorf(
					"duplicate image name %q: %s/%s and %s/%s both map to it — "+
						"rename one of the directories; the last path segment becomes both "+
						"the image name and the release-please package name, and must be unique",
					d.ImageName, prev.component, prev.dockerfile, cur.component, cur.dockerfile)
			}
			seen[d.ImageName] = cur
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
	// OCI-Namen sind kleingeschrieben (Audit H-17). Ein Verzeichnis
	// `services/MyService` ergab bisher `$REPO-MyService`, und das landete
	// unveraendert im gerenderten `image_name` UND im GHCR-`package_name`.
	//
	// Die Templates lowercasen dieselbe Quelle laengst fuer das Job-ID-Suffix
	// (`strings.ToLower $base` in release.yml.tmpl) - die Herleitung tat es
	// nicht. Also wieder Muster 4: die Faehigkeit ist da, nur nicht ueberall
	// angewandt. Jetzt stimmen Job-ID und Image-Name wieder ueberein.
	//
	// Kleingeschrieben statt abgewiesen: der Verzeichnisname ist hier nur
	// Rohstoff fuer einen Slug, kein vom Adopter geschriebener Wert. Ein
	// ausdrueckliches `image:` im Manifest wird dagegen abgewiesen, siehe
	// imageRe.
	seg = strings.ToLower(seg)
	suffix = strings.ToLower(suffix)
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

func role(repo, componentPath string, dockerfiles []domain.Dockerfile, fe *fsErrors) string {
	dir := filepath.Join(repo, componentPath)
	if len(dockerfiles) > 0 {
		return "service"
	}
	if hasMainUnderCmd(dir, fe) || hasCargoBin(dir) || hasPythonScripts(dir) {
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

// detectCGO durchsucht die Komponente nach cgo-Nutzung. Ein unlesbares
// Verzeichnis hiess frueher "kein cgo" (Audit B-6, an einer Stelle, die der
// Fund nicht aufzaehlte): der gerenderte test-go-Job liefe dann ohne
// CGO_ENABLED=1, und der Build scheitert erst dort - oder testet still die
// falsche Konfiguration.
func detectCGO(repo, componentPath, primary string, fe *fsErrors) bool {
	if primary != "go" {
		return false
	}
	dir := filepath.Join(repo, componentPath)
	found := false
	_ = filepath.WalkDir(dir, func(path string, d fs.DirEntry, err error) error {
		if err != nil {
			fe.note(repo, path, err)
			return nil
		}
		if d.IsDir() || !strings.HasSuffix(d.Name(), ".go") {
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

func detectLegacyCI(repo string, declared []string) ([]domain.LegacyCI, error) {
	dir := filepath.Join(repo, ".github", "workflows")
	entries, err := os.ReadDir(dir)
	if errors.Is(err, os.ErrNotExist) {
		return []domain.LegacyCI{}, nil
	}
	if err != nil {
		return nil, err
	}
	owned := map[string]bool{"ci.yml": true, "release.yml": true, "prerelease.yml": true, "prerelease-on-push.yml": true, "cleanup.yml": true}
	for _, d := range declared {
		owned[d] = true
	}
	var out []domain.LegacyCI
	for _, e := range entries {
		if e.IsDir() || owned[e.Name()] || (!strings.HasSuffix(e.Name(), ".yml") && !strings.HasSuffix(e.Name(), ".yaml")) {
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

func unsupportedLanguageWarnings(components []domain.Component, fromManifest bool) []domain.Warning {
	seen := map[string]bool{}
	re := regexp.MustCompile("^(" + warningExemptLanguages + ")$")
	var out []domain.Warning
	for _, c := range components {
		if fromManifest && c.PrimaryLanguage == "generic" && len(c.Dockerfiles) > 0 {
			continue // image-only component declared by the manifest
		}
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

// unassignedSubdirDockerfileWarnings fires when the repo resolved to a single
// root component but carries Dockerfiles in sub-directories that no component
// owns. Before the root-marker fix those Dockerfiles hijacked the layout; now
// they are ignored loudly and the adopter manifest is the way to claim them.
func unassignedSubdirDockerfileWarnings(repo string, components []domain.Component, fe *fsErrors) []domain.Warning {
	if len(components) != 1 || components[0].Path != "." {
		return nil
	}
	var orphans []string
	_ = filepath.WalkDir(repo, func(path string, d fs.DirEntry, err error) error {
		if err != nil {
			// Diese Funktion MELDET verwaiste Dockerfiles. Ein unlesbares
			// Verzeichnis hiess bisher "nichts zu melden" - die Warnung blieb
			// aus, und der Adopter erfuhr nichts.
			fe.note(repo, path, err)
			return nil
		}
		if skip := skipHidden(repo, path, d); skip != nil {
			return skip
		}
		if d.IsDir() {
			return nil
		}
		name := d.Name()
		if name != "Dockerfile" && name != "Containerfile" && !strings.HasPrefix(name, "Dockerfile.") && !strings.HasPrefix(name, "Containerfile.") {
			return nil
		}
		rel, _ := filepath.Rel(repo, path)
		rel = filepath.ToSlash(rel)
		if strings.Contains(rel, "/") {
			orphans = append(orphans, rel)
		}
		return nil
	})
	if len(orphans) == 0 {
		return nil
	}
	sort.Strings(orphans)
	return []domain.Warning{{
		Code:    "subdir_dockerfiles_unassigned",
		Path:    strings.Join(orphans, ","),
		Message: fmt.Sprintf("%d Dockerfile(s) in sub-directories are not attached to any component and will not be built: %s. Declare them in .github/onboard.yml (components[].dockerfiles or their own component).", len(orphans), strings.Join(orphans, ", ")),
	}}
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

// firstLines liest die ersten n Zeilen und schneidet Leerzeichen, Tabs und ein
// CR am Zeilenende ab.
//
// Beide Aufrufer sind Annotationsleser (`# onboard:image=`, `# onboard:release=`)
// und vergleichen die Zeile als Ganzes. Ohne den Schnitt entscheidet ein
// unsichtbares Zeichen ueber das Ergebnis:
//
//	# onboard:release=true<CR>     auf Windows geschrieben -> Go verwarf sie
//	# onboard:release=true<space>  vom Editor gelassen     -> Go verwarf sie
//
// Die Bash-Fassung nahm beide an (ihr grep war nur am Zeilenanfang verankert),
// also entschieden die zwei Engines gegensaetzlich darueber, ob ein Image
// ueberhaupt ausgeliefert wird - und zwar unsichtbar im Diff. Ein auf Windows
// geschriebenes Dockerfile ist voellig normal; die Annotation dort still zu
// ignorieren waere in beiden Engines falsch, nicht nur uneinheitlich.
//
// Gilt nur fuer das Zeilenende. Eine EINGERUECKTE Annotation weisen beide
// Engines ab, und das bleibt so: das ist einheitlich und beabsichtigt.
func firstLines(path string, n int) []string {
	lines := strings.Split(mustRead(path), "\n")
	if len(lines) > n {
		lines = lines[:n]
	}
	for i, l := range lines {
		lines[i] = strings.TrimRight(l, " \t\r")
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

// hasMainUnderCmd entscheidet mit ueber `role: cli`. Ein fehlendes `cmd/` ist
// der Normalfall und wird nicht gemeldet; ein VORHANDENES, aber unlesbares
// schon (Audit B-6, weitere Fundstelle).
func hasMainUnderCmd(dir string, fe *fsErrors) bool {
	found := false
	_ = filepath.WalkDir(filepath.Join(dir, "cmd"), func(path string, d fs.DirEntry, err error) error {
		if err != nil {
			fe.note(dir, path, err)
			return nil
		}
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
		if err != nil {
			return nil
		}
		if skip := skipHidden(dir, path, d); skip != nil {
			return skip
		}
		if d.IsDir() || d.Name() != "Chart.yaml" || path == filepath.Join(dir, "Chart.yaml") {
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
