package cli

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"os"
	"strings"

	"github.com/serverkraken/reusable-workflows/internal/adapters/catalogscripts"
	"github.com/serverkraken/reusable-workflows/internal/adapters/defaultsfs"
	"github.com/serverkraken/reusable-workflows/internal/adapters/gitcli"
	"github.com/serverkraken/reusable-workflows/internal/adapters/githubcli"
	"github.com/serverkraken/reusable-workflows/internal/adapters/gomplate"
	defaultsapp "github.com/serverkraken/reusable-workflows/internal/app/defaults"
	"github.com/serverkraken/reusable-workflows/internal/app/detect"
	"github.com/serverkraken/reusable-workflows/internal/app/drift"
	previewapp "github.com/serverkraken/reusable-workflows/internal/app/preview"
	renderapp "github.com/serverkraken/reusable-workflows/internal/app/render"
	"github.com/serverkraken/reusable-workflows/internal/domain"
)

func Run(ctx context.Context, args []string, stdout, stderr io.Writer) int {
	if len(args) == 0 || args[0] == "help" || args[0] == "--help" || args[0] == "-h" {
		usage(stdout)
		return 0
	}
	switch args[0] {
	case "detect":
		return runDetect(ctx, args[1:], stdout, stderr)
	case "render":
		return runRender(ctx, args[1:], stdout, stderr)
	case "drift":
		return runDrift(ctx, args[1:], stdout, stderr)
	case "apply-defaults":
		return runApplyDefaults(ctx, args[1:], stdout, stderr)
	case "preview":
		return runPreview(ctx, args[1:], stdout, stderr)
	default:
		fmt.Fprintf(stderr, "unknown command: %s\n", args[0])
		usage(stderr)
		return 2
	}
}

func runDetect(ctx context.Context, args []string, stdout, stderr io.Writer) int {
	fs := flag.NewFlagSet("detect", flag.ContinueOnError)
	fs.SetOutput(stderr)
	repoPath := fs.String("repo-path", "", "repository path")
	targetRepo := fs.String("target-repo", os.Getenv("TARGET_REPO"), "owner/repo for GitHub metadata")
	override := fs.String("language-override", "auto", "auto or explicit language")
	format := fs.String("format", "legacy", "legacy or profile-json")
	profileJSON := fs.Bool("profile-json", false, "emit profile-json output (bash-compatible alias)")
	emitBoth := fs.Bool("emit-both", false, "emit legacy key=value outputs and profile_json block")
	if err := fs.Parse(args); err != nil {
		return 2
	}
	if *repoPath == "" && fs.NArg() > 0 {
		*repoPath = fs.Arg(0)
	}
	if *override == "auto" && fs.NArg() > 1 {
		*override = fs.Arg(1)
	}
	if fs.NArg() > 2 {
		fmt.Fprintln(stderr, "too many positional arguments: expected <repo-path> [language-override]")
		return 2
	}
	if *profileJSON {
		*format = "profile-json"
	}
	if *repoPath == "" {
		fmt.Fprintln(stderr, "repo path is required")
		return 1
	}
	res, err := (detect.Service{GitHub: githubcli.Client{}}).Detect(ctx, detect.Request{
		RepoPath:         *repoPath,
		LanguageOverride: *override,
		TargetRepo:       *targetRepo,
	})
	if err != nil {
		fmt.Fprintln(stderr, err)
		return 1
	}
	profile, err := json.MarshalIndent(res.Profile, "", "  ")
	if err != nil {
		fmt.Fprintln(stderr, err)
		return 1
	}
	if *emitBoth {
		writeLegacy(stdout, res.Legacy)
		delim := delimiter(profile)
		fmt.Fprintf(stdout, "profile_json<<%s\n%s\n%s\n", delim, profile, delim)
		return 0
	}
	switch *format {
	case "profile-json":
		fmt.Fprintln(stdout, string(profile))
	case "legacy":
		writeLegacy(stdout, res.Legacy)
	default:
		fmt.Fprintf(stderr, "unsupported format: %s\n", *format)
		return 2
	}
	return 0
}

func runRender(ctx context.Context, args []string, stdout, stderr io.Writer) int {
	_ = stdout
	fs := flag.NewFlagSet("render", flag.ContinueOnError)
	fs.SetOutput(stderr)
	var catalogPath, targetPath, profilePath, pinVersion string
	fs.StringVar(&catalogPath, "catalog-path", "", "catalog repo path")
	fs.StringVar(&catalogPath, "catalog", "", "catalog repo path (alias)")
	fs.StringVar(&targetPath, "target-path", "", "target repo path")
	fs.StringVar(&targetPath, "target", "", "target repo path (alias)")
	fs.StringVar(&profilePath, "profile-json-path", "", "profile JSON path")
	fs.StringVar(&profilePath, "profile", "", "profile JSON path (alias)")
	fs.StringVar(&pinVersion, "pin-version", "", "catalog pin version")
	fs.StringVar(&pinVersion, "pin", "", "catalog pin version (alias)")
	renderedAgainst := fs.String("rendered-against", os.Getenv("RENDERED_AGAINST"), "full catalog tag recorded in lock")
	if err := fs.Parse(args); err != nil {
		return 2
	}
	if catalogPath == "" && fs.NArg() > 0 {
		catalogPath = fs.Arg(0)
	}
	if targetPath == "" && fs.NArg() > 1 {
		targetPath = fs.Arg(1)
	}
	if profilePath == "" && fs.NArg() > 2 {
		profilePath = fs.Arg(2)
	}
	if pinVersion == "" && fs.NArg() > 3 {
		pinVersion = fs.Arg(3)
	}
	if fs.NArg() > 4 {
		fmt.Fprintln(stderr, "too many positional arguments: expected <catalog-path> <target-path> <profile-json-path> <pin-version>")
		return 2
	}
	err := (renderapp.Service{Templates: gomplate.Adapter{}}).Render(ctx, renderapp.Request{
		CatalogPath:     catalogPath,
		TargetPath:      targetPath,
		ProfileJSONPath: profilePath,
		PinVersion:      pinVersion,
		RenderedAgainst: *renderedAgainst,
	})
	if err != nil {
		fmt.Fprintln(stderr, err)
		return 1
	}
	return 0
}

func runDrift(ctx context.Context, args []string, stdout, stderr io.Writer) int {
	fs := flag.NewFlagSet("drift", flag.ContinueOnError)
	fs.SetOutput(stderr)
	targetPath := fs.String("target-path", "", "checked-out adopter repo path")
	catalogPath := fs.String("catalog-path", "", "catalog repo path")
	currentVersion := fs.String("current-version", os.Getenv("CATALOG_CURRENT_VERSION"), "current catalog major, e.g. v4")
	if err := fs.Parse(args); err != nil {
		return 2
	}
	if *targetPath == "" && fs.NArg() > 0 {
		*targetPath = fs.Arg(0)
	}
	if *catalogPath == "" && fs.NArg() > 1 {
		*catalogPath = fs.Arg(1)
	}
	if fs.NArg() > 2 {
		fmt.Fprintln(stderr, "too many positional arguments: expected <target-path> <catalog-path>")
		return 2
	}
	res, err := (drift.Service{
		Detector: catalogscripts.Adapter{},
		Renderer: catalogscripts.Adapter{},
		Git:      gitcli.Client{},
	}).Drift(ctx, drift.Request{
		TargetPath:     *targetPath,
		CatalogPath:    *catalogPath,
		CurrentVersion: *currentVersion,
	})
	if err != nil {
		fmt.Fprintln(stderr, err)
		return 1
	}
	writeDrift(stdout, res)
	return 0
}

func runApplyDefaults(ctx context.Context, args []string, stdout, stderr io.Writer) int {
	fs := flag.NewFlagSet("apply-defaults", flag.ContinueOnError)
	fs.SetOutput(stderr)
	catalogPath := fs.String("catalog-path", ".", "catalog repo path")
	fs.StringVar(catalogPath, "catalog", ".", "catalog repo path (alias)")
	repo := fs.String("repo", "", "owner/repo of the target")
	targetPath := fs.String("target-path", "", "checked-out adopter repo path")
	prevMarker := fs.String("prev-marker", "", "previous defaults_applied_at marker")
	dryRun := fs.Bool("dry-run", false, "plan changes without mutating GitHub or the lock")
	if err := fs.Parse(args); err != nil {
		return 2
	}
	if fs.NArg() > 0 {
		fmt.Fprintln(stderr, "too many positional arguments: use flags for apply-defaults")
		return 2
	}
	res, err := (defaultsapp.Service{
		GitHub: githubcli.Client{},
		Store:  defaultsfs.Store{},
	}).Apply(ctx, defaultsapp.Request{
		CatalogPath: *catalogPath,
		Repo:        *repo,
		TargetPath:  *targetPath,
		PrevMarker:  *prevMarker,
		DryRun:      *dryRun,
	})
	if err != nil {
		fmt.Fprintf(stderr, "::error::%v\n", err)
		return 1
	}
	for _, notice := range res.Notices {
		fmt.Fprintln(stderr, notice)
	}
	if *dryRun {
		fmt.Fprintln(stdout, "defaults_applied=false")
		fmt.Fprintln(stdout, "tier_2_applied=false")
		fmt.Fprintf(stdout, "would_change=%s\n", defaultsapp.CategoriesCSV(res.WouldChange))
		writeDefaultsSummary(os.Getenv("GITHUB_STEP_SUMMARY"), *repo, res.WouldChange)
		return 0
	}
	fmt.Fprintln(stdout, "defaults_applied=true")
	fmt.Fprintf(stdout, "tier_2_applied=%t\n", res.Tier2Applied)
	fmt.Fprintf(stdout, "modified=%s\n", defaultsapp.CategoriesCSV(res.Modified))
	return 0
}

func runPreview(ctx context.Context, args []string, stdout, stderr io.Writer) int {
	fs := flag.NewFlagSet("preview", flag.ContinueOnError)
	fs.SetOutput(stderr)
	catalogPath := fs.String("catalog-path", ".", "catalog repo path")
	fs.StringVar(catalogPath, "catalog", ".", "catalog repo path (alias)")
	repoPath := fs.String("repo-path", "", "source repository path")
	outPath := fs.String("out", "", "preview output directory")
	targetRepo := fs.String("target-repo", os.Getenv("TARGET_REPO"), "owner/repo for GitHub metadata and substitutions")
	fs.StringVar(targetRepo, "repo", os.Getenv("TARGET_REPO"), "owner/repo for GitHub metadata and substitutions (alias)")
	override := fs.String("language-override", "auto", "auto or explicit language")
	pinVersion := fs.String("pin-version", "v4", "catalog pin version")
	fs.StringVar(pinVersion, "pin", "v4", "catalog pin version (alias)")
	renderedAgainst := fs.String("rendered-against", os.Getenv("RENDERED_AGAINST"), "full catalog tag recorded in lock")
	if err := fs.Parse(args); err != nil {
		return 2
	}
	if *repoPath == "" && fs.NArg() > 0 {
		*repoPath = fs.Arg(0)
	}
	if *outPath == "" && fs.NArg() > 1 {
		*outPath = fs.Arg(1)
	}
	if fs.NArg() > 2 {
		fmt.Fprintln(stderr, "too many positional arguments: expected <repo-path> <out>")
		return 2
	}
	res, err := (previewapp.Service{
		Detector: detect.Service{GitHub: githubcli.Client{}},
		Renderer: renderapp.Service{Templates: gomplate.Adapter{}},
	}).Preview(ctx, previewapp.Request{
		CatalogPath:      *catalogPath,
		RepoPath:         *repoPath,
		OutPath:          *outPath,
		TargetRepo:       *targetRepo,
		LanguageOverride: *override,
		PinVersion:       *pinVersion,
		RenderedAgainst:  *renderedAgainst,
	})
	if err != nil {
		fmt.Fprintln(stderr, err)
		return 1
	}
	writePreview(stdout, res)
	return 0
}

func writeLegacy(stdout io.Writer, legacy domain.LegacyOutputs) {
	fmt.Fprintf(stdout, "language=%s\n", legacy.Language)
	fmt.Fprintf(stdout, "release_type=%s\n", legacy.ReleaseType)
	fmt.Fprintf(stdout, "current_version=%s\n", legacy.CurrentVersion)
	fmt.Fprintf(stdout, "default_branch=%s\n", legacy.DefaultBranch)
}

func writeDrift(stdout io.Writer, res domain.DriftResult) {
	if res.LockVersion != "" {
		fmt.Fprintf(stdout, "lock_version=%s\n", res.LockVersion)
	}
	if res.CurrentVersion != "" {
		fmt.Fprintf(stdout, "current_version=%s\n", res.CurrentVersion)
	}
	fmt.Fprintf(stdout, "status=%s\n", res.Status)
	if res.Status == domain.DriftNoLock {
		return
	}
	fmt.Fprintf(stdout, "modified=%s\n", strings.Join(res.Modified, ","))
	fmt.Fprintf(stdout, "render_error=%s\n", res.RenderError)
}

func writePreview(stdout io.Writer, res previewapp.Result) {
	fmt.Fprintf(stdout, "preview_out=%s\n", res.OutPath)
	fmt.Fprintf(stdout, "profile_json=%s\n", res.ProfileJSONPath)
	writeLegacy(stdout, res.Legacy)
	fmt.Fprintf(stdout, "target_repo=%s\n", res.Profile.TargetRepo)
	fmt.Fprintf(stdout, "rendered_files=%s\n", strings.Join(res.RenderedFiles, ","))
}

func delimiter(payload []byte) string {
	seed := base64.RawURLEncoding.EncodeToString([]byte(fmt.Sprintf("%d", len(payload))))
	for i := 0; ; i++ {
		d := fmt.Sprintf("EOF_%s_%d", seed, i)
		if !strings.Contains(string(payload), d) {
			return d
		}
	}
}

func usage(w io.Writer) {
	fmt.Fprintln(w, "usage:")
	fmt.Fprintln(w, "  sk-workflows detect <repo-path> [language-override]")
	fmt.Fprintln(w, "  sk-workflows detect --profile-json <repo-path>")
	fmt.Fprintln(w, "  sk-workflows detect --emit-both <repo-path> [language-override]")
	fmt.Fprintln(w, "  sk-workflows detect --repo-path <dir> [--language-override <lang>] [--format legacy|profile-json]")
	fmt.Fprintln(w, "  sk-workflows render <catalog-path> <target-path> <profile-json-path> <pin-version>")
	fmt.Fprintln(w, "  sk-workflows render --catalog-path <dir> --target-path <dir> --profile-json-path <file> --pin-version vN")
	fmt.Fprintln(w, "  sk-workflows drift <target-path> <catalog-path>")
	fmt.Fprintln(w, "  sk-workflows drift --target-path <dir> --catalog-path <dir> [--current-version vN]")
	fmt.Fprintln(w, "  sk-workflows apply-defaults --repo owner/repo --target-path <dir> [--catalog-path <dir>] [--prev-marker <ts>] [--dry-run]")
	fmt.Fprintln(w, "  sk-workflows preview --repo-path <dir> --out <dir> [--catalog-path <dir>] [--pin-version vN] [--target-repo owner/repo]")
}

func writeDefaultsSummary(path, repo string, categories []string) {
	if path == "" {
		return
	}
	var b strings.Builder
	b.WriteString("## apply-repo-defaults (dry-run)\n\n")
	b.WriteString("**Repo:** `")
	b.WriteString(repo)
	b.WriteString("`\n\n")
	b.WriteString("**Would change:** ")
	if len(categories) == 0 {
		b.WriteString("_nothing - already in sync_")
	} else {
		b.WriteString("`")
		b.WriteString(strings.Join(categories, ","))
		b.WriteString("`")
	}
	b.WriteString("\n")
	f, err := os.OpenFile(path, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o644)
	if err != nil {
		return
	}
	defer f.Close()
	_, _ = f.WriteString(b.String())
}
