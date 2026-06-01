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

	"github.com/serverkraken/reusable-workflows/internal/adapters/githubcli"
	"github.com/serverkraken/reusable-workflows/internal/app/detect"
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

func writeLegacy(stdout io.Writer, legacy domain.LegacyOutputs) {
	fmt.Fprintf(stdout, "language=%s\n", legacy.Language)
	fmt.Fprintf(stdout, "release_type=%s\n", legacy.ReleaseType)
	fmt.Fprintf(stdout, "current_version=%s\n", legacy.CurrentVersion)
	fmt.Fprintf(stdout, "default_branch=%s\n", legacy.DefaultBranch)
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
}
