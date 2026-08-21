package manifest

import (
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"os"
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
	Path, Language, Type, Image, Context, Platforms string
	Release     *bool
	Unittest    bool
	Dockerfiles []DockerfileSpec
	Line        int
}

type DockerfileSpec struct {
	Path, Image, Context, Platforms string
	Release                         *bool
	Line                            int
}

type Workflows struct{ E2E *E2E }
type E2E struct{ Script, Schedule string }
type Release struct{ DispatchTrigger bool }
type Consumer struct {
	Repo  string
	Scope []string
	Mode  string
}

var (
	imageRe    = regexp.MustCompile(`^[A-Za-z0-9._/-]+$`)
	repoRe     = regexp.MustCompile(`^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$`)
	cronRe     = regexp.MustCompile(`^\S+ \S+ \S+ \S+ \S+$`)
	languages  = []string{"go", "python", "rust", "helm", "flutter", "node", "generic"}
	types      = []string{"helm"}
	modes      = []string{"renovate"}
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
		for _, item := range seq {
			c, err := decodeComponent(item)
			if err != nil {
				return nil, err
			}
			if seen[c.Path] {
				return nil, fmt.Errorf("line %d: duplicate component path %q", item.Line, c.Path)
			}
			seen[c.Path] = true
			m.Components = append(m.Components, c)
		}
	}
	if n, ok := root.Map["workflows"]; ok {
		if err := allowKeys(n, "e2e"); err != nil {
			return nil, err
		}
		m.Workflows = &Workflows{}
		if e, ok := n.Map["e2e"]; ok {
			if err := allowKeys(e, "script", "schedule"); err != nil {
				return nil, err
			}
			e2e := &E2E{}
			if e2e.Script, err = requiredString(e, "script"); err != nil {
				return nil, err
			}
			if e2e.Schedule, err = optionalString(e, "schedule"); err != nil {
				return nil, err
			}
			if e2e.Schedule != "" && !cronRe.MatchString(e2e.Schedule) {
				return nil, fmt.Errorf("line %d: schedule must be a 5-field cron expression", e.Map["schedule"].Line)
			}
			m.Workflows.E2E = e2e
		}
	}
	if n, ok := root.Map["release"]; ok {
		if err := allowKeys(n, "dispatch_trigger"); err != nil {
			return nil, err
		}
		m.Release = &Release{}
		if m.Release.DispatchTrigger, err = optionalBool(n, "dispatch_trigger"); err != nil {
			return nil, err
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
	if err := allowKeys(n, "path", "language", "type", "image", "context", "platforms", "release", "unittest", "dockerfiles"); err != nil {
		return Component{}, err
	}
	c := Component{Line: n.Line}
	var err error
	if c.Path, err = requiredString(n, "path"); err != nil {
		return c, err
	}
	if c.Path, err = cleanRelPath(c.Path, n.Map["path"].Line); err != nil {
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
	if c.Platforms, err = optionalString(n, "platforms"); err != nil {
		return c, err
	}
	if c.Release, err = optionalBoolPtr(n, "release"); err != nil {
		return c, err
	}
	if c.Unittest, err = optionalBool(n, "unittest"); err != nil {
		return c, err
	}
	if d, ok := n.Map["dockerfiles"]; ok {
		seq, err := seqValue(d)
		if err != nil {
			return c, err
		}
		for _, item := range seq {
			if err := allowKeys(item, "path", "image", "context", "platforms", "release"); err != nil {
				return c, err
			}
			spec := DockerfileSpec{Line: item.Line}
			if spec.Path, err = requiredString(item, "path"); err != nil {
				return c, err
			}
			if spec.Path, err = cleanRelPath(spec.Path, item.Map["path"].Line); err != nil {
				return c, err
			}
			if spec.Image, err = optionalImage(item, "image"); err != nil {
				return c, err
			}
			if spec.Context, err = optionalRelPath(item, "context"); err != nil {
				return c, err
			}
			if spec.Platforms, err = optionalString(item, "platforms"); err != nil {
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

func optionalRelPath(n *Node, key string) (string, error) {
	v, err := optionalString(n, key)
	if err != nil || v == "" {
		return v, err
	}
	return cleanRelPath(v, n.Map[key].Line)
}

func cleanRelPath(p string, line int) (string, error) {
	if filepath.IsAbs(p) || strings.HasPrefix(p, "/") {
		return "", fmt.Errorf("line %d: path must stay inside the repository, got %q", line, p)
	}
	clean := filepath.ToSlash(filepath.Clean(p))
	if clean == ".." || strings.HasPrefix(clean, "../") {
		return "", fmt.Errorf("line %d: path must stay inside the repository, got %q", line, p)
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
