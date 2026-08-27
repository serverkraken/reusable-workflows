package manifest

import (
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"os"
	"path"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
)

const FileName = ".github/onboard.yml"

type Manifest struct {
	Schema     int
	Components []Component
	Workflows  *Workflows
	Release    *Release
	GitOps     []Consumer
}

type Component struct {
	Path, Language, Type, Image, Context, Platforms, Scanners string
	UploadSARIF                                               *bool
	// Severity and FailOnFindings are the scan GATE, as opposed to Scanners
	// which decides what is looked for. Split out because an image can be
	// worth scanning while its findings must not block a release — mailstack's
	// crowdsec-sync ships upstream CrowdSec binaries whose Go-stdlib CVEs it
	// cannot fix from its own Dockerfile.
	Severity       string
	FailOnFindings *bool
	Release        *bool
	Unittest       bool
	// AppVersion keeps a chart's appVersion in step with its own chart
	// version. release-please's helm strategy only rewrites `version:` —
	// mailstack's chart reached 1.10.0 while appVersion sat at v1.6.5, and
	// that value is what every resource's app.kubernetes.io/version label and
	// the install notes show. Opt-in because it renders an extra-files entry,
	// and a chart without the x-release-please-version marker on its
	// appVersion line has nothing for that updater to do.
	AppVersion  bool
	Dockerfiles []DockerfileSpec
	Line        int
}

type DockerfileSpec struct {
	Path, Image, Context, Platforms, Scanners string
	Severity                                  string
	UploadSARIF                               *bool
	FailOnFindings                            *bool
	Release                                   *bool
	Line                                      int
}

type Workflows struct {
	E2E *E2E
	// Keep lists workflow files the adopter maintains itself. Without it the
	// legacy scan proposes deleting anything it did not render — wartung's
	// hand-written quality.yml was flagged as "go test pipeline; replaced by
	// test-go.yml" because it happens to contain `go test -race`, while it
	// really runs ansible-lint, yamllint, shellcheck and the Ansible tests,
	// none of which the catalog covers.
	Keep []string
}
type E2E struct{ Script, Schedule string }
type Release struct {
	DispatchTrigger, Badges bool
	// PrereleaseBranch ist der Branch, auf dessen Push prerelease-on-push.yml
	// baut. Leer = `develop`, der bisher fest im Template stand (Audit J-25).
	// GitHub wertet in `on:` keine Ausdruecke aus, der Wert muss also beim
	// Rendern feststehen — deshalb ein Manifest-Feld und kein Repo-Variable.
	PrereleaseBranch string
	// ChartPins moves the chart's own image pins after a release built new
	// images. Nil when the adopter does not ship a chart for its own images.
	ChartPins *ChartPins
}

// ChartPins names the values file and the dotted path that holds an image tag.
// `Key` carries a {name} placeholder for the image basename.
type ChartPins struct {
	Values, Key string
	Line        int
}
type Consumer struct {
	Repo  string
	Scope []string
	Mode  string
}

// ImagePattern ist die EINE Regel fuer Image-Namen im Katalog.
//
// Sie existierte zweimal woertlich: hier und in detect.readImageOverride, das
// `# onboard:image=` aus einem Dockerfile-Kopf liest. Beim Verschaerfen auf
// Kleinschreibung (Audit A-7/H-17) habe ich nur diese Fassung angefasst - der
// Zwilling nahm `Acme/UPPER` weiter unbeanstandet an. Genau die Divergenz, die
// M-1 beschreibt, diesmal von mir selbst erzeugt.
//
// Deshalb exportiert: eine Definition, beide Aufrufstellen. Wer sie aendert,
// aendert beide.
const ImagePattern = `^[a-z0-9._/-]+$`

// RelPathPattern ist die EINE Regel fuer repo-relative Pfade im Manifest:
// `path`, `context`, `script`, `values`.
//
// Sie existierte als `scriptRe` und galt nur fuer `script`. `context` lief
// durch cleanRelPath, das absolute Pfade und `..` abweist - und sonst nichts.
// Gemessen, alles angenommen:
//
//	context: "git@github.com:angreifer/repo.git"   unveraendert durchgereicht
//	context: "svc#main"                            unveraendert durchgereicht
//	context: "https://github.com/x/y.git#main"     zu "https:/..." verstuemmelt
//
// Der erste Fall ist der ernste: `git@host:pfad` ist eine gueltige ENTFERNTE
// Build-Quelle fuer buildx. Der Wert landet im `context:` des docker-build-
// Atoms, das damit aus einem fremden Repository baut und das Ergebnis in die
// Registry des Adopters schiebt. Auch das `#` ist kein Zufall: buildx trennt
// damit Ref und Unterverzeichnis einer entfernten Quelle ab.
//
// Unabhaengig davon, wie erreichbar das im Einzelfall ist: der Validator heisst
// cleanRelPath und verspricht in seiner eigenen Fehlermeldung, dass der Pfad im
// Repository bleibt. Ein Wert mit `@`, `:` oder `#` ist kein repo-relativer
// Pfad, und genau das soll die Funktion durchsetzen.
const RelPathPattern = `^[A-Za-z0-9._/-]+$`

// ChartPinKeyPattern gilt fuer `release.chart_pins.key`.
//
// Der Nachbarschluessel `values` laeuft durch cleanRelPath und damit durch
// RelPathPattern. `key` lief durch NICHTS ausser der Pruefung, dass er
// "{name}" enthaelt. Gemessen, beides angenommen:
//
//	key: 'images.{name}.tag"'                        -> zerbrach das gerenderte YAML
//	key: 'images.{name}.tag${{ secrets.GITHUB_TOKEN }}'
//
// Der zweite Fall ist der ernste. Der Wert landet als
// `key_template: "..."` im release.yml des Adopters, und GitHub wertet den
// Ausdruck dort zur LAUFZEIT aus. Der Token steht danach im key_template, das
// chart-image-bump.py als gepunkteten Pfad in die values-Datei schreibt.
//
// `key` ist ein gepunkteter Pfad in eine Helm-values-Datei mit dem Platzhalter
// {name} - Buchstaben, Ziffern, Punkt, Unterstrich, Bindestrich und die
// geschweiften Klammern des Platzhalters. Weder `$` noch Anfuehrungszeichen
// gehoeren dazu (Audit J-22).
//
// Der Fund nannte `values`; das ist validiert. Das Loch war der Schluessel
// direkt daneben.
const ChartPinKeyPattern = `^[A-Za-z0-9._{}-]+$`

// PrereleaseBranchPattern gilt fuer `release.prerelease_branch`.
//
// Der Wert landet in `prerelease-on-push.yml` in einer YAML-FLOW-SEQUENZ:
//
//	on:
//	  push:
//	    branches: [<wert>]
//
// Das ist dieselbe Stelle, an der `default_branch` in release.yml.tmpl schon
// einmal auffiel (Audit J-20). Git erlaubt dort Zeichen, die YAML anders liest
// als der Adopter meint:
//
//	prerelease_branch: x,y   ->  branches: [x,y]   ZWEI Branches statt einem
//	prerelease_branch: a]b   ->  branches: [a]b]   zerbricht die Datei
//
// Das Template quotet zusaetzlich mit strings.Quote — beides, weil Quoting den
// Schaden repariert, die Pruefung ihn aber benennt. Ein Adopter, der `x,y`
// meint, soll das beim Onboarding erfahren und nicht anhand eines Workflows,
// der still auf zwei Branches lauscht.
//
// Bewusst enger als Git: keine Leerzeichen, kein `@`, `:`, `~`, `^`, `?`, `*`,
// `[`. Das deckt `develop`, `dev`, `release/next` und `feature.x` ab.
const PrereleaseBranchPattern = `^[A-Za-z0-9._/-]+$`

var (
	// OCI-Namen sind kleingeschrieben; die Distribution-Spec laesst im
	// Repository-Namen nur [a-z0-9] plus Trenner zu (Audit A-7). Das Muster
	// erlaubte Grossbuchstaben, und ein `image: Acme/UPPER` waere unbeanstandet
	// bis zum Push durchgelaufen.
	//
	// Abgewiesen statt kleingeschrieben: anders als beim abgeleiteten Namen hat
	// das hier jemand hingeschrieben. Den Wert eines Adopters still zu
	// veraendern waere schlechter, als ihn darauf hinzuweisen.
	imageRe = regexp.MustCompile(ImagePattern)
	// scriptRe und die Pfadpruefung in cleanRelPath teilen sich dieselbe Regel:
	// die Zeichenklasse galt bisher NUR fuer `script`, nicht fuer `context`
	// oder `path` (Audit A-1). cleanRelPath heisst so und meldet "path must
	// stay inside the repository" - hielt das aber nur gegen `/` am Anfang und
	// `..`, nicht gegen alles andere, was kein Pfad ist.
	relPathRe          = regexp.MustCompile(RelPathPattern)
	chartPinKeyRe      = regexp.MustCompile(ChartPinKeyPattern)
	prereleaseBranchRe = regexp.MustCompile(PrereleaseBranchPattern)
	repoRe             = regexp.MustCompile(`^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$`)
	// platformsRe mirrors the buildx `--platform` list the docker-build atoms
	// forward verbatim: os/arch with an optional /vN variant, comma-separated,
	// no spaces.
	platformsRe = regexp.MustCompile(`^[a-z0-9]+/[a-z0-9]+(/v[0-9]+)?(,[a-z0-9]+/[a-z0-9]+(/v[0-9]+)?)*$`)
	// cronRe accepts the five standard cron fields. The charset is deliberately
	// narrow (digits, `*`, `,`, `-`, `/`, and names like MON-FRI) so quoting
	// artefacts or shell punctuation never reach the rendered `schedule:`.
	//
	// Der Zeichensatz allein reicht NICHT: `61 25 32 13 8` passierte ihn
	// anstandslos (Audit A-6). Die Bereiche prueft validateCron weiter unten.
	cronRe    = regexp.MustCompile(`^[-0-9*,/A-Za-z]+( [-0-9*,/A-Za-z]+){4}$`)
	languages = []string{"go", "python", "rust", "helm", "flutter", "node", "generic"}
	types     = []string{"helm"}
	modes     = []string{"renovate"}
	// scanners mirrors trivy's own `--scanners` vocabulary (trivy-image passes
	// the value through unchanged).
	scanners = []string{"vuln", "secret", "misconfig", "license"}
	// severities mirrors trivy's own `--severity` vocabulary. Uppercase only:
	// trivy accepts nothing else, and silently scanning at a different
	// threshold than the manifest reads is worse than a render-time error.
	severities = []string{"UNKNOWN", "LOW", "MEDIUM", "HIGH", "CRITICAL"}
)

func Load(repoPath string) (*Manifest, string, bool, error) {
	raw, err := os.ReadFile(filepath.Join(repoPath, filepath.FromSlash(FileName)))
	if errors.Is(err, os.ErrNotExist) {
		return nil, "", false, nil
	}
	if err != nil {
		return nil, "", false, fmt.Errorf("%s: %w", FileName, err)
	}
	m, err := Parse(raw)
	if err != nil {
		return nil, "", true, err
	}
	sum := sha256.Sum256(raw)
	return m, hex.EncodeToString(sum[:]), true, nil
}

func Parse(src []byte) (*Manifest, error) {
	root, err := parseYAML(string(src))
	if err != nil {
		return nil, fmt.Errorf("%s: %w", FileName, err)
	}
	m, err := decode(root)
	if err != nil {
		return nil, fmt.Errorf("%s: %w", FileName, err)
	}
	return m, nil
}

func decode(root *Node) (*Manifest, error) {
	if err := allowKeys(root, "schema", "components", "workflows", "release", "gitops"); err != nil {
		return nil, err
	}
	m := &Manifest{}
	sn, ok := root.Map["schema"]
	if !ok {
		return nil, fmt.Errorf("line %d: `schema` is required", root.Line)
	}
	schema, err := intValue(sn)
	if err != nil {
		return nil, err
	}
	if schema != 1 {
		return nil, fmt.Errorf("line %d: unsupported schema %d (this catalog supports 1)", sn.Line, schema)
	}
	m.Schema = schema

	if n, ok := root.Map["components"]; ok {
		seq, err := seqValue(n)
		if err != nil {
			return nil, err
		}
		if len(seq) == 0 {
			return nil, fmt.Errorf("line %d: `components` must not be empty when set", n.Line)
		}
		seen := map[string]bool{}
		// release-please derives a non-root package's `package-name` (and thus
		// its tag prefix) from the directory basename, so two components with
		// the same basename would fight over one tag namespace.
		packages := map[string]string{}
		for _, item := range seq {
			c, err := decodeComponent(item)
			if err != nil {
				return nil, err
			}
			if seen[c.Path] {
				return nil, fmt.Errorf("line %d: duplicate component path %q", item.Line, c.Path)
			}
			seen[c.Path] = true
			if c.Path != "." {
				base := path.Base(c.Path)
				if prev, dup := packages[base]; dup {
					return nil, fmt.Errorf("line %d: component %s: package name %q already used by %s", item.Line, c.Path, base, prev)
				}
				packages[base] = c.Path
			}
			m.Components = append(m.Components, c)
		}
	}
	if n, ok := root.Map["workflows"]; ok {
		if err := allowKeys(n, "e2e", "keep"); err != nil {
			return nil, err
		}
		m.Workflows = &Workflows{}
		if k, ok := n.Map["keep"]; ok {
			seq, err := seqValue(k)
			if err != nil {
				return nil, err
			}
			for _, item := range seq {
				name, err := stringValue(item)
				if err != nil {
					return nil, err
				}
				if strings.ContainsAny(name, "/\\") || (!strings.HasSuffix(name, ".yml") && !strings.HasSuffix(name, ".yaml")) {
					return nil, fmt.Errorf("line %d: workflows.keep takes bare file names under .github/workflows, got %q", item.Line, name)
				}
				m.Workflows.Keep = append(m.Workflows.Keep, name)
			}
		}
		if e, ok := n.Map["e2e"]; ok {
			if err := allowKeys(e, "script", "schedule"); err != nil {
				return nil, err
			}
			e2e := &E2E{}
			if e2e.Script, err = requiredString(e, "script"); err != nil {
				return nil, err
			}
			scriptLine := e.Map["script"].Line
			raw := e2e.Script
			if e2e.Script, err = cleanRelPath(raw, scriptLine, "script"); err != nil {
				return nil, err
			}
			if e2e.Schedule, err = optionalString(e, "schedule"); err != nil {
				return nil, err
			}
			if e2e.Schedule != "" {
				if !cronRe.MatchString(e2e.Schedule) {
					return nil, fmt.Errorf("line %d: schedule must be a 5-field cron expression", e.Map["schedule"].Line)
				}
				if err := validateCron(e2e.Schedule); err != nil {
					return nil, fmt.Errorf("line %d: schedule %w", e.Map["schedule"].Line, err)
				}
			}
			m.Workflows.E2E = e2e
		}
	}
	if n, ok := root.Map["release"]; ok {
		if err := allowKeys(n, "dispatch_trigger", "badges", "chart_pins", "prerelease_branch"); err != nil {
			return nil, err
		}
		m.Release = &Release{}
		if m.Release.Badges, err = optionalBool(n, "badges"); err != nil {
			return nil, err
		}
		if m.Release.DispatchTrigger, err = optionalBool(n, "dispatch_trigger"); err != nil {
			return nil, err
		}
		if pb, err := optionalString(n, "prerelease_branch"); err != nil {
			return nil, err
		} else if pb != "" {
			line := n.Line
			if node, ok := n.Map["prerelease_branch"]; ok {
				line = node.Line
			}
			if !prereleaseBranchRe.MatchString(pb) {
				return nil, fmt.Errorf("line %d: release.prerelease_branch must match %s, got %q", line, PrereleaseBranchPattern, pb)
			}
			// Zeichensatz allein reicht nicht: `-x`, `a/`, `/a` und `a..b` sind
			// alle aus erlaubten Zeichen gebaut und trotzdem keine Branchnamen,
			// die `git` so annimmt.
			if strings.HasPrefix(pb, "-") || strings.HasPrefix(pb, "/") || strings.HasSuffix(pb, "/") || strings.Contains(pb, "..") || strings.Contains(pb, "//") {
				return nil, fmt.Errorf("line %d: release.prerelease_branch is not a usable branch name: %q", line, pb)
			}
			m.Release.PrereleaseBranch = pb
		}
		if cp, ok := n.Map["chart_pins"]; ok {
			if err := allowKeys(cp, "values", "key"); err != nil {
				return nil, err
			}
			pins := &ChartPins{Line: cp.Line, Key: "images.{name}.tag"}
			if pins.Values, err = requiredString(cp, "values"); err != nil {
				return nil, err
			}
			if pins.Values, err = cleanRelPath(pins.Values, cp.Map["values"].Line, "values"); err != nil {
				return nil, err
			}
			if key, err := optionalString(cp, "key"); err != nil {
				return nil, err
			} else if key != "" {
				pins.Key = key
			}
			if !strings.Contains(pins.Key, "{name}") {
				return nil, fmt.Errorf("line %d: chart_pins.key must contain {name}, got %q", cp.Line, pins.Key)
			}
			if !chartPinKeyRe.MatchString(pins.Key) {
				return nil, fmt.Errorf("line %d: chart_pins.key must match %s, got %q", cp.Line, ChartPinKeyPattern, pins.Key)
			}
			m.Release.ChartPins = pins
		}
	}
	if n, ok := root.Map["gitops"]; ok {
		seq, err := seqValue(n)
		if err != nil {
			return nil, err
		}
		for _, item := range seq {
			if err := allowKeys(item, "repo", "scope", "mode"); err != nil {
				return nil, err
			}
			c := Consumer{Mode: "renovate"}
			if c.Repo, err = requiredString(item, "repo"); err != nil {
				return nil, err
			}
			if !repoRe.MatchString(c.Repo) {
				return nil, fmt.Errorf("line %d: repo must be owner/name, got %q", item.Map["repo"].Line, c.Repo)
			}
			if s, ok := item.Map["scope"]; ok {
				if c.Scope, err = stringList(s); err != nil {
					return nil, err
				}
			}
			if mode, ok := item.Map["mode"]; ok {
				v, err := stringValue(mode)
				if err != nil {
					return nil, err
				}
				if v == "push" {
					return nil, fmt.Errorf("line %d: gitops mode push is not yet supported (reserved; see docs/operations.md § Adopter Manifest)", mode.Line)
				}
				if !contains(modes, v) {
					return nil, fmt.Errorf("line %d: mode must be one of %v, got %q", mode.Line, modes, v)
				}
				c.Mode = v
			}
			m.GitOps = append(m.GitOps, c)
		}
	}
	return m, nil
}

func decodeComponent(n *Node) (Component, error) {
	if err := allowKeys(n, "path", "language", "type", "image", "context", "platforms", "scanners", "severity", "upload_sarif", "fail_on_findings", "release", "unittest", "app_version", "dockerfiles"); err != nil {
		return Component{}, err
	}
	c := Component{Line: n.Line}
	var err error
	if c.Path, err = requiredString(n, "path"); err != nil {
		return c, err
	}
	if c.Path, err = cleanRelPath(c.Path, n.Map["path"].Line, "path"); err != nil {
		return c, err
	}
	if c.Language, err = optionalString(n, "language"); err != nil {
		return c, err
	}
	if c.Language != "" && !contains(languages, c.Language) {
		return c, fmt.Errorf("line %d: language must be one of %v, got %q", n.Map["language"].Line, languages, c.Language)
	}
	if c.Type, err = optionalString(n, "type"); err != nil {
		return c, err
	}
	if c.Type != "" && !contains(types, c.Type) {
		return c, fmt.Errorf("line %d: type must be one of %v, got %q", n.Map["type"].Line, types, c.Type)
	}
	if c.Image, err = optionalImage(n, "image"); err != nil {
		return c, err
	}
	if c.Context, err = optionalRelPath(n, "context"); err != nil {
		return c, err
	}
	if c.Platforms, err = optionalPlatforms(n, "platforms"); err != nil {
		return c, err
	}
	if c.Scanners, err = optionalScanners(n, "scanners"); err != nil {
		return c, err
	}
	if c.Severity, err = optionalSeverity(n, "severity"); err != nil {
		return c, err
	}
	if c.UploadSARIF, err = optionalBoolPtr(n, "upload_sarif"); err != nil {
		return c, err
	}
	if c.FailOnFindings, err = optionalBoolPtr(n, "fail_on_findings"); err != nil {
		return c, err
	}
	if c.Release, err = optionalBoolPtr(n, "release"); err != nil {
		return c, err
	}
	if c.Unittest, err = optionalBool(n, "unittest"); err != nil {
		return c, err
	}
	if c.AppVersion, err = optionalBool(n, "app_version"); err != nil {
		return c, err
	}
	if d, ok := n.Map["dockerfiles"]; ok {
		seq, err := seqValue(d)
		if err != nil {
			return c, err
		}
		for _, item := range seq {
			if err := allowKeys(item, "path", "image", "context", "platforms", "scanners", "severity", "upload_sarif", "fail_on_findings", "release"); err != nil {
				return c, err
			}
			spec := DockerfileSpec{Line: item.Line}
			if spec.Path, err = requiredString(item, "path"); err != nil {
				return c, err
			}
			if spec.Path, err = cleanRelPath(spec.Path, item.Map["path"].Line, "path"); err != nil {
				return c, err
			}
			if spec.Image, err = optionalImage(item, "image"); err != nil {
				return c, err
			}
			if spec.Context, err = optionalRelPath(item, "context"); err != nil {
				return c, err
			}
			if spec.Platforms, err = optionalPlatforms(item, "platforms"); err != nil {
				return c, err
			}
			if spec.Scanners, err = optionalScanners(item, "scanners"); err != nil {
				return c, err
			}
			if spec.Severity, err = optionalSeverity(item, "severity"); err != nil {
				return c, err
			}
			if spec.UploadSARIF, err = optionalBoolPtr(item, "upload_sarif"); err != nil {
				return c, err
			}
			if spec.FailOnFindings, err = optionalBoolPtr(item, "fail_on_findings"); err != nil {
				return c, err
			}
			if spec.Release, err = optionalBoolPtr(item, "release"); err != nil {
				return c, err
			}
			c.Dockerfiles = append(c.Dockerfiles, spec)
		}
	}
	return c, nil
}

// ---- node helpers ----

func allowKeys(n *Node, allowed ...string) error {
	if n.Kind != KindMap {
		return fmt.Errorf("line %d: expected a mapping", n.Line)
	}
	for _, k := range n.Keys {
		if !contains(allowed, k) {
			return fmt.Errorf("line %d: unknown key %q (allowed: %s)", n.Map[k].Line, k, strings.Join(allowed, ", "))
		}
	}
	return nil
}

func seqValue(n *Node) ([]*Node, error) {
	if n.Kind != KindSeq {
		return nil, fmt.Errorf("line %d: expected a list", n.Line)
	}
	return n.Seq, nil
}

func stringValue(n *Node) (string, error) {
	if n.Kind != KindScalar || n.Scalar == "" {
		return "", fmt.Errorf("line %d: expected a non-empty string", n.Line)
	}
	return n.Scalar, nil
}

func intValue(n *Node) (int, error) {
	if n.Kind != KindScalar {
		return 0, fmt.Errorf("line %d: expected an integer", n.Line)
	}
	v, err := strconv.Atoi(n.Scalar)
	if err != nil {
		return 0, fmt.Errorf("line %d: expected an integer, got %q", n.Line, n.Scalar)
	}
	return v, nil
}

func boolValue(n *Node) (bool, error) {
	if n.Kind == KindScalar {
		switch n.Scalar {
		case "true":
			return true, nil
		case "false":
			return false, nil
		}
	}
	return false, fmt.Errorf("line %d: expected true or false", n.Line)
}

func requiredString(n *Node, key string) (string, error) {
	v, ok := n.Map[key]
	if !ok {
		return "", fmt.Errorf("line %d: `%s` is required", n.Line, key)
	}
	return stringValue(v)
}

func optionalString(n *Node, key string) (string, error) {
	v, ok := n.Map[key]
	if !ok {
		return "", nil
	}
	return stringValue(v)
}

func optionalBool(n *Node, key string) (bool, error) {
	v, ok := n.Map[key]
	if !ok {
		return false, nil
	}
	return boolValue(v)
}

func optionalBoolPtr(n *Node, key string) (*bool, error) {
	v, ok := n.Map[key]
	if !ok {
		return nil, nil
	}
	b, err := boolValue(v)
	if err != nil {
		return nil, err
	}
	return &b, nil
}

func optionalImage(n *Node, key string) (string, error) {
	v, err := optionalString(n, key)
	if err != nil || v == "" {
		return v, err
	}
	if !imageRe.MatchString(v) {
		return "", fmt.Errorf("line %d: image must match %s, got %q", n.Map[key].Line, imageRe.String(), v)
	}
	return v, nil
}

func optionalPlatforms(n *Node, key string) (string, error) {
	v, err := optionalString(n, key)
	if err != nil || v == "" {
		return v, err
	}
	if !platformsRe.MatchString(v) {
		return "", fmt.Errorf("line %d: platforms must be a comma-separated list of os/arch[/variant], got %q", n.Map[key].Line, v)
	}
	return v, nil
}

// optionalSeverity validates the trivy `--severity` list the trivy-image atom
// forwards verbatim. Rejecting a typo here matters more than for most keys: an
// unrecognised threshold would not fail the scan, it would quietly gate on
// something other than what the manifest says.
func optionalSeverity(n *Node, key string) (string, error) {
	v, err := optionalString(n, key)
	if err != nil || v == "" {
		return v, err
	}
	seen := map[string]bool{}
	for _, s := range strings.Split(v, ",") {
		if !contains(severities, s) {
			return "", fmt.Errorf("line %d: severity must be a comma-separated subset of %v, got %q", n.Map[key].Line, severities, v)
		}
		if seen[s] {
			return "", fmt.Errorf("line %d: severity lists %q twice", n.Map[key].Line, s)
		}
		seen[s] = true
	}
	return v, nil
}

// optionalScanners validates the trivy `--scanners` list the trivy-image atom
// forwards verbatim. Each element is checked against trivy's own vocabulary so
// a typo fails at render time rather than silently disabling a scanner in a
// weekly release run.
func optionalScanners(n *Node, key string) (string, error) {
	v, err := optionalString(n, key)
	if err != nil || v == "" {
		return v, err
	}
	seen := map[string]bool{}
	for _, s := range strings.Split(v, ",") {
		if !contains(scanners, s) {
			return "", fmt.Errorf("line %d: scanners must be a comma-separated subset of %v, got %q", n.Map[key].Line, scanners, v)
		}
		if seen[s] {
			return "", fmt.Errorf("line %d: scanners lists %q twice", n.Map[key].Line, s)
		}
		seen[s] = true
	}
	return v, nil
}

func optionalRelPath(n *Node, key string) (string, error) {
	v, err := optionalString(n, key)
	if err != nil || v == "" {
		return v, err
	}
	return cleanRelPath(v, n.Map[key].Line, key)
}

// cleanRelPath prueft einen repo-relativen Pfad. `what` ist der Feldname und
// steht in der Fehlermeldung: die Regel gilt fuer `path`, `context`, `script`
// und `values`, und wer sie verletzt, soll lesen koennen, WELCHES Feld gemeint
// ist.
func cleanRelPath(p string, line int, what string) (string, error) {
	if filepath.IsAbs(p) || strings.HasPrefix(p, "/") {
		return "", fmt.Errorf("line %d: %s must stay inside the repository, got %q", line, what, p)
	}
	clean := filepath.ToSlash(filepath.Clean(p))
	if clean == ".." || strings.HasPrefix(clean, "../") {
		return "", fmt.Errorf("line %d: %s must stay inside the repository, got %q", line, what, p)
	}
	// Geprueft wird der ROHE Wert, nicht der bereinigte: filepath.Clean macht
	// aus `https://evil/x` ein `https:/evil/x` und damit aus einer erkennbaren
	// URL etwas, das wie ein Pfad aussieht. Die Verstuemmelung darf nicht die
	// Pruefung entschaerfen.
	if !relPathRe.MatchString(p) {
		return "", fmt.Errorf("line %d: %s must be a repo-relative path matching %s, got %q",
			line, what, RelPathPattern, p)
	}
	return clean, nil
}

func stringList(n *Node) ([]string, error) {
	seq, err := seqValue(n)
	if err != nil {
		return nil, err
	}
	out := make([]string, 0, len(seq))
	for _, item := range seq {
		v, err := stringValue(item)
		if err != nil {
			return nil, err
		}
		out = append(out, v)
	}
	return out, nil
}

func contains(list []string, v string) bool {
	for _, x := range list {
		if x == v {
			return true
		}
	}
	return false
}

// validateCron prueft die WERTE der fuenf Cron-Felder, nicht nur ihre Zeichen
// (Audit A-6).
//
// cronRe prueft Zeichensatz und Feldzahl. `61 25 32 13 8` erfuellt beides und
// lief bis ins gerenderte e2e.yml des Adopters durch. Dort faengt es
// actionlint:
//
//	invalid CRON format "61 25 32 13 8" in schedule event:
//	end of range (61) above maximum (59): 61
//
// Aber eben erst dort, ein Repo weiter, mit einer Meldung ueber die
// Workflow-Datei statt ueber die Manifest-Zeile — dieselbe Klasse wie A-3,
// A-4 und B-4: hier erklaert, dort gescheitert. Die Meldung nennt jetzt die
// Zeile im Manifest und das Feld, das nicht passt.
//
// Bewusst KEIN vollstaendiger Cron-Dialekt: `@daily`, `L`, `W`, `#` und
// Sekundenfelder kennt GitHub Actions nicht, und cronRe laesst `@` und `#`
// ohnehin nicht durch. Geprueft wird genau das, was GitHub akzeptiert.
func validateCron(expr string) error {
	fields := strings.Fields(expr)
	if len(fields) != 5 {
		// cronRe hat das bereits sichergestellt; defensiv, damit der
		// Validator auch allein aufgerufen korrekt bleibt.
		return fmt.Errorf("must have 5 fields, got %d", len(fields))
	}
	specs := []struct {
		name     string
		min, max int
		names    map[string]int
	}{
		{"minute", 0, 59, nil},
		{"hour", 0, 23, nil},
		{"day-of-month", 1, 31, nil},
		{"month", 1, 12, cronMonths},
		// 0 UND 7 sind Sonntag — beides ist bei GitHub gueltig.
		{"day-of-week", 0, 7, cronWeekdays},
	}
	for i, s := range specs {
		if err := validateCronField(fields[i], s.min, s.max, s.names); err != nil {
			return fmt.Errorf("field %d (%s): %w", i+1, s.name, err)
		}
	}
	return nil
}

var cronMonths = map[string]int{
	"JAN": 1, "FEB": 2, "MAR": 3, "APR": 4, "MAY": 5, "JUN": 6,
	"JUL": 7, "AUG": 8, "SEP": 9, "OCT": 10, "NOV": 11, "DEC": 12,
}

var cronWeekdays = map[string]int{
	"SUN": 0, "MON": 1, "TUE": 2, "WED": 3, "THU": 4, "FRI": 5, "SAT": 6,
}

// validateCronField prueft eine kommagetrennte Liste aus `*`, `*/n`, `n`,
// `a-b` und `a-b/n`.
func validateCronField(field string, min, max int, names map[string]int) error {
	for _, part := range strings.Split(field, ",") {
		if part == "" {
			return fmt.Errorf("empty list entry in %q", field)
		}
		body := part
		if slash := strings.IndexByte(part, '/'); slash >= 0 {
			body = part[:slash]
			step := part[slash+1:]
			n, err := strconv.Atoi(step)
			if err != nil || n < 1 {
				return fmt.Errorf("step %q must be a positive number", step)
			}
			// Ein Schritt groesser als die Spanne feuert nur einmal am
			// Bereichsanfang. Das ist gueltig, aber fast immer ein Tippfehler
			// — GitHub laesst es zu, deshalb bleibt es hier erlaubt.
		}
		if body == "*" {
			continue
		}
		lo, hi := body, ""
		if dash := strings.IndexByte(body, '-'); dash >= 0 {
			lo, hi = body[:dash], body[dash+1:]
		}
		lov, err := cronValue(lo, min, max, names)
		if err != nil {
			return err
		}
		if hi == "" {
			continue
		}
		hiv, err := cronValue(hi, min, max, names)
		if err != nil {
			return err
		}
		if lov > hiv {
			return fmt.Errorf("range %q starts above its end", body)
		}
	}
	return nil
}

func cronValue(tok string, min, max int, names map[string]int) (int, error) {
	if tok == "" {
		return 0, fmt.Errorf("empty value")
	}
	if names != nil {
		if v, ok := names[strings.ToUpper(tok)]; ok {
			return v, nil
		}
	}
	v, err := strconv.Atoi(tok)
	if err != nil {
		if names != nil {
			return 0, fmt.Errorf("%q is neither a number nor a known name", tok)
		}
		return 0, fmt.Errorf("%q is not a number", tok)
	}
	if v < min || v > max {
		return 0, fmt.Errorf("%d is outside %d-%d", v, min, max)
	}
	return v, nil
}
