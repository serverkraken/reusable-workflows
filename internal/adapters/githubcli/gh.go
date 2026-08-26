package githubcli

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os/exec"
	"strings"

	"github.com/serverkraken/reusable-workflows/internal/domain"
)

type Client struct{}

func (Client) DefaultBranch(ctx context.Context, repo string) (string, error) {
	out, err := run(ctx, "gh", "api", "/repos/"+repo, "-q", ".default_branch")
	if err != nil {
		return "", err
	}
	branch := strings.TrimSpace(string(out))
	if branch == "" || branch == "null" {
		return "main", nil
	}
	return branch, nil
}

func (Client) LatestStableRelease(ctx context.Context, repo string) (string, error) {
	out, err := run(ctx, "gh", "release", "list", "--repo", repo, "--exclude-pre-releases", "--limit", "1", "--json", "tagName", "-q", ".[0].tagName")
	if err != nil {
		// Ebenfalls durchreichen (Audit L-7, gleiche Klasse wie I-11).
		//
		// `0.0.0` ist die richtige Antwort auf "noch kein Release" — als
		// Antwort auf "die Abfrage ist fehlgeschlagen" ist sie eine
		// Verwechslung mit Folgen: das Onboarding saet damit eine Version, und
		// ein Repo, das laengst bei v2 steht, faengt wieder bei null an.
		// Genau dafuer wurde I-11 im Shell-Pfad behoben; hier stand es noch.
		//
		// Die leere Antwort unten bleibt `0.0.0` — die ist echt.
		return "", err
	}
	tag := strings.TrimSpace(string(out))
	tag = strings.TrimPrefix(tag, "v")
	if tag == "" || tag == "null" {
		return "0.0.0", nil
	}
	return tag, nil
}

// ReleaseTags lists the repo's tags. Tags, not releases: release-please keys
// off tags, and a component can legitimately be seeded with a bare tag and no
// GitHub Release object — wartung's controller-v2.5.2 was created exactly that
// way, and reading releases would have missed it. Callers select by semver,
// so the API's ordering does not matter.
func (Client) ReleaseTags(ctx context.Context, repo string) ([]string, error) {
	out, err := run(ctx, "gh", "api", "--paginate", "/repos/"+repo+"/tags", "-q", ".[].name")
	if err != nil {
		// Durchreichen, nicht schlucken (Audit L-7).
		//
		// Vorher stand hier `return nil, nil`. Damit war der Fehlerzweig in
		// detect.Service toter Code — er meldet "could not list releases for
		// %s", konnte aber nie ausloesen. Ein Ausfall der Tag-Abfrage sah aus
		// wie "dieses Repo hat keine Tags", und das Onboarding saete die
		// Version aus einer leeren Liste.
		//
		// Das Degradieren gehoert nicht hierher: dafuer gibt es
		// godetect.tolerantMetadata, das genau diese Methode fuer den
		// Drift-Pfad abfaengt. Zweimal zu schlucken heisst, dass der strenge
		// Pfad nie streng ist.
		return nil, err
	}
	var tags []string
	for _, l := range strings.Split(strings.TrimSpace(string(out)), "\n") {
		if l = strings.TrimSpace(l); l != "" && l != "null" {
			tags = append(tags, l)
		}
	}
	return tags, nil
}

func (Client) Topics(ctx context.Context, repo string) ([]string, error) {
	out, err := run(ctx, "gh", "api", "/repos/"+repo+"/topics", "-q", ".names")
	if err != nil {
		return nil, err
	}
	raw := strings.TrimSpace(string(out))
	if raw == "" || raw == "null" {
		return nil, nil
	}
	var topics []string
	if err := json.Unmarshal([]byte(raw), &topics); err != nil {
		return nil, err
	}
	return topics, nil
}

func (Client) RepoMetadata(ctx context.Context, repo string) (domain.RepoMetadata, error) {
	out, err := api(ctx, "GET", "/repos/"+repo, nil)
	if err != nil {
		return domain.RepoMetadata{}, err
	}
	var meta domain.RepoMetadata
	if err := json.Unmarshal(out, &meta); err != nil {
		return domain.RepoMetadata{}, err
	}
	if meta.DefaultBranch == "" || meta.DefaultBranch == "null" {
		meta.DefaultBranch = "main"
	}
	return meta, nil
}

// BranchProtection treats only HTTP 404 ("Branch not protected") as
// missing; every other API failure is returned so callers abort instead
// of overwriting live protection with catalog defaults.
func (Client) BranchProtection(ctx context.Context, repo, branch string) (json.RawMessage, bool, error) {
	out, err := api(ctx, "GET", fmt.Sprintf("/repos/%s/branches/%s/protection", repo, branch), nil)
	if err != nil {
		if isNotFound(err) {
			return nil, true, nil
		}
		return nil, false, err
	}
	return json.RawMessage(bytes.TrimSpace(out)), false, nil
}

func isNotFound(err error) bool {
	msg := err.Error()
	return strings.Contains(msg, "HTTP 404") || strings.Contains(msg, "Branch not protected") || strings.Contains(msg, "Not Found")
}

func (Client) UpdateBranchProtection(ctx context.Context, repo, branch string, payload []byte) error {
	_, err := api(ctx, "PUT", fmt.Sprintf("/repos/%s/branches/%s/protection", repo, branch), payload)
	return err
}

func (Client) ReplaceTopics(ctx context.Context, repo string, topics []string) error {
	payload, err := json.Marshal(struct {
		Names []string `json:"names"`
	}{Names: topics})
	if err != nil {
		return err
	}
	_, err = api(ctx, "PUT", "/repos/"+repo+"/topics", payload)
	return err
}

func (Client) PatchRepository(ctx context.Context, repo string, payload []byte) error {
	_, err := api(ctx, "PATCH", "/repos/"+repo, payload)
	return err
}

func run(ctx context.Context, name string, args ...string) ([]byte, error) {
	cmd := exec.CommandContext(ctx, name, args...)
	var stderr bytes.Buffer
	cmd.Stderr = &stderr
	out, err := cmd.Output()
	if err != nil {
		msg := strings.TrimSpace(stderr.String())
		if msg == "" {
			msg = err.Error()
		}
		return nil, errors.New(msg)
	}
	return out, nil
}

func api(ctx context.Context, method, endpoint string, input []byte) ([]byte, error) {
	args := []string{"api"}
	if method != "" && method != "GET" {
		args = append(args, "-X", method)
	}
	args = append(args, endpoint)
	if input != nil {
		args = append(args, "--input", "-")
	}
	cmd := exec.CommandContext(ctx, "gh", args...)
	if input != nil {
		cmd.Stdin = bytes.NewReader(input)
	}
	var stdout, stderr bytes.Buffer
	cmd.Stdout = &stdout
	cmd.Stderr = &stderr
	if err := cmd.Run(); err != nil {
		msg := strings.TrimSpace(stderr.String())
		if msg == "" {
			msg = strings.TrimSpace(stdout.String())
		}
		if msg == "" {
			msg = err.Error()
		}
		return stdout.Bytes(), errors.New(msg)
	}
	return stdout.Bytes(), nil
}
