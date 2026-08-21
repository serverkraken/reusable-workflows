# Adopter Manifest + Per-Component Releases Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let an adopter declare its component layout in `.github/onboard.yml`, and make the rendered release pipeline build only the components release-please actually released — so mailstack can be onboarded without losing anything its hand-wired workflows do today.

**Architecture:** A new zero-dependency package `internal/manifest` parses a small YAML subset into a node tree and validates it against schema v1 with line-numbered errors. `detect` consumes the manifest (authoritative components, attached Dockerfiles, build contexts) and fixes the root-marker fallback bug; `render`/`drift` learn a lock `inputs.manifest_sha256`; the gomplate templates gain a monorepo release-gating branch driven by two new `semantic-release.yml` outputs (`paths_released`, `releases`) and an `e2e.yml` skeleton; `lint-helm.yml` gains `unittest`. Every change is additive and every single-component adopter renders byte-identically.

**Tech Stack:** Go 1.24 stdlib only (`go.mod` has no `require`), gomplate templates, Bash + bats, GitHub Actions reusable workflows, jq, release-please-action v5, helm-unittest.

**Spec:** `docs/superpowers/specs/2026-08-21-adopter-manifest-monorepo-design.md` (same branch). Read it first; this plan argues from it.

## Global Constraints

- **Zero external Go dependencies.** `go.mod` is `module github.com/serverkraken/reusable-workflows` / `go 1.24` with no `require` block. The YAML subset parser is hand-written (spec § Open questions: "minimal in-tree decoder").
- **Single-component adopters render byte-identically.** Every new profile field carries `omitempty`; every new template branch is guarded by a field that only manifest/monorepo profiles set; the lock's new `inputs` block is emitted only when a manifest exists. Gate: `bats tests/shell/` golden tests (all fixtures except `monorepo-go`, which is regenerated on purpose) and the `onboard-drift-go-cli-happy` self-CI job against `tests/fixtures/onboard/drift-clean` stay green without touching their expected files.
- **Both engines share templates; only Go reads the manifest.** `scripts/onboard-detect.sh` must exit non-zero when `.github/onboard.yml` exists (three dispatch branches, three checks). Bash render/drift are not extended for manifest profiles.
- **Contract docs are enforced.** `tests/conventions/check-contracts.sh` diffs `docs/contracts.md` tables against `workflow_call.inputs/outputs/secrets`. Every new input/output needs a table row in the same commit.
- **Go coverage gate ≥ 90 %** on the catalog module (`test-go-self` in self-CI). New packages ship with thorough tests.
- **Naming:** the adopter file is `.github/onboard.yml` ("adopter manifest"); the catalog workflow `.github/workflows/onboard.yml` is "the onboard workflow". Never write bare "onboard.yml" in docs.
- **Lock JSON is hand-serialised** (`encodeLock`, `internal/app/render/service.go:267-294`) to control key order — extend it there, never via `json.Marshal`.
- **Catalog release target: v4.14.0** (minor). Commits use Conventional Commits; `feat:`/`fix:` scopes as shown in each task.
- **Spec amendment (this plan):** the manifest gains an optional `context` (component level and per Dockerfile, repo-relative; default = component path). Without it mailstack's `images/<name>/Dockerfile` cannot build (`COPY images/<name>/…` needs context `.`). Task 0 patches the spec.

---

## File structure

| Path | Responsibility | Task |
|---|---|---|
| `internal/manifest/yaml.go` | YAML-subset parser → `*Node` tree with line numbers | 3 |
| `internal/manifest/yaml_test.go` | parser tests | 3 |
| `internal/manifest/manifest.go` | schema v1 types, `Load`, strict validation | 4 |
| `internal/manifest/manifest_test.go` | schema tests | 4 |
| `internal/domain/profile.go` | new optional profile fields | 5 |
| `internal/domain/lock.go` | `Inputs` on `OnboardLock` | 9 |
| `internal/app/detect/service.go` | fallback fix, manifest → components, warnings, legacy owned set | 6, 7 |
| `internal/app/detect/service_test.go` | fixture tests | 6, 7 |
| `internal/app/render/service.go` | `e2e.yml` in render set, lock inputs | 9 |
| `internal/app/drift/service.go` | manifest hash → `stale-lock` | 10 |
| `scripts/onboard-detect.sh` | fail-loud on manifest | 8 |
| `tests/shell/onboard-detect.bats` | fail-loud test | 8 |
| `.github/workflows/semantic-release.yml` | `paths_released`, `releases` outputs | 1 |
| `.github/workflows/lint-helm.yml` | `unittest` input | 2 |
| `.github/renovate.json5` | helm-unittest manager + `allowedVersions` | 2 |
| `docs/contracts.md` | new rows | 1, 2 |
| `docs/adopter-templates/configs/release-please-config.monorepo.json.tmpl` | root/subdir/helm packages | 11 |
| `docs/adopter-templates/configs/release-please-manifest.json.tmpl` | per-component seed version | 11 |
| `docs/adopter-templates/skeletons/release.yml.tmpl` | path gating, context, dispatch trigger, chart publish | 12 |
| `docs/adopter-templates/skeletons/prerelease.yml.tmpl` | component loop | 13 |
| `docs/adopter-templates/skeletons/ci.yml.tmpl` | chart component jobs | 14 |
| `docs/adopter-templates/skeletons/e2e.yml.tmpl` | new | 15 |
| `tests/fixtures/onboard/go-root-subdir-dockerfile/` | fallback-fix fixture | 6 |
| `tests/fixtures/onboard/go-root-multi-image/` | manifest fixture + golden `expected/` | 7, 16 |
| `tests/fixtures/helm-unittest/`, `tests/fixtures/lint-test/helm-unittest-fail/` | lint-helm unittest fixtures | 2 |
| `.github/workflows/self-ci.yml`, `failure-paths-nightly.yml`, `integration.yml` | callers | 1, 2, 16 |
| `.github/workflows/onboard.yml`, `docs/onboarding-status.md`, `scripts/seed-onboarding-status.sh` | "Consumers" column | 17 |
| `docs/operations.md` | § 11 Adopter Manifest | 18 |

---

### Task 0: Spec amendment — `context` field ✅ (done while writing this plan)

**Files:**
- Modify: `docs/superpowers/specs/2026-08-21-adopter-manifest-monorepo-design.md`

- [x] **Step 1: Patch the schema example and semantics**

In § 1 replace the `images/postfix` entry and add `context` to the attached-Dockerfile example:

```yaml
  - path: .
    language: go
    dockerfiles:
      - path: images/tools/Dockerfile
        image: serverkraken/mailstack/tools
        context: .                           # optional, repo-relative; default = component path
  - path: images/postfix
    image: serverkraken/mailstack/postfix
    context: .                               # shorthand form of the same field
```

Replace the bullet "**Build context = component path.**" with:

> **Build context defaults to the component path** and can be overridden per component (`context`, shorthand) or per Dockerfile (`dockerfiles[].context`), repo-relative. All Dockerfiles of one component must resolve to the same context (docker-build-multi has one shared `context`); detect rejects mixed contexts. mailstack sets `context: .` on every image component because its Dockerfiles `COPY images/<name>/…` from the repo root.

In § 2 item 4 keep `dockerfiles[].context` in the list (it is now load-bearing).

- [x] **Step 2: Commit** — landed together with this plan (`docs(plan): …`).

---

## Stage 1 — Atoms (no template change, no drift)

### Task 1: `semantic-release.yml` outputs `paths_released` + `releases`

**Files:**
- Modify: `.github/workflows/semantic-release.yml:27-35` (workflow_call outputs), `:61-65` (job outputs), insert a step after `:86`
- Modify: `docs/contracts.md:240-255`
- Modify: `.github/workflows/integration.yml:348-360` (add assertion job)

**Interfaces:**
- Produces: outputs `paths_released` (JSON array string, e.g. `["."]` or `["images/postfix","charts/mailstack"]`, `[]` when nothing released) and `releases` (JSON object string `{"<path>":{"tag_name":"postfix-v1.2.0","version":"1.2.0","major":"1","minor":"2"}}`, `{}` when nothing released). Task 12 templates consume both.

- [ ] **Step 1: Add the collecting step**

After the `googleapis/release-please-action` step (ends at line 86) insert:

```yaml
      # release-please-action emits one output per released path with a
      # `<path>--` prefix (and, for the root package ".", the bare names).
      # workflow_call outputs must be declared statically, so the dynamic set
      # is folded into two JSON strings here: the list of released paths and a
      # path→{tag_name,version,major,minor} map. Single-package repos get
      # ["."] / {".": {...}}; idle runs get [] / {}.
      - name: Collect per-path release outputs
        id: paths
        env:
          RP_OUTPUTS: ${{ toJSON(steps.release.outputs) }}
        run: |
          set -euo pipefail
          paths="$(jq -c '(.paths_released // "[]") | fromjson' <<< "$RP_OUTPUTS")"
          releases="$(jq -c '
            . as $o
            | (($o.paths_released // "[]") | fromjson) as $paths
            | def pick($p; $k):
                ($o[$p + "--" + $k]) // (if $p == "." then $o[$k] else null end) // "";
            | reduce $paths[] as $p ({}; . + {($p): {
                tag_name: pick($p; "tag_name"),
                version:  pick($p; "version"),
                major:    pick($p; "major"),
                minor:    pick($p; "minor")
              }})' <<< "$RP_OUTPUTS")"
          {
            echo "paths_released=$paths"
            echo "releases=$releases"
          } >> "$GITHUB_OUTPUT"
```

- [ ] **Step 2: Declare the outputs**

In `on.workflow_call.outputs` (after `minor_tag`, line 35) add:

```yaml
      paths_released:
        description: 'JSON array of release-please package paths released in this run ("[]" when none).'
        value: ${{ jobs.release.outputs.paths_released }}
      releases:
        description: 'JSON object path → {tag_name, version, major, minor} for every released path ("{}" when none).'
        value: ${{ jobs.release.outputs.releases }}
```

In `jobs.release.outputs` (after `minor_tag`, line 65) add:

```yaml
      paths_released: ${{ steps.paths.outputs.paths_released }}
      releases: ${{ steps.paths.outputs.releases }}
```

- [ ] **Step 3: Document the contract**

In `docs/contracts.md` `### \`semantic-release.yml\`` table append two rows after `minor_tag`:

```markdown
| output  | `paths_released`                | string  | —        | —                                         | JSON array of released package paths, e.g. `'["."]'`; `'[]'` when idle |
| output  | `releases`                      | string  | —        | —                                         | JSON object `{"<path>":{"tag_name","version","major","minor"}}`; `'{}'` when idle |
```

- [ ] **Step 4: Run the contract check**

Run: `bats tests/shell/check-contracts.bats`
Expected: PASS (a missing row fails with the offending name).

- [ ] **Step 5: Assert the shape in integration**

In `.github/workflows/integration.yml` after the `test-semantic-release-dry-run` job add:

```yaml
  assert-semantic-release-outputs:
    needs: test-semantic-release-dry-run
    runs-on: ubuntu-latest
    timeout-minutes: 5
    steps:
      - name: paths_released / releases are well-formed JSON and agree
        env:
          PATHS: ${{ needs.test-semantic-release-dry-run.outputs.paths_released }}
          RELEASES: ${{ needs.test-semantic-release-dry-run.outputs.releases }}
        run: |
          set -euo pipefail
          jq -e 'type == "array"' <<< "$PATHS" > /dev/null
          jq -e 'type == "object"' <<< "$RELEASES" > /dev/null
          # every released path has a map entry and vice versa
          diff <(jq -r '.[]' <<< "$PATHS" | sort) <(jq -r 'keys[]' <<< "$RELEASES" | sort)
```

- [ ] **Step 6: Lint**

Run: `actionlint .github/workflows/semantic-release.yml .github/workflows/integration.yml`
Expected: no findings.

- [ ] **Step 7: Commit**

```bash
git add .github/workflows/semantic-release.yml .github/workflows/integration.yml docs/contracts.md
git commit -m "feat(semantic-release): expose paths_released and releases outputs"
```

---

### Task 2: `lint-helm.yml` input `unittest`

**Files:**
- Modify: `.github/workflows/lint-helm.yml` (inputs after `ct_version`; steps after `ct lint`; summary)
- Modify: `.github/renovate.json5` (customManagers + packageRules)
- Create: `tests/fixtures/helm-unittest/{Chart.yaml,values.yaml,templates/configmap.yaml,tests/configmap_test.yaml}`
- Create: `tests/fixtures/lint-test/helm-unittest-fail/{Chart.yaml,values.yaml,templates/configmap.yaml,tests/configmap_test.yaml}`
- Modify: `.github/workflows/self-ci.yml` (after `lint-helm-happy`, line 51-56), `.github/workflows/failure-paths-nightly.yml` (after the `test-lint-helm-fail` assert pair, lines 65-83)
- Modify: `docs/contracts.md:174-184`

**Interfaces:**
- Produces: input `unittest` (boolean, default `false`). Task 14 renders `unittest: true` for chart components with `unittest: true` in the manifest.

- [ ] **Step 1: Fixtures**

`tests/fixtures/helm-unittest/Chart.yaml`:
```yaml
apiVersion: v2
name: unittest-fixture
version: 0.1.0
type: application
```
`tests/fixtures/helm-unittest/values.yaml`:
```yaml
message: hello
```
`tests/fixtures/helm-unittest/templates/configmap.yaml`:
```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: {{ .Release.Name }}-config
data:
  message: {{ .Values.message | quote }}
```
`tests/fixtures/helm-unittest/tests/configmap_test.yaml`:
```yaml
suite: configmap
templates:
  - configmap.yaml
tests:
  - it: renders the message
    set:
      message: hi
    asserts:
      - equal:
          path: data.message
          value: hi
```
`tests/fixtures/lint-test/helm-unittest-fail/`: same four files, but the test asserts `value: wrong` (chart name `unittest-fail-fixture`) so `helm lint` passes and `helm unittest` fails.

- [ ] **Step 2: Input**

After `ct_version` (line 31) add:

```yaml
      unittest:
        description: 'Run helm-unittest (tests/*_test.yaml inside each chart) after linting.'
        required: false
        type: boolean
        default: false
```

- [ ] **Step 3: Steps**

After the `ct lint` step insert:

```yaml
      # Third-party plugin on a long-lived runner: pinned release into a
      # job-private plugin dir, so neither a plugin left behind by an earlier
      # job nor the upstream default branch decides what runs. <1.1.0 is
      # enforced by a Renovate packageRule: 1.1.0 switched plugin.yaml to
      # `platformHooks`, which Helm v3's plugin loader rejects outright.
      - name: Install helm-unittest
        if: inputs.unittest
        env:
          HELM_PLUGINS: ${{ runner.temp }}/helm-plugins
          # renovate: datasource=github-releases depName=helm-unittest/helm-unittest
          HELM_UNITTEST_VERSION: v1.0.3
        run: |
          set -euo pipefail
          rm -rf "$HELM_PLUGINS" && mkdir -p "$HELM_PLUGINS"
          helm plugin install https://github.com/helm-unittest/helm-unittest \
            --version "${HELM_UNITTEST_VERSION#v}"

      - name: helm unittest
        if: inputs.unittest
        id: helm_unittest
        working-directory: ${{ inputs.working_directory }}
        env:
          HELM_PLUGINS: ${{ runner.temp }}/helm-plugins
          CHARTS_DIR: ${{ inputs.charts_dir }}
        run: |
          set -euo pipefail
          shopt -s nullglob
          if [[ -f "$CHARTS_DIR/Chart.yaml" ]]; then
            helm unittest "$CHARTS_DIR"
          else
            for d in "$CHARTS_DIR"/*/; do
              [[ -f "${d%/}/Chart.yaml" ]] && helm unittest "${d%/}"
            done
          fi
```

- [ ] **Step 4: Summary**

In the Summary step add `HELM_UNITTEST_OUTCOME: ${{ steps.helm_unittest.outcome }}` to `env`, change the result condition to

```bash
          if [[ "$HELM_LINT_OUTCOME" == "success" && "$CT_LINT_OUTCOME" == "success" && ( "$HELM_UNITTEST_OUTCOME" == "success" || "$HELM_UNITTEST_OUTCOME" == "skipped" ) ]]; then
```

and add the table row `echo "| helm unittest | $(glyph "$HELM_UNITTEST_OUTCOME") |"` after the `ct lint` row (skipped renders `−`, per `docs/conventions/step-summary.md`).

- [ ] **Step 5: Renovate**

In `.github/renovate.json5` add to `customManagers` (copy the `TRIVY_VERSION` entry shape at lines 44-55):

```js
    {
      customType: 'regex',
      fileMatch: ['^\\.github/workflows/lint-helm\\.ya?ml$'],
      matchStrings: [
        '#\\s*renovate:\\s*datasource=(?<datasource>\\S+)\\s+depName=(?<depName>\\S+)\\s*\\n\\s*HELM_UNITTEST_VERSION:\\s*[\'"]?(?<currentValue>v\\S+?)[\'"]?\\s',
      ],
      datasourceTemplate: 'github-releases',
      depNameTemplate: 'helm-unittest/helm-unittest',
    },
```

and to `packageRules`:

```js
    {
      description: 'helm-unittest >=1.1.0 uses plugin.yaml platformHooks, rejected by Helm v3 (lint-helm default v3.16.3)',
      matchDepNames: ['helm-unittest/helm-unittest'],
      allowedVersions: '<1.1.0',
    },
```

- [ ] **Step 6: Callers**

`self-ci.yml`, after `lint-helm-happy`:

```yaml
  lint-helm-unittest-happy:
    uses: ./.github/workflows/lint-helm.yml
    secrets: inherit
    with:
      working_directory: tests/fixtures
      charts_dir: helm-unittest
      unittest: true
```

Add `lint-helm-unittest-happy` to the `summary` job's `needs` list the same way `lint-helm-happy` is listed (line 464ff).

`failure-paths-nightly.yml`, after the `test-lint-helm-fail` pair (lines 65-83) — copy that pair verbatim and rename:

```yaml
  test-lint-helm-unittest-fail:
    uses: ./.github/workflows/lint-helm.yml
    secrets: inherit
    with:
      working_directory: tests/fixtures/lint-test
      charts_dir: helm-unittest-fail
      unittest: true

  assert-lint-helm-unittest-fail:
    needs: test-lint-helm-unittest-fail
    if: always()
    runs-on: ubuntu-latest
    steps:
      - env:
          RESULT: ${{ needs.test-lint-helm-unittest-fail.result }}
        run: |
          if [[ "$RESULT" != "failure" ]]; then
            echo "::error::expected lint job to fail, got: $RESULT"
            exit 1
          fi
```

(Keep whatever extra keys the existing assert job at lines 73-83 carries — mirror it exactly.)

- [ ] **Step 7: Contract row**

`docs/contracts.md` `### \`lint-helm.yml\`` table, after `ct_version`:

```markdown
| input | `unittest`          | boolean | no       | `false`                     | Run helm-unittest (`tests/*_test.yaml` in each chart) after linting. |
```

- [ ] **Step 8: Verify**

Run: `bats tests/shell/check-contracts.bats && actionlint .github/workflows/lint-helm.yml .github/workflows/self-ci.yml .github/workflows/failure-paths-nightly.yml`
Expected: PASS / no findings. Local smoke (needs helm): `HELM_PLUGINS=$(mktemp -d) helm plugin install https://github.com/helm-unittest/helm-unittest --version 1.0.3 && HELM_PLUGINS=… helm unittest tests/fixtures/helm-unittest` → `Passed: 1`; same on `helm-unittest-fail` → exit 1.

- [ ] **Step 9: Commit**

```bash
git add .github/workflows/lint-helm.yml .github/renovate.json5 tests/fixtures/helm-unittest tests/fixtures/lint-test/helm-unittest-fail .github/workflows/self-ci.yml .github/workflows/failure-paths-nightly.yml docs/contracts.md
git commit -m "feat(lint-helm): optional helm-unittest run via unittest input"
```

---

## Stage 2 — Detect, render, drift, templates

### Task 3: YAML-subset parser (`internal/manifest/yaml.go`)

**Files:**
- Create: `internal/manifest/yaml.go`, `internal/manifest/yaml_test.go`

**Interfaces:**
- Produces:
  ```go
  type Kind int // KindMap, KindSeq, KindScalar
  type Node struct {
      Kind   Kind
      Line   int               // 1-based source line
      Keys   []string          // KindMap: insertion order
      Map    map[string]*Node  // KindMap
      Seq    []*Node           // KindSeq
      Scalar string            // KindScalar: raw text, quotes stripped
      Quoted bool              // KindScalar: was quoted (never coerced)
  }
  func parseYAML(src string) (*Node, error)   // error text: "line N: <reason>"
  ```
  Supported subset: block mappings (`key: value`, `key:` + indented block), block sequences (`- scalar`, `- key: value` + continuation keys at item indent), flow sequences of scalars (`[a, "b", c]`), plain/`"`/`'` scalars, `#` comments, blank lines, two-space indentation. Tabs, anchors, multi-line scalars, flow maps, duplicate keys → error.

- [ ] **Step 1: Failing tests**

```go
package manifest

import (
	"strings"
	"testing"
)

func TestParseYAMLMappingSequenceScalars(t *testing.T) {
	src := `schema: 1
# comment line
components:
  - path: .
    language: go
    dockerfiles:
      - path: images/tools/Dockerfile
        image: serverkraken/mailstack/tools
  - path: charts/mailstack
    type: helm
    unittest: true
gitops:
  - repo: serverkraken/homelab-mail-nue
    scope: [kubernetes/apps/mailstack/**, "bootstrap/templates/**"]
    mode: renovate   # trailing comment
release:
  dispatch_trigger: "true"
`
	root, err := parseYAML(src)
	if err != nil {
		t.Fatal(err)
	}
	if root.Kind != KindMap || strings.Join(root.Keys, ",") != "schema,components,gitops,release" {
		t.Fatalf("root=%+v", root)
	}
	if got := root.Map["schema"]; got.Kind != KindScalar || got.Scalar != "1" || got.Line != 1 {
		t.Fatalf("schema=%+v", got)
	}
	comps := root.Map["components"]
	if comps.Kind != KindSeq || len(comps.Seq) != 2 || comps.Seq[0].Line != 4 {
		t.Fatalf("components=%+v", comps)
	}
	df := comps.Seq[0].Map["dockerfiles"].Seq[0]
	if df.Map["image"].Scalar != "serverkraken/mailstack/tools" || df.Map["image"].Line != 8 {
		t.Fatalf("dockerfile=%+v", df)
	}
	if comps.Seq[1].Map["unittest"].Scalar != "true" {
		t.Fatalf("unittest=%+v", comps.Seq[1].Map["unittest"])
	}
	scope := root.Map["gitops"].Seq[0].Map["scope"]
	if scope.Kind != KindSeq || len(scope.Seq) != 2 || scope.Seq[1].Scalar != "bootstrap/templates/**" || !scope.Seq[1].Quoted {
		t.Fatalf("scope=%+v", scope)
	}
	if root.Map["gitops"].Seq[0].Map["mode"].Scalar != "renovate" {
		t.Fatalf("comment not stripped: %+v", root.Map["gitops"].Seq[0].Map["mode"])
	}
	if dt := root.Map["release"].Map["dispatch_trigger"]; dt.Scalar != "true" || !dt.Quoted {
		t.Fatalf("quoted scalar=%+v", dt)
	}
}

func TestParseYAMLErrors(t *testing.T) {
	tests := map[string]string{
		"tab indent":        "a:\n\tb: 1\n",
		"duplicate key":     "a: 1\na: 2\n",
		"bad indent":        "a:\n   b: 1\n",
		"anchor":            "a: &x 1\n",
		"flow map":          "a: {b: 1}\n",
		"multiline scalar":  "a: |\n  text\n",
		"seq under scalar":  "a: 1\n  - b\n",
		"missing value":     "a:\n",
		"unterminated quote": "a: \"x\n",
	}
	for name, src := range tests {
		t.Run(name, func(t *testing.T) {
			if _, err := parseYAML(src); err == nil || !strings.HasPrefix(err.Error(), "line ") {
				t.Fatalf("err=%v", err)
			}
		})
	}
}

func TestParseYAMLEmptyIsEmptyMap(t *testing.T) {
	root, err := parseYAML("# nothing\n\n")
	if err != nil || root.Kind != KindMap || len(root.Keys) != 0 {
		t.Fatalf("root=%+v err=%v", root, err)
	}
}
```

- [ ] **Step 2: Run to verify failure**

Run: `go test ./internal/manifest/ -run TestParseYAML -v`
Expected: FAIL — package does not exist / `parseYAML` undefined.

- [ ] **Step 3: Implement**

```go
// Package manifest reads the adopter manifest `.github/onboard.yml`.
//
// The catalog CLI has no external dependencies, so this file implements the
// small YAML subset the manifest schema needs — block mappings, block
// sequences, flow sequences of scalars, quoted/plain scalars, comments —
// and rejects everything else with a line-numbered error. It is not a YAML
// parser; it is a manifest reader that happens to accept YAML syntax.
package manifest

import (
	"fmt"
	"strings"
)

type Kind int

const (
	KindMap Kind = iota
	KindSeq
	KindScalar
)

type Node struct {
	Kind   Kind
	Line   int
	Keys   []string
	Map    map[string]*Node
	Seq    []*Node
	Scalar string
	Quoted bool
}

type line struct {
	no     int
	indent int
	text   string // content without indentation and without comment
}

func parseYAML(src string) (*Node, error) {
	lines, err := tokenize(src)
	if err != nil {
		return nil, err
	}
	if len(lines) == 0 {
		return &Node{Kind: KindMap, Map: map[string]*Node{}, Line: 1}, nil
	}
	p := &parser{lines: lines}
	node, err := p.block(lines[0].indent)
	if err != nil {
		return nil, err
	}
	if p.pos < len(p.lines) {
		return nil, fmt.Errorf("line %d: unexpected indentation", p.lines[p.pos].no)
	}
	if node.Kind != KindMap {
		return nil, fmt.Errorf("line %d: document root must be a mapping", lines[0].no)
	}
	return node, nil
}

func tokenize(src string) ([]line, error) {
	var out []line
	for i, raw := range strings.Split(src, "\n") {
		no := i + 1
		if strings.Contains(raw, "\t") {
			return nil, fmt.Errorf("line %d: tabs are not allowed", no)
		}
		text := stripComment(raw)
		if strings.TrimSpace(text) == "" {
			continue
		}
		indent := len(text) - len(strings.TrimLeft(text, " "))
		if indent%2 != 0 {
			return nil, fmt.Errorf("line %d: indentation must be a multiple of two spaces", no)
		}
		out = append(out, line{no: no, indent: indent, text: strings.TrimSpace(text)})
	}
	return out, nil
}

// stripComment removes a trailing `# …` that is not inside quotes.
func stripComment(s string) string {
	inSingle, inDouble := false, false
	for i, r := range s {
		switch {
		case r == '\'' && !inDouble:
			inSingle = !inSingle
		case r == '"' && !inSingle:
			inDouble = !inDouble
		case r == '#' && !inSingle && !inDouble && (i == 0 || s[i-1] == ' '):
			return s[:i]
		}
	}
	return s
}

type parser struct {
	lines []line
	pos   int
}

func (p *parser) block(indent int) (*Node, error) {
	l := p.lines[p.pos]
	if l.indent != indent {
		return nil, fmt.Errorf("line %d: bad indentation", l.no)
	}
	if strings.HasPrefix(l.text, "- ") || l.text == "-" {
		return p.sequence(indent)
	}
	return p.mapping(indent)
}

func (p *parser) mapping(indent int) (*Node, error) {
	node := &Node{Kind: KindMap, Map: map[string]*Node{}, Line: p.lines[p.pos].no}
	for p.pos < len(p.lines) {
		l := p.lines[p.pos]
		if l.indent < indent {
			break
		}
		if l.indent > indent {
			return nil, fmt.Errorf("line %d: unexpected indentation", l.no)
		}
		if strings.HasPrefix(l.text, "- ") || l.text == "-" {
			return nil, fmt.Errorf("line %d: sequence item inside mapping", l.no)
		}
		key, rest, ok := splitKey(l.text)
		if !ok {
			return nil, fmt.Errorf("line %d: expected `key: value`", l.no)
		}
		if _, dup := node.Map[key]; dup {
			return nil, fmt.Errorf("line %d: duplicate key %q", l.no, key)
		}
		p.pos++
		var child *Node
		var err error
		if rest == "" {
			if p.pos >= len(p.lines) || p.lines[p.pos].indent <= indent {
				return nil, fmt.Errorf("line %d: key %q has no value", l.no, key)
			}
			child, err = p.block(p.lines[p.pos].indent)
			if err == nil {
				child.Line = l.no // a block value is reported at its key's line
			}
		} else {
			child, err = scalarOrFlow(rest, l.no)
		}
		if err != nil {
			return nil, err
		}
		node.Keys = append(node.Keys, key)
		node.Map[key] = child
	}
	return node, nil
}

func (p *parser) sequence(indent int) (*Node, error) {
	node := &Node{Kind: KindSeq, Line: p.lines[p.pos].no}
	for p.pos < len(p.lines) {
		l := p.lines[p.pos]
		if l.indent < indent {
			break
		}
		if l.indent > indent {
			return nil, fmt.Errorf("line %d: unexpected indentation", l.no)
		}
		if !strings.HasPrefix(l.text, "- ") && l.text != "-" {
			return nil, fmt.Errorf("line %d: expected sequence item", l.no)
		}
		rest := strings.TrimSpace(strings.TrimPrefix(l.text, "-"))
		if rest == "" {
			return nil, fmt.Errorf("line %d: empty sequence item", l.no)
		}
		if _, _, isMap := splitKey(rest); isMap && !strings.HasPrefix(rest, "[") && !strings.HasPrefix(rest, "\"") && !strings.HasPrefix(rest, "'") {
			// `- key: value`: re-home the inline first key at indent+2 and
			// parse the item as a mapping so continuation keys line up.
			p.lines[p.pos] = line{no: l.no, indent: indent + 2, text: rest}
			item, err := p.mapping(indent + 2)
			if err != nil {
				return nil, err
			}
			node.Seq = append(node.Seq, item)
			continue
		}
		item, err := scalarOrFlow(rest, l.no)
		if err != nil {
			return nil, err
		}
		p.pos++
		node.Seq = append(node.Seq, item)
	}
	return node, nil
}

// splitKey splits `key: rest`; a key is a plain token up to the first `: `
// (or trailing `:`).
func splitKey(text string) (key, rest string, ok bool) {
	if strings.HasPrefix(text, "\"") || strings.HasPrefix(text, "'") || strings.HasPrefix(text, "[") {
		return "", "", false
	}
	if strings.HasSuffix(text, ":") {
		return strings.TrimSpace(text[:len(text)-1]), "", true
	}
	i := strings.Index(text, ": ")
	if i <= 0 {
		return "", "", false
	}
	return strings.TrimSpace(text[:i]), strings.TrimSpace(text[i+2:]), true
}

func scalarOrFlow(text string, no int) (*Node, error) {
	switch {
	case strings.HasPrefix(text, "["):
		if !strings.HasSuffix(text, "]") {
			return nil, fmt.Errorf("line %d: unterminated flow sequence", no)
		}
		node := &Node{Kind: KindSeq, Line: no}
		inner := strings.TrimSpace(text[1 : len(text)-1])
		if inner == "" {
			return node, nil
		}
		for _, part := range splitFlow(inner) {
			item, err := scalar(strings.TrimSpace(part), no)
			if err != nil {
				return nil, err
			}
			node.Seq = append(node.Seq, item)
		}
		return node, nil
	case strings.HasPrefix(text, "{"):
		return nil, fmt.Errorf("line %d: flow mappings are not supported", no)
	case strings.HasPrefix(text, "&") || strings.HasPrefix(text, "*") || strings.HasPrefix(text, "!"):
		return nil, fmt.Errorf("line %d: anchors, aliases and tags are not supported", no)
	case text == "|" || text == ">" || strings.HasPrefix(text, "|") || strings.HasPrefix(text, ">"):
		return nil, fmt.Errorf("line %d: block scalars are not supported", no)
	}
	return scalar(text, no)
}

// splitFlow splits on commas outside quotes.
func splitFlow(s string) []string {
	var parts []string
	start, inSingle, inDouble := 0, false, false
	for i, r := range s {
		switch {
		case r == '\'' && !inDouble:
			inSingle = !inSingle
		case r == '"' && !inSingle:
			inDouble = !inDouble
		case r == ',' && !inSingle && !inDouble:
			parts = append(parts, s[start:i])
			start = i + 1
		}
	}
	return append(parts, s[start:])
}

func scalar(text string, no int) (*Node, error) {
	if len(text) >= 1 && (text[0] == '"' || text[0] == '\'') {
		q := text[0]
		if len(text) < 2 || text[len(text)-1] != q {
			return nil, fmt.Errorf("line %d: unterminated quoted string", no)
		}
		return &Node{Kind: KindScalar, Line: no, Scalar: text[1 : len(text)-1], Quoted: true}, nil
	}
	return &Node{Kind: KindScalar, Line: no, Scalar: text}, nil
}
```

- [ ] **Step 4: Run tests**

Run: `go test ./internal/manifest/ -run TestParseYAML -v -cover`
Expected: PASS, coverage ≥ 90 % for the file. Add a test case for any uncovered error branch (`go tool cover -html` shows them).

- [ ] **Step 5: Commit**

```bash
git add internal/manifest/yaml.go internal/manifest/yaml_test.go
git commit -m "feat(manifest): zero-dependency YAML-subset reader for the adopter manifest"
```

---

### Task 4: Manifest schema v1 (`internal/manifest/manifest.go`)

**Files:**
- Create: `internal/manifest/manifest.go`, `internal/manifest/manifest_test.go`

**Interfaces:**
- Produces:
  ```go
  const FileName = ".github/onboard.yml"

  type Manifest struct {
      Schema     int
      Components []Component   // nil when the key is absent
      Workflows  *Workflows
      Release    *Release
      GitOps     []Consumer
  }
  type Component struct {
      Path, Language, Type, Image, Context, Platforms string
      Release  *bool
      Unittest bool
      Dockerfiles []DockerfileSpec
      Line int
  }
  type DockerfileSpec struct {
      Path, Image, Context, Platforms string
      Release *bool
      Line int
  }
  type Workflows struct{ E2E *E2E }
  type E2E struct{ Script, Schedule string }
  type Release struct{ DispatchTrigger bool }
  type Consumer struct {
      Repo  string
      Scope []string
      Mode  string // "renovate"
  }

  // Load reads <repoPath>/.github/onboard.yml. found=false (nil error) when absent.
  func Load(repoPath string) (m *Manifest, sha256Hex string, found bool, err error)
  func Parse(src []byte) (*Manifest, error)
  ```
  Errors are `fmt.Errorf("%s: line %d: …", FileName, line)`.

- [ ] **Step 1: Failing tests**

```go
package manifest

import (
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
```

- [ ] **Step 2: Run to verify failure**

Run: `go test ./internal/manifest/ -run 'TestParse(Valid|Manifest)|TestLoad' -v`
Expected: FAIL — undefined `Parse`, `Load`, `FileName`.

- [ ] **Step 3: Implement**

```go
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
```

- [ ] **Step 4: Run tests**

Run: `go test ./internal/manifest/ -v -cover`
Expected: PASS, coverage ≥ 90 %. Adjust expected substrings in the table only if the message wording differs by punctuation, never by content.

- [ ] **Step 5: Vet + lint + commit**

Run: `go vet ./... && golangci-lint run ./internal/manifest/`
Expected: clean.

```bash
git add internal/manifest/manifest.go internal/manifest/manifest_test.go
git commit -m "feat(manifest): schema v1 types, strict validation and Load"
```

---

### Task 5: Profile fields

**Files:**
- Modify: `internal/domain/profile.go`

**Interfaces:**
- Produces (all `omitempty`, so existing profile JSON is unchanged when unset):
  ```go
  // Profile
  ManifestSHA256 string            `json:"manifest_sha256,omitempty"`
  Workflows      *WorkflowsSpec    `json:"workflows,omitempty"`
  Release        *ReleaseSpec      `json:"release,omitempty"`
  Consumers      []GitOpsConsumer  `json:"gitops_consumers,omitempty"`
  // Component
  Unittest bool   `json:"unittest,omitempty"`
  Version  string `json:"version,omitempty"` // chart components: Chart.yaml version
  // Dockerfile
  Context   string `json:"context,omitempty"`   // repo-relative; empty = component path
  Platforms string `json:"platforms,omitempty"`
  ```
  ```go
  type WorkflowsSpec struct{ E2E *E2ESpec `json:"e2e,omitempty"` }
  type E2ESpec struct { Script string `json:"script"`; Schedule string `json:"schedule,omitempty"` }
  type ReleaseSpec struct{ DispatchTrigger bool `json:"dispatch_trigger"` }
  type GitOpsConsumer struct { Repo string `json:"repo"`; Scope []string `json:"scope,omitempty"`; Mode string `json:"mode"` }
  ```
  `ImageNameSource` gains the value `"manifest"`. (`Profile.GitOps` — the cluster-repo *signal* — is untouched; consumers live under `gitops_consumers`.)

- [ ] **Step 1: Test — existing profile JSON is byte-identical**

Append to `internal/app/detect/service_test.go`:

```go
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
```
(add `"encoding/json"` and `"strings"` to the test imports if missing.)

- [ ] **Step 2: Add the fields** exactly as listed under Interfaces, in `profile.go`.

- [ ] **Step 3: Run**

Run: `go test ./internal/domain/ ./internal/app/detect/ -run TestProfileJSONHasNoNewKeysWithoutManifest -v`
Expected: PASS.

- [ ] **Step 4: Commit**

```bash
git add internal/domain/profile.go internal/app/detect/service_test.go
git commit -m "feat(domain): optional manifest-driven profile fields"
```

---

### Task 6: Detect — root-marker fallback fix + warning

**Files:**
- Modify: `internal/app/detect/service.go:146-157` (`detectComponents`), `:610-650` (warnings)
- Create: `tests/fixtures/onboard/go-root-subdir-dockerfile/{go.mod,main.go,images/api/Dockerfile,images/worker/Dockerfile}`
- Test: `internal/app/detect/service_test.go`

**Interfaces:**
- Produces: warning code `subdir_dockerfiles_unassigned` with `Path` = comma-joined orphaned Dockerfile paths.

- [ ] **Step 1: Fixture**

```
tests/fixtures/onboard/go-root-subdir-dockerfile/go.mod        → "module example.com/root\n\ngo 1.22\n"
tests/fixtures/onboard/go-root-subdir-dockerfile/main.go       → "package main\n\nfunc main() {}\n"
tests/fixtures/onboard/go-root-subdir-dockerfile/images/api/Dockerfile    → "FROM scratch\nCOPY go.mod /\n"
tests/fixtures/onboard/go-root-subdir-dockerfile/images/worker/Dockerfile → "FROM scratch\nCOPY go.mod /\n"
```

- [ ] **Step 2: Failing test**

```go
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
```

- [ ] **Step 3: Run to verify failure**

Run: `go test ./internal/app/detect/ -run TestRootMarkerWinsOverSubdirDockerfiles -v`
Expected: FAIL — today `Monorepo=true` with two `images/*` components.

- [ ] **Step 4: Implement**

In `detectComponents` change lines 149-154 to:

```go
	if len(paths) == 0 && !rootHasMarker {
		paths = fallbackMarkerPaths(repo)
	}
	if len(paths) == 0 && !rootHasMarker {
		paths = fallbackDockerfilePaths(repo)
	}
```

Add after `noReleaseEligibleWarnings`:

```go
// unassignedSubdirDockerfileWarnings fires when the repo resolved to a single
// root component but carries Dockerfiles in sub-directories that no component
// owns. Before the root-marker fix those Dockerfiles hijacked the layout; now
// they are ignored loudly and the adopter manifest is the way to claim them.
func unassignedSubdirDockerfileWarnings(repo string, components []domain.Component) []domain.Warning {
	if len(components) != 1 || components[0].Path != "." {
		return nil
	}
	var orphans []string
	_ = filepath.WalkDir(repo, func(path string, d fs.DirEntry, err error) error {
		if err != nil || d.IsDir() {
			return nil
		}
		name := d.Name()
		if name != "Dockerfile" && name != "Containerfile" && !strings.HasPrefix(name, "Dockerfile.") && !strings.HasPrefix(name, "Containerfile.") {
			return nil
		}
		rel, _ := filepath.Rel(repo, path)
		rel = filepath.ToSlash(rel)
		if strings.Contains(rel, "/") && !strings.HasPrefix(rel, ".git/") {
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
```

In `Detect` after the `noReleaseEligibleWarnings` append add:

```go
	profile.Warnings = append(profile.Warnings, unassignedSubdirDockerfileWarnings(req.RepoPath, profile.Components)...)
```

(Task 7 makes this call conditional on "no manifest".)

- [ ] **Step 5: Run all detect tests**

Run: `go test ./internal/app/detect/ -v`
Expected: PASS, including `TestFallbackDockerfileMonorepo` (no root marker → unchanged) and `TestMonorepoDetection`.

- [ ] **Step 6: Bash twin**

In `scripts/lib/onboard-detect-lib.sh` `detect_components()` (line 236ff) apply the same guard to the Dockerfile fallback (the Bash mirror of lines 152-154): only run the Dockerfile fallback when the root has no marker. Add a bats case in `tests/shell/onboard-detect.bats`:

```bash
@test "detect: root go.mod wins over sub-directory Dockerfiles" {
  run "$DETECT" --profile-json "$FIX/go-root-subdir-dockerfile"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.monorepo' <<< "$output")" = "false" ]
  [ "$(jq -r '.components | length' <<< "$output")" = "1" ]
  [ "$(jq -r '.components[0].path' <<< "$output")" = "." ]
}
```

Run: `bats tests/shell/onboard-detect.bats`
Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add internal/app/detect/service.go internal/app/detect/service_test.go scripts/lib/onboard-detect-lib.sh tests/shell/onboard-detect.bats tests/fixtures/onboard/go-root-subdir-dockerfile
git commit -m "fix(detect): keep the root component when sub-directories carry Dockerfiles"
```

---

### Task 7: Detect — manifest-driven components

**Files:**
- Modify: `internal/app/detect/service.go` (`Detect` 47-124, new `componentsFromManifest`, `detectLegacyCI` owned set, `inventoryDockerfiles`)
- Create: `tests/fixtures/onboard/go-root-multi-image/` (source side)
- Test: `internal/app/detect/service_test.go`

**Interfaces:**
- Consumes: `manifest.Load`, `manifest.Manifest` (Task 4); profile fields (Task 5).
- Produces: profile with `manifest_sha256`, authoritative components, `dockerfiles[].context/platforms`, `image_name_source: "manifest"`, `components[].unittest/version`, `workflows`, `release`, `gitops_consumers`. `inventoryDockerfiles` gains a third parameter: `inventoryDockerfiles(repo, componentPath, imageOverride string)`.

- [ ] **Step 1: Fixture (source side)**

```
tests/fixtures/onboard/go-root-multi-image/
  go.mod                      "module example.com/multi\n\ngo 1.22\n"
  cmd/tool/main.go            "package main\n\nfunc main() {}\n"
  images/tools/Dockerfile     "FROM scratch\nCOPY go.mod go.sum ./\nCOPY . .\n"
  images/api/Dockerfile       "FROM scratch\nCOPY images/api/entrypoint.sh /\n"
  images/api/entrypoint.sh    "#!/bin/sh\n"
  images/worker/Dockerfile    "FROM scratch\nCOPY images/worker/run.sh /\n"
  images/worker/run.sh        "#!/bin/sh\n"
  charts/demo/Chart.yaml      "apiVersion: v2\nname: demo\nversion: 0.3.0\ntype: application\n"
  charts/demo/values.yaml     "image:\n  tag: v0.0.0\n"
  charts/demo/templates/configmap.yaml  "apiVersion: v1\nkind: ConfigMap\nmetadata:\n  name: demo\n"
  charts/demo/tests/configmap_test.yaml "suite: cm\ntemplates: [configmap.yaml]\ntests:\n  - it: exists\n    asserts:\n      - isKind:\n          of: ConfigMap\n"
  test/e2e/run.sh             "#!/usr/bin/env bash\nexit 0\n"
  .github/workflows/e2e.yml   "name: e2e\non: {}\njobs: {}\n"
  .github/onboard.yml:
```
```yaml
schema: 1
components:
  - path: .
    language: go
    dockerfiles:
      - path: images/tools/Dockerfile
        image: acme/multi/tools
  - path: images/api
    image: acme/multi/api
    context: .
  - path: images/worker
    image: acme/multi/worker
    context: .
    platforms: linux/amd64
  - path: charts/demo
    type: helm
    unittest: true
workflows:
  e2e:
    script: test/e2e/run.sh
    schedule: "0 3 * * *"
release:
  dispatch_trigger: true
gitops:
  - repo: acme/gitops-prod
    scope: [kubernetes/apps/multi/**]
  - repo: acme/gitops-lab
```

- [ ] **Step 2: Failing test**

```go
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
	if root.PrimaryLanguage != "go" || len(root.Dockerfiles) != 1 {
		t.Fatalf("root=%+v", root)
	}
	if d := root.Dockerfiles[0]; d.Path != "images/tools/Dockerfile" || d.ImageName != "acme/multi/tools" || d.ImageNameSource != "manifest" || d.Context != "" || !d.ReleaseEligible {
		t.Fatalf("tools=%+v", d)
	}
	if root.ReleaseSignals.ChartYAML != nil {
		t.Fatalf("chart owned by charts/demo must not be a root signal: %+v", root.ReleaseSignals)
	}
	api := p.Components[1]
	if api.PrimaryLanguage != "generic" || len(api.Dockerfiles) != 1 || api.Dockerfiles[0].Path != "Dockerfile" || api.Dockerfiles[0].ImageName != "acme/multi/api" || api.Dockerfiles[0].Context != "." {
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
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			repo := write(t, tt.manifest, tt.files)
			_, err := (Service{}).Detect(context.Background(), Request{RepoPath: repo})
			if err == nil || !strings.Contains(err.Error(), tt.want) {
				t.Fatalf("err=%v want %q", err, tt.want)
			}
		})
	}
}
```

- [ ] **Step 3: Run to verify failure**

Run: `go test ./internal/app/detect/ -run 'TestManifest' -v`
Expected: FAIL (fields empty / wrong component set).

- [ ] **Step 4: Implement**

Import `"github.com/serverkraken/reusable-workflows/internal/manifest"`.

In `Detect`, replace

```go
	components, err := detectComponents(req.RepoPath)
	if err != nil {
		return Result{}, err
	}
```
with
```go
	man, manifestSHA, hasManifest, err := manifest.Load(req.RepoPath)
	if err != nil {
		return Result{}, err
	}
	var components []domain.Component
	if hasManifest && man.Components != nil {
		components, err = componentsFromManifest(req.RepoPath, man)
	} else {
		components, err = detectComponents(req.RepoPath)
	}
	if err != nil {
		return Result{}, err
	}
	var declared []string
	if hasManifest && man.Workflows != nil && man.Workflows.E2E != nil {
		declared = append(declared, "e2e.yml")
	}
```
change `legacy, err := detectLegacyCI(req.RepoPath)` to `detectLegacyCI(req.RepoPath, declared)`, and after building `profile` add:

```go
	if hasManifest {
		profile.ManifestSHA256 = manifestSHA
		if man.Workflows != nil && man.Workflows.E2E != nil {
			profile.Workflows = &domain.WorkflowsSpec{E2E: &domain.E2ESpec{Script: man.Workflows.E2E.Script, Schedule: man.Workflows.E2E.Schedule}}
		}
		if man.Release != nil {
			profile.Release = &domain.ReleaseSpec{DispatchTrigger: man.Release.DispatchTrigger}
		}
		for _, c := range man.GitOps {
			profile.Consumers = append(profile.Consumers, domain.GitOpsConsumer{Repo: c.Repo, Scope: c.Scope, Mode: c.Mode})
		}
	}
```
and make the Task-6 warning conditional: `if !hasManifest { profile.Warnings = append(profile.Warnings, unassignedSubdirDockerfileWarnings(...)...) }`.

Image-only components (a manifest component with Dockerfiles but no language marker, like `images/api`) are build units, not code — they must not trigger `no_lint_test_atom`. Change the `unsupportedLanguageWarnings` call to pass `hasManifest` and skip such components:

```go
func unsupportedLanguageWarnings(components []domain.Component, manifest bool) []domain.Warning {
	…
	for _, c := range components {
		if manifest && c.PrimaryLanguage == "generic" && len(c.Dockerfiles) > 0 {
			continue // image-only component declared by the manifest
		}
		if seen[c.PrimaryLanguage] || re.MatchString(c.PrimaryLanguage) {
```
(non-manifest detection is unchanged: fallback Dockerfile monorepos keep their warning).

`detectLegacyCI` signature → `func detectLegacyCI(repo string, declared []string) ([]domain.LegacyCI, error)`; after the `owned` map literal add `for _, d := range declared { owned[d] = true }`.

`inventoryDockerfiles(repo, componentPath string)` → `inventoryDockerfiles(repo, componentPath, imageOverride string)`: when `imageOverride != ""`, set `image = imageOverride; source = "manifest"` for every file (callers in `detectComponents` pass `""`).

New function:

```go
// componentsFromManifest builds the component list from an authoritative
// manifest. Per component, anything the manifest leaves out is detected the
// same way detectComponents would (languages, Dockerfiles in the component
// directory, release signals, cgo).
func componentsFromManifest(repo string, m *manifest.Manifest) ([]domain.Component, error) {
	paths := map[string]bool{}
	for _, mc := range m.Components {
		paths[mc.Path] = true
	}
	out := make([]domain.Component, 0, len(m.Components))
	for _, mc := range m.Components {
		dir := filepath.Join(repo, mc.Path)
		if !dirExists(dir) {
			return nil, fmt.Errorf("%s: line %d: component path %s does not exist", manifest.FileName, mc.Line, mc.Path)
		}
		langs := languagesAt(dir)
		if mc.Language != "" {
			langs = append([]string{mc.Language}, without(langs, mc.Language)...)
		}
		if mc.Type == "helm" && !containsString(langs, "helm") {
			langs = append([]string{"helm"}, langs...)
		}
		if langs == nil {
			langs = []string{}
		}
		primary := "generic"
		if len(langs) > 0 {
			primary = langs[0]
		}

		dockerfiles := inventoryDockerfiles(repo, mc.Path, mc.Image)
		if mc.Image != "" || mc.Context != "" || mc.Platforms != "" || mc.Release != nil {
			if len(dockerfiles) != 1 {
				return nil, fmt.Errorf("%s: line %d: component %s declares image/context/platforms/release but has %d Dockerfiles; use dockerfiles[] instead", manifest.FileName, mc.Line, mc.Path, len(dockerfiles))
			}
			applyDockerfileSpec(&dockerfiles[0], mc.Context, mc.Platforms, mc.Release)
		}
		for _, spec := range mc.Dockerfiles {
			full := filepath.Join(repo, spec.Path)
			if !has(filepath.Dir(full), filepath.Base(full)) {
				return nil, fmt.Errorf("%s: line %d: %s: no such file", manifest.FileName, spec.Line, spec.Path)
			}
			rel, err := filepath.Rel(mc.Path, spec.Path)
			if err != nil || strings.HasPrefix(rel, "..") {
				return nil, fmt.Errorf("%s: line %d: %s is outside component %s", manifest.FileName, spec.Line, spec.Path, mc.Path)
			}
			name := filepath.Base(spec.Path)
			image, source := spec.Image, "manifest"
			if image == "" {
				if image = readImageOverride(full); image != "" {
					source = "override"
				} else {
					image, source = deriveImageName(name, filepath.ToSlash(filepath.Dir(spec.Path))), "derived"
				}
			}
			eligible := name == "Dockerfile" || name == "Containerfile"
			if o := readReleaseOverride(full); o != nil {
				eligible = *o
			}
			df := domain.Dockerfile{Path: filepath.ToSlash(rel), ImageName: image, ImageNameSource: source, ReleaseEligible: eligible}
			applyDockerfileSpec(&df, spec.Context, spec.Platforms, spec.Release)
			dockerfiles = append(dockerfiles, df)
		}
		sort.Slice(dockerfiles, func(i, j int) bool { return dockerfiles[i].Path < dockerfiles[j].Path })
		if ctx, ok := sharedContext(mc.Path, dockerfiles); !ok {
			return nil, fmt.Errorf("%s: line %d: Dockerfiles of component %s must share one build context (docker-build-multi has a single context), got %s", manifest.FileName, mc.Line, mc.Path, ctx)
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
			Role:              role(repo, mc.Path, dockerfiles),
			Dockerfiles:       dockerfiles,
			ReleaseSignals:    signals,
			CGO:               detectCGO(repo, mc.Path, primary),
			Unittest:          mc.Unittest,
		}
		if primary == "helm" {
			c.Version = chartVersion(filepath.Join(dir, "Chart.yaml"))
		}
		out = append(out, c)
	}
	return out, nil
}

func applyDockerfileSpec(df *domain.Dockerfile, ctx, platforms string, release *bool) {
	if ctx != "" {
		df.Context = ctx
	}
	if platforms != "" {
		df.Platforms = platforms
	}
	if release != nil {
		df.ReleaseEligible = *release
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

// chartVersion reads `version:` from a Chart.yaml; empty when absent.
func chartVersion(path string) string {
	for _, l := range strings.Split(mustRead(path), "\n") {
		if strings.HasPrefix(l, "version:") {
			return strings.Trim(strings.TrimSpace(strings.TrimPrefix(l, "version:")), `"'`)
		}
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

func containsString(list []string, v string) bool {
	for _, x := range list {
		if x == v {
			return true
		}
	}
	return false
}
```

`role()` returns `"service"` whenever Dockerfiles exist — the root with the attached `tools` image therefore becomes `service`; that is intended (it ships an image).

- [ ] **Step 5: Run**

Run: `go test ./internal/app/detect/ -v -cover`
Expected: PASS; coverage ≥ 90 %. Also `go test ./internal/adapters/cli/` (detect output marshals the new fields automatically).

- [ ] **Step 6: Commit**

```bash
git add internal/app/detect/service.go internal/app/detect/service_test.go tests/fixtures/onboard/go-root-multi-image
git commit -m "feat(detect): read the adopter manifest as the authoritative component layout"
```

---

### Task 8: Bash detect fails loud on a manifest

**Files:**
- Modify: `scripts/onboard-detect.sh` (after line 49, after line 118, after line 136)
- Test: `tests/shell/onboard-detect.bats`

- [ ] **Step 1: Failing bats test**

```bash
@test "detect: refuses a repo with an adopter manifest (Go CLI required)" {
  run "$DETECT" --profile-json "$FIX/go-root-multi-image"
  [ "$status" -eq 1 ]
  [[ "$output" == *"adopter manifest"* ]]
  [[ "$output" == *"use_go_cli"* ]]
  run "$DETECT" "$FIX/go-root-multi-image"
  [ "$status" -eq 1 ]
  run "$DETECT" --emit-both "$FIX/go-root-multi-image"
  [ "$status" -eq 1 ]
}
```

Run: `bats tests/shell/onboard-detect.bats -f "adopter manifest"`
Expected: FAIL (exit 0 today).

- [ ] **Step 2: Implement**

Add a helper near the top of `scripts/onboard-detect.sh` (after `SCRIPT_DIR=`):

```bash
# The Bash engine has no manifest parser by design (see
# docs/operations.md § Adopter Manifest). Fail loud instead of rendering a
# wrong layout; onboard.yml's use_go_cli=true routes such repos to sk-workflows.
refuse_manifest() {
  if [[ -f "$1/.github/onboard.yml" ]]; then
    echo "::error::$1/.github/onboard.yml: adopter manifest present — the Bash detector does not support manifests; dispatch with use_go_cli=true (sk-workflows detect)" >&2
    exit 1
  fi
}
```

Call `refuse_manifest "$REPO_PATH"` immediately after each of the three `-d "$REPO_PATH"` validations (after line 49, after line 118, after line 136).

- [ ] **Step 3: Run**

Run: `bats tests/shell/onboard-detect.bats && shellcheck scripts/onboard-detect.sh`
Expected: PASS / clean.

- [ ] **Step 4: Commit**

```bash
git add scripts/onboard-detect.sh tests/shell/onboard-detect.bats
git commit -m "fix(onboard-detect): bash engine refuses repos with an adopter manifest"
```

---

### Task 9: Render — `e2e.yml` in the render set, lock `inputs`

**Files:**
- Modify: `internal/domain/lock.go`, `internal/app/render/service.go:128-180` (`plannedFiles`, `lockPaths`), `:248-294` (`writeLock`, `encodeLock`), the `Render` call site of `writeLock`
- Test: `internal/app/render/service_test.go`

**Interfaces:**
- Produces: lock JSON
  ```json
  {
    "schema_version": 1,
    "catalog_version": "v4",
    "rendered_against": "v4.14.0",
    "rendered_at": "…",
    "inputs": {
      "manifest_sha256": "sha256:<hex>"
    },
    "files": { … }
  }
  ```
  `inputs` is written **only** when `profile.manifest_sha256 != ""`. Domain: `OnboardLock.Inputs *LockInputs \`json:"inputs,omitempty"\``, `type LockInputs struct { ManifestSHA256 string \`json:"manifest_sha256"\` }`. New rendered file `.github/workflows/e2e.yml` from `skeletons/e2e.yml.tmpl` when `profile.workflows.e2e` is set; it is appended after `ci-android.yml` and before the release-please configs.

- [ ] **Step 1: Failing tests**

```go
func TestRenderManifestProfileAddsE2EAndLockInputs(t *testing.T) {
	target := t.TempDir()
	profile := `{"schema_version":1,"target_repo":"acme/multi","default_branch":"main","current_version":"1.0.0","monorepo":true,
	  "manifest_sha256":"` + strings.Repeat("ab", 32) + `",
	  "workflows":{"e2e":{"script":"test/e2e/run.sh","schedule":"0 3 * * *"}},
	  "components":[{"path":".","languages":["go"],"primary_language":"go","release_please_type":"go","role":"service","dockerfiles":[],"release_signals":{"goreleaser_config":null,"chart_yaml":null,"flutter_android":false},"cgo":false},
	                {"path":"images/api","languages":[],"primary_language":"generic","release_please_type":"simple","role":"service","dockerfiles":[],"release_signals":{"goreleaser_config":null,"chart_yaml":null,"flutter_android":false},"cgo":false}],
	  "legacy_ci":[],"topics":[],"warnings":[]}`
	profilePath := filepath.Join(t.TempDir(), "profile.json")
	if err := os.WriteFile(profilePath, []byte(profile), 0o644); err != nil {
		t.Fatal(err)
	}
	templates := &fakeTemplates{content: map[string]string{}}
	svc := Service{Templates: templates, Now: func() time.Time { return time.Date(2026, 8, 21, 9, 0, 0, 0, time.UTC) }}
	if err := svc.Render(context.Background(), Request{CatalogPath: t.TempDir(), TargetPath: target, ProfileJSONPath: profilePath, PinVersion: "v4", RenderedAgainst: "v4.14.0"}); err != nil {
		t.Fatal(err)
	}
	if !calledTemplate(templates.calls, "e2e.yml.tmpl") {
		t.Fatal("e2e.yml.tmpl not rendered for a manifest with workflows.e2e")
	}
	raw, err := os.ReadFile(filepath.Join(target, ".github", "onboard.lock.json"))
	if err != nil {
		t.Fatal(err)
	}
	lock := string(raw)
	wantInputs := "  \"rendered_at\": \"2026-08-21T09:00:00Z\",\n  \"inputs\": {\n    \"manifest_sha256\": \"sha256:" + strings.Repeat("ab", 32) + "\"\n  },\n  \"files\": {"
	if !strings.Contains(lock, wantInputs) {
		t.Fatalf("lock inputs block missing or misplaced:\n%s", lock)
	}
	if !strings.Contains(lock, `".github/workflows/e2e.yml": "sha256:`) {
		t.Fatalf("e2e.yml not tracked in lock:\n%s", lock)
	}
}

func TestRenderWithoutManifestWritesNoInputsBlock(t *testing.T) {
	// reuse the single-service profile fixture used by
	// TestRenderSingleServiceWritesFilesSubstitutesRepoAndLock
	target, templates := renderSingleService(t) // extract this helper from that test if it does not exist yet
	_ = templates
	raw, err := os.ReadFile(filepath.Join(target, ".github", "onboard.lock.json"))
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(string(raw), `"inputs"`) || strings.Contains(string(raw), "e2e.yml") {
		t.Fatalf("manifest-less lock must be unchanged:\n%s", raw)
	}
}
```
(`Service.Now`/`Templates` field names: use whatever `TestRenderSingleServiceWritesFilesSubstitutesRepoAndLock` uses — read lines 55-129 and mirror its construction; if no `renderSingleService` helper exists, extract one from that test in this step.)

- [ ] **Step 2: Run to verify failure**

Run: `go test ./internal/app/render/ -run 'TestRenderManifestProfile|TestRenderWithoutManifest' -v`
Expected: FAIL.

- [ ] **Step 3: Implement**

`internal/domain/lock.go`:
```go
type LockInputs struct {
	ManifestSHA256 string `json:"manifest_sha256"`
}
```
and on `OnboardLock`: `Inputs *LockInputs \`json:"inputs,omitempty"\`` (after `RenderedAgainst`).

`plannedFiles` and `lockPaths`: after the `hasFlutterAndroid` block add
```go
	if profile.Workflows != nil && profile.Workflows.E2E != nil {
		files = append(files, renderFile{Template: "skeletons/e2e.yml.tmpl", Output: ".github/workflows/e2e.yml"})
	}
```
(and the string form in `lockPaths`).

`writeLock(targetPath, pinVersion, renderedAgainst, renderedAt string, files []string)` → add parameter `manifestSHA string`, pass through to `encodeLock(pinVersion, renderedAgainst, renderedAt, manifestSHA, files, hashes)`. In `encodeLock`, right after `writeStringField(&out, "rendered_at", renderedAt, true)` add:

```go
	if manifestSHA != "" {
		out.WriteString("  \"inputs\": {\n")
		fmt.Fprintf(&out, "    \"manifest_sha256\": %s\n", mustJSON("sha256:"+manifestSHA))
		out.WriteString("  },\n")
	}
```
with `func mustJSON(s string) string { b, _ := json.Marshal(s); return string(b) }`. Update the `Render` call site to pass `profile.ManifestSHA256` (the profile is already decoded by `readProfile`). Update `TestEncodeLockEmptyFiles` for the new parameter.

- [ ] **Step 4: Run**

Run: `go test ./internal/app/render/ ./internal/domain/ -v -cover`
Expected: PASS. `bats tests/shell/onboard-drift.bats` (byte-reproducible test on `go-repo`) PASS unchanged.

- [ ] **Step 5: Commit**

```bash
git add internal/domain/lock.go internal/app/render/service.go internal/app/render/service_test.go
git commit -m "feat(render): track e2e.yml and the manifest hash in the onboard lock"
```

---

### Task 10: Drift — manifest change is `stale-lock`

**Files:**
- Modify: `internal/app/drift/service.go:39-80` (`Drift`)
- Test: `internal/app/drift/service_test.go`

**Interfaces:**
- Consumes: `domain.OnboardLock.Inputs` (Task 9), `manifest.FileName` (Task 4).
- Produces: when the lock's `inputs.manifest_sha256` differs from the current file hash (either side missing counts as different), `Status = stale-lock`, `Modified = [".github/onboard.yml"]`, render-compare is skipped.

- [ ] **Step 1: Failing test**

```go
func TestDriftManifestHashMismatchIsStaleLock(t *testing.T) {
	repo := fixtureRepo(t, "v4") // helper used by TestRenderCompareStaleLockAndErrors
	// lock records a manifest hash, working tree has a different manifest
	lockPath := filepath.Join(repo, ".github", "onboard.lock.json")
	raw, _ := os.ReadFile(lockPath)
	var lock map[string]any
	_ = json.Unmarshal(raw, &lock)
	lock["inputs"] = map[string]string{"manifest_sha256": "sha256:" + strings.Repeat("00", 32)}
	updated, _ := json.Marshal(lock)
	_ = os.WriteFile(lockPath, updated, 0o644)
	_ = os.WriteFile(filepath.Join(repo, ".github", "onboard.yml"), []byte("schema: 1\n"), 0o644)

	detector := &fakeDetector{profile: []byte(`{"schema_version":1}`)}
	renderer := &fakeRenderer{files: renderedFixtureFiles()}
	res, err := (Service{Detector: detector, Renderer: renderer}).Drift(context.Background(), Request{TargetPath: repo, CatalogPath: t.TempDir(), CurrentVersion: "v4"})
	if err != nil {
		t.Fatal(err)
	}
	if res.Status != domain.DriftStaleLock || !reflect.DeepEqual(res.Modified, []string{".github/onboard.yml"}) {
		t.Fatalf("res=%+v", res)
	}
	if renderer.profile != "" {
		t.Fatal("render-compare must be skipped when the manifest hash already proves staleness")
	}
}

func TestDriftManifestHashMatchProceedsToRenderCompare(t *testing.T) {
	repo := fixtureRepo(t, "v4")
	content := []byte("schema: 1\n")
	sum := sha256.Sum256(content)
	lockPath := filepath.Join(repo, ".github", "onboard.lock.json")
	raw, _ := os.ReadFile(lockPath)
	var lock map[string]any
	_ = json.Unmarshal(raw, &lock)
	lock["inputs"] = map[string]string{"manifest_sha256": "sha256:" + hex.EncodeToString(sum[:])}
	updated, _ := json.Marshal(lock)
	_ = os.WriteFile(lockPath, updated, 0o644)
	_ = os.WriteFile(filepath.Join(repo, ".github", "onboard.yml"), content, 0o644)

	renderer := &fakeRenderer{files: renderedFixtureFiles()}
	res, err := (Service{Detector: &fakeDetector{profile: []byte(`{"schema_version":1}`)}, Renderer: renderer}).Drift(context.Background(), Request{TargetPath: repo, CatalogPath: t.TempDir(), CurrentVersion: "v4"})
	if err != nil || res.Status != domain.DriftClean || renderer.profile == "" {
		t.Fatalf("res=%+v err=%v profile=%q", res, err, renderer.profile)
	}
}
```

- [ ] **Step 2: Run to verify failure**

Run: `go test ./internal/app/drift/ -run TestDriftManifest -v`
Expected: FAIL.

- [ ] **Step 3: Implement**

In `Drift`, replace

```go
	if res.Status == domain.DriftClean {
		s.renderCompare(ctx, req, lock, &res)
	}
```
with
```go
	if res.Status == domain.DriftClean {
		if manifestChanged(req.TargetPath, lock) {
			res.Status = domain.DriftStaleLock
			res.Modified = []string{manifest.FileName}
		} else {
			s.renderCompare(ctx, req, lock, &res)
		}
	}
```
and add:
```go
// manifestChanged compares the lock's recorded manifest hash with the working
// tree. A manifest that appeared or disappeared since the last render counts
// as changed; repos that never had one (both sides empty) are unaffected.
func manifestChanged(targetPath string, lock domain.OnboardLock) bool {
	recorded := ""
	if lock.Inputs != nil {
		recorded = lock.Inputs.ManifestSHA256
	}
	current := ""
	if raw, err := os.ReadFile(filepath.Join(targetPath, filepath.FromSlash(manifest.FileName))); err == nil {
		sum := sha256.Sum256(raw)
		current = "sha256:" + hex.EncodeToString(sum[:])
	}
	return recorded != current
}
```
(imports: `crypto/sha256`, `encoding/hex`, `internal/manifest`.)

- [ ] **Step 4: Run**

Run: `go test ./internal/app/drift/ -v -cover`
Expected: PASS; `TestDriftStatuses` unchanged.

- [ ] **Step 5: Commit**

```bash
git add internal/app/drift/service.go internal/app/drift/service_test.go
git commit -m "feat(drift): classify a changed adopter manifest as stale-lock"
```

---

### Task 11: Templates — release-please monorepo config + manifest seed

**Files:**
- Modify: `docs/adopter-templates/configs/release-please-config.monorepo.json.tmpl`, `docs/adopter-templates/configs/release-please-manifest.json.tmpl`
- Regenerate: `tests/fixtures/onboard/monorepo-go/expected/release-please-config.json`

**Interfaces:**
- Produces: root `.` → `include-component-in-tag: false`, no `package-name`; sub-directory packages → `package-name: <path.Base>`, `include-component-in-tag: true`; `release-type` from `release_please_type` (`helm` for charts); top-level `separate-pull-requests: false` and the standard `changelog-sections`. Manifest seeds `components[].version` when set, else `current_version`.

- [ ] **Step 1: Write the templates**

`release-please-config.monorepo.json.tmpl`:
```json
{
  "$schema": "https://raw.githubusercontent.com/googleapis/release-please/main/schemas/config.json",
  "separate-pull-requests": false,
  "bump-minor-pre-major": true,
  "changelog-sections": [
    { "type": "feat", "section": "Features" },
    { "type": "fix", "section": "Bug Fixes" },
    { "type": "perf", "section": "Performance" },
    { "type": "refactor", "section": "Refactors" },
    { "type": "docs", "section": "Documentation", "hidden": false },
    { "type": "test", "section": "Tests", "hidden": true },
    { "type": "ci", "section": "CI", "hidden": true },
    { "type": "chore", "section": "Chores", "hidden": true }
  ],
  "packages": {
{{- $first := true }}
{{- range .profile.components }}
{{- if not $first }},{{ end }}
{{- $first = false }}
{{- if eq .path "." }}
    ".": {
      "release-type": "{{ .release_please_type }}",
      "include-component-in-tag": false
    }
{{- else }}
    "{{ .path }}": {
      "release-type": "{{ .release_please_type }}",
      "package-name": "{{ path.Base .path }}",
      "include-component-in-tag": true
    }
{{- end }}
{{- end }}
  }
}
```

`release-please-manifest.json.tmpl`:
```json
{
{{- $first := true }}
{{- range .profile.components }}
{{- if not $first }},{{ end }}
{{- $first = false }}
  "{{ .path }}": "{{ if index . "version" }}{{ .version }}{{ else }}{{ $.profile.current_version }}{{ end }}"
{{- end }}
}
```
(`index . "version"` is nil-safe for profiles without the key — Bash profiles never emit it.)

- [ ] **Step 2: Verify single-component output is untouched**

`release-please-manifest.json.tmpl` is shared by single-component renders. Run: `bats tests/shell/onboard-render.bats`
Expected: all golden tests PASS except `golden: monorepo-go` (config changed on purpose).

- [ ] **Step 3: Regenerate the monorepo-go golden and inspect**

Run: `UPDATE_GOLDEN=1 bats tests/shell/onboard-render.bats -f "monorepo-go" && git diff --stat tests/fixtures/onboard/monorepo-go/expected`
Expected: only `release-please-config.json` (and its lock hash) changed; `package-name` is now `api` / `worker`.

- [ ] **Step 4: Commit**

```bash
git add docs/adopter-templates/configs tests/fixtures/onboard/monorepo-go/expected
git commit -m "feat(templates): monorepo release-please config with root package, helm type and chart seed versions"
```

---

### Task 12: Template — `release.yml` path gating, contexts, dispatch trigger, chart publish

**Files:**
- Modify: `docs/adopter-templates/skeletons/release.yml.tmpl`
- Regenerate: `tests/fixtures/onboard/monorepo-go/expected/.github/workflows/release.yml`

**Interfaces:**
- Consumes: `needs.release-please.outputs.paths_released` / `releases` (Task 1); `dockerfiles[].context`, `dockerfiles[].platforms`, `profile.release.dispatch_trigger`, `components[].primary_language == "helm"` (Tasks 5/7).
- Produces: in monorepo profiles each component job is gated with `contains(fromJSON(needs.release-please.outputs.paths_released), '<path>')` and tagged `v${{ fromJSON(needs.release-please.outputs.releases)['<path>'].version }}`; single-component output is byte-identical.

- [ ] **Step 1: Edit the template**

After `{{- $pin := .pin -}}` (line 17) add:
```
{{- $mono := .profile.monorepo -}}
```
Replace lines 19-21 (`on:` block) with:
```
on:
  push:
    branches: [{{ .profile.default_branch }}]
{{- if and (index .profile "release") .profile.release.dispatch_trigger }}
  workflow_dispatch: {}
{{- end }}
```
Inside the component loop, after `{{- $isRoot := eq $c.path "." -}}` (line 44) add the per-component gate and tag expressions:
```
{{- $gate := "needs.release-please.outputs.release_created == 'true'" -}}
{{- $tag := "${{ needs.release-please.outputs.tag_name }}" -}}
{{- if $mono -}}
  {{- $gate = printf "contains(fromJSON(needs.release-please.outputs.paths_released), '%s')" $c.path -}}
  {{- $tag = printf "v${{ fromJSON(needs.release-please.outputs.releases)['%s'].version }}" $c.path -}}
{{- end -}}
```
Then replace every `if: needs.release-please.outputs.release_created == 'true'` inside the loop with `if: {{ $gate }}`, every `tag: {{`${{ needs.release-please.outputs.tag_name }}`}}` with `tag: {{ $tag }}`, and in `release-flutter-android` `version: {{ $tag }}`.

Single-Dockerfile branch (lines 60-67): replace the `with:` context/dockerfile lines with
```
    with:
    {{- $ctx := $ctxPath }}{{ if $df.context }}{{ $ctx = $df.context }}{{ end }}
    {{- if ne $ctx "." }}
      context: {{ $ctx }}
    {{- end }}
    {{- if not $isRoot }}
      dockerfile: {{ $ctxPath }}/{{ $df.path }}
    {{- else }}
      dockerfile: {{ $df.path }}
    {{- end }}
      image_name: {{ $df.image_name }}
    {{- if $df.platforms }}
      platforms: {{ $df.platforms }}
    {{- end }}
```
(For today's profiles `$df.context` is absent and `$ctx == $ctxPath`, so the emitted lines are unchanged: root → no context; sub-dir → `context: <path>`.)

Multi-Dockerfile branch (lines 94-96): replace with
```
    {{- $ctx := $ctxPath }}{{ if (index $releaseDfs 0).context }}{{ $ctx = (index $releaseDfs 0).context }}{{ end }}
    {{- if ne $ctx "." }}
      context: {{ $ctx }}
    {{- end }}
```
and build `$images` with repo-relative Dockerfile paths for non-root components: `coll.Dict "dockerfile" (ternary (printf "%s/%s" $ctxPath .path) .path (not $isRoot)) "image_name" .image_name` — check gomplate's `ternary` argument order (`ternary <true-val> <false-val> <condition>`) against the installed version; if unsure use an explicit `{{ if }}` to compute a `$dfPath` variable first.

Chart component (new, after the `chart_yaml` block at line 127):
```
{{- if and (eq $c.primary_language "helm") (not $isRoot) }}
  helm-publish{{ $suffix }}:
    needs: [release-please]
    if: {{ $gate }}
    uses: serverkraken/reusable-workflows/.github/workflows/helm-publish.yml@{{ $pin }}
    permissions:
      contents: read
      packages: write
    with:
      chart_path: {{ $c.path }}
      oci_registry: ghcr.io/{{ $.profile.target_repo }}/charts
    secrets: inherit
{{- end }}
```
(Root charts keep today's behaviour — the backlog's Pages-vs-OCI decision is pending.)

- [ ] **Step 2: Byte-identity check**

Run: `bats tests/shell/onboard-render.bats && bats tests/shell/onboard-drift.bats`
Expected: every golden PASS except `monorepo-go`; the byte-reproducible drift test PASS.

- [ ] **Step 3: Regenerate monorepo-go and review**

Run: `UPDATE_GOLDEN=1 bats tests/shell/onboard-render.bats -f "monorepo-go"`
Then read `tests/fixtures/onboard/monorepo-go/expected/.github/workflows/release.yml`: both jobs must carry `if: contains(fromJSON(needs.release-please.outputs.paths_released), 'services/api')` and `tag: v${{ fromJSON(needs.release-please.outputs.releases)['services/api'].version }}`; `context: services/api` unchanged.

- [ ] **Step 4: actionlint the rendered file**

Run: `actionlint tests/fixtures/onboard/monorepo-go/expected/.github/workflows/release.yml`
Expected: no findings (actionlint validates the `fromJSON(...)['…']` expression syntax).

- [ ] **Step 5: Commit**

```bash
git add docs/adopter-templates/skeletons/release.yml.tmpl tests/fixtures/onboard/monorepo-go/expected
git commit -m "feat(templates): gate monorepo release jobs on paths_released, honour build contexts and dispatch trigger"
```

---

### Task 13: Template — `prerelease.yml` component loop

**Files:**
- Modify: `docs/adopter-templates/skeletons/prerelease.yml.tmpl`
- Regenerate: `tests/fixtures/onboard/monorepo-go/expected/.github/workflows/prerelease.yml`

**Interfaces:**
- Produces: for monorepo profiles one `build<suffix>`/`scan<suffix>` pair per component with release-eligible-or-not Dockerfiles (prerelease builds everything), contexts as in Task 12; single-component output byte-identical.

- [ ] **Step 1: Edit**

Keep lines 1-26 but compute the `on:` block from the **first** component as today (the Flutter dispatch inputs only make sense single-component; a monorepo with a Flutter app keeps index-0 semantics). Replace `jobs:` … end with a loop:

```
jobs:
{{- range $i, $c := .profile.components }}
{{- $slug := strings.ReplaceAll "/" "-" $c.path -}}
{{- if eq $slug "." }}{{ $slug = "" }}{{ end -}}
{{- $suffix := "" -}}
{{- if $slug }}{{ $suffix = printf "-%s" $slug }}{{ end -}}
{{- $isRoot := eq $c.path "." -}}
{{- if and (has $c.release_signals "flutter_android") $c.release_signals.flutter_android }}
  build{{ $suffix }}:
    … (existing flutter block, job name suffixed)
{{- else if eq (len $c.dockerfiles) 1 }}
{{- $df := index $c.dockerfiles 0 }}
{{- $ctx := $c.path }}{{ if $df.context }}{{ $ctx = $df.context }}{{ end }}
  build{{ $suffix }}:
    uses: serverkraken/reusable-workflows/.github/workflows/docker-build.yml@{{ $pin }}
    permissions: … (unchanged)
    secrets: inherit
    with:
      prerelease: true
    {{- if ne $ctx "." }}
      context: {{ $ctx }}
    {{- end }}
    {{- if not $isRoot }}
      dockerfile: {{ $c.path }}/{{ $df.path }}
    {{- else }}
      dockerfile: {{ $df.path }}
    {{- end }}
      image_name: {{ $df.image_name }}
    {{- if $df.platforms }}
      platforms: {{ $df.platforms }}
    {{- end }}
      sign: … attest: … sbom: … (unchanged)
  scan{{ $suffix }}:
    needs: build{{ $suffix }}
    … image_ref: {{ printf "${{ needs.build%s.outputs.image_ref }}" $suffix }} …
{{- else if gt (len $c.dockerfiles) 1 -}}
  … docker-build-multi block with the same $ctx logic and suffixed job name …
{{- else if eq $i 0 }}
  # No Dockerfiles detected for this component.
  noop:
    runs-on: ubuntu-latest
    steps:
      - run: echo "No prerelease build artifacts for this repo (no Dockerfiles)."
{{- end }}
{{- end }}
```
Write the full blocks out (copy the existing bodies); the `…` above marks unchanged lines only. The `noop` job is emitted for index 0 only so a monorepo never gets two `noop` jobs; for single-component profiles the output is identical to today.

- [ ] **Step 2: Byte-identity + regen**

Run: `bats tests/shell/onboard-render.bats`
Expected: all golden PASS except `monorepo-go`; then `UPDATE_GOLDEN=1 bats tests/shell/onboard-render.bats -f "monorepo-go"` and confirm `prerelease.yml` now has `build-services-api`, `build-services-worker` with `context:`/`dockerfile:` lines. `actionlint` the regenerated file.

- [ ] **Step 3: Commit**

```bash
git add docs/adopter-templates/skeletons/prerelease.yml.tmpl tests/fixtures/onboard/monorepo-go/expected
git commit -m "fix(templates): prerelease builds every monorepo component, not only the first"
```

---

### Task 14: Template — `ci.yml` chart components

**Files:**
- Modify: `docs/adopter-templates/skeletons/ci.yml.tmpl:104-109`

**Interfaces:**
- Consumes: `components[].unittest` (Task 7), `lint-helm` `unittest` input (Task 2).
- Produces: for `primary_language == "helm"` and `path != "."`: `lint-helm-<suffix>` with `working_directory: .`, `charts_dir: <path.Dir path>`, `unittest: true` when set, plus `helm-publish-dryrun-<suffix>`. Root charts unchanged.

- [ ] **Step 1: Edit**

Replace lines 104-109 with:

```
{{- else if eq $c.primary_language "helm" }}
{{- if eq $c.path "." }}
  lint-helm-{{ $suffix }}:
    uses: serverkraken/reusable-workflows/.github/workflows/lint-helm.yml@{{ $pin }}
    with:
      working_directory: {{ $c.path }}
    secrets: inherit
{{- else }}
  lint-helm-{{ $suffix }}:
    uses: serverkraken/reusable-workflows/.github/workflows/lint-helm.yml@{{ $pin }}
    with:
      working_directory: .
      charts_dir: {{ path.Dir $c.path }}
    {{- if index $c "unittest" }}
      unittest: true
    {{- end }}
    secrets: inherit
  helm-publish-dryrun-{{ $suffix }}:
    uses: serverkraken/reusable-workflows/.github/workflows/helm-publish.yml@{{ $pin }}
    permissions:
      contents: read
      packages: write
    with:
      chart_path: {{ $c.path }}
      oci_registry: ghcr.io/{{ $.profile.target_repo }}/charts
      dry_run: true
    secrets: inherit
{{- end }}
```

- [ ] **Step 2: Verify**

Run: `bats tests/shell/onboard-render.bats`
Expected: all PASS (no golden has a non-root helm component yet; `service-with-helm` keeps its chart as a *signal*, not a component).

- [ ] **Step 3: Commit**

```bash
git add docs/adopter-templates/skeletons/ci.yml.tmpl
git commit -m "feat(templates): lint, unit-test and dry-run publish chart components in ci.yml"
```

---

### Task 15: Template — `e2e.yml.tmpl`

**Files:**
- Create: `docs/adopter-templates/skeletons/e2e.yml.tmpl`

**Interfaces:**
- Consumes: `profile.workflows.e2e.{script,schedule}`; rendered by Task 9's render set.

- [ ] **Step 1: Write**

```
{{- /*
  e2e.yml — consumer-owned Kubernetes e2e suite on a kind cluster, rendered
  only when the adopter manifest declares workflows.e2e. The script owns the
  cluster lifecycle; e2e-kind.yml provisions the toolchain and guarantees
  cleanup on the long-lived self-hosted runners.
*/ -}}
{{- $pin := .pin -}}
{{- $e2e := .profile.workflows.e2e -}}
name: e2e
on:
{{- if $e2e.schedule }}
  schedule:
    - cron: '{{ $e2e.schedule }}'
{{- end }}
  workflow_dispatch: {}
  push:
    tags:
      - 'v*'

jobs:
  e2e:
    uses: serverkraken/reusable-workflows/.github/workflows/e2e-kind.yml@{{ $pin }}
    permissions:
      contents: read
      packages: read
    with:
      script: {{ $e2e.script }}
      helm_version: {{`${{ vars.SK_HELM_VERSION || 'v3.16.3' }}`}}
    secrets: inherit
```

- [ ] **Step 2: Render check**

Covered by Task 16's golden; here just: `gomplate -c .=<(printf '{"pin":"v4","profile":{"workflows":{"e2e":{"script":"test/e2e/run.sh","schedule":"0 3 * * *"}}}}') -f docs/adopter-templates/skeletons/e2e.yml.tmpl | actionlint -`
Expected: valid workflow, no findings.

- [ ] **Step 3: Commit**

```bash
git add docs/adopter-templates/skeletons/e2e.yml.tmpl
git commit -m "feat(templates): e2e.yml skeleton for manifest-declared kind e2e suites"
```

---

### Task 16: Golden for the manifest fixture + self-CI job

**Files:**
- Create: `tests/fixtures/onboard/go-root-multi-image/expected/…` (7 workflows/configs + lock)
- Modify: `.github/workflows/self-ci.yml` (new job after `onboard-render-go-cli-happy`, line 312-361; add to `summary.needs`)

**Interfaces:**
- Consumes: everything above. The bats harness uses the Bash engine, which refuses manifests, so this golden runs through `sk-workflows preview` in self-CI.

- [ ] **Step 1: Generate the expected tree locally**

```bash
go build -o /tmp/skw ./cmd/sk-workflows
OUT=$(mktemp -d)
/tmp/skw preview -catalog-path . -repo-path tests/fixtures/onboard/go-root-multi-image -pin-version v4 -rendered-against v4.14.0 -out "$OUT"
rm "$OUT/profile.json"
jq 'del(.rendered_at)' "$OUT/.github/onboard.lock.json" > "$OUT/lock.tmp" && mv "$OUT/lock.tmp" "$OUT/.github/onboard.lock.json"
mkdir -p tests/fixtures/onboard/go-root-multi-image/expected
cp -R "$OUT/." tests/fixtures/onboard/go-root-multi-image/expected/
```

- [ ] **Step 2: Review the rendered files against the acceptance list**

Check by reading:
- `ci.yml`: `secscan`, `lint-go-root`, `test-go-root`, `lint-helm-charts-demo` (`working_directory: .`, `charts_dir: charts`, `unittest: true`), `helm-publish-dryrun-charts-demo`; no jobs for `images/api` / `images/worker` (generic, no lint atom) and **no** `no_lint_test_atom`-driven fallback.
- `release.yml`: `workflow_dispatch: {}`; `docker-build` (root, `dockerfile: images/tools/Dockerfile`, no context, gated on `'.'`), `docker-build-images-api` (`context: .`? — no: `$ctx` is `.` so **no** context line; `dockerfile: images/api/Dockerfile`), `docker-build-images-worker` (+ `platforms: linux/amd64`), each `scan-*`, `helm-publish-charts-demo` gated on `'charts/demo'`; every gate uses `paths_released`, every tag uses `releases[...]`.
- `prerelease.yml`: three build/scan pairs.
- `e2e.yml`: schedule `0 3 * * *`, script `test/e2e/run.sh`.
- `release-please-config.json`: `.` (go, no component in tag), `images/api`/`images/worker` (simple, package-name `api`/`worker`), `charts/demo` (helm, package-name `demo`).
- `.release-please-manifest.json`: `"charts/demo": "0.3.0"`, others `"0.0.0"` (no GitHub metadata locally).
- `onboard.lock.json`: `inputs.manifest_sha256` present; `.github/workflows/e2e.yml` tracked.

Run `actionlint` on every rendered workflow. Fix templates (Tasks 12-15) until this list holds, then regenerate.

- [ ] **Step 3: Self-CI job**

```yaml
  # ----- onboard preview (Go path, adopter manifest): renders the manifest
  #       fixture through sk-workflows preview and diffs it against the
  #       committed golden. The bats harness cannot cover this fixture — the
  #       Bash engine refuses manifests by design.
  onboard-preview-manifest-golden:
    runs-on: ubuntu-latest
    timeout-minutes: 10
    steps:
      - uses: actions/checkout@de0fac2e4500dabe0009e67214ff5f5447ce83dd # v6
      - uses: actions/setup-go@4a3601121dd01d1626a1e23e37211e3254c1c06c # v6
        with:
          go-version-file: go.mod
          cache: true
      - uses: ./actions/setup-sk-workflows
        with:
          build_from_source: 'true'
      - name: Install gomplate
        run: sudo ./scripts/install-gomplate.sh
      - name: Preview and diff
        env:
          FIX: tests/fixtures/onboard/go-root-multi-image
        run: |
          set -euo pipefail
          out="$(mktemp -d)"
          # no -target-repo: that would call `gh` for branch/release metadata;
          # target_repo falls back to the fixture basename (deterministic).
          sk-workflows preview -catalog-path . -repo-path "$FIX" \
            -pin-version v4 -rendered-against v4.14.0 -out "$out"
          rm "$out/profile.json"
          jq 'del(.rendered_at)' "$out/.github/onboard.lock.json" > "$out/lock.tmp" && mv "$out/lock.tmp" "$out/.github/onboard.lock.json"
          diff -r "$FIX/expected" "$out"
```
Add `onboard-preview-manifest-golden` to `summary.needs`.

- [ ] **Step 4: Commit**

```bash
git add tests/fixtures/onboard/go-root-multi-image/expected .github/workflows/self-ci.yml
git commit -m "test(onboard): golden render for the adopter-manifest fixture via sk-workflows preview"
```

---

### Task 17: Onboard workflow — "Consumers" in PR body and status doc

**Files:**
- Modify: `.github/workflows/onboard.yml:365-429` (PR-A body), `:670-751` (status upsert)
- Modify: `docs/onboarding-status.md` (table header + every row), `scripts/seed-onboarding-status.sh:40`

- [ ] **Step 1: PR body**

Next to `components_md` (line 367-370) add:
```bash
          consumers_md="$(echo "$PROFILE" | jq -r '
            (.gitops_consumers // []) | map("- `" + .repo + "`" + (if (.scope // []) | length > 0 then " (" + (.scope | join(", ")) + ")" else "" end) + " — " + .mode) | join("\n")')"
```
and in the body heredoc, after the "Detected shape" block:
```bash
$( [[ -n "$consumers_md" ]] && printf '\n### Consumed by (from .github/onboard.yml)\n\n%s\n' "$consumers_md" )
```

- [ ] **Step 2: Status table — seventh column**

`docs/onboarding-status.md`: header becomes `| Repository | Onboarded | Catalog Version | Add PR | Cleanup PR | Status | Consumers |` with `|---|---|---|---|---|---|---|`; append ` — |` to every existing row (one-time migration, do it with `sed -i.bak -E 's/^(\| serverkraken\/[^|]+\|.*\|)$/\1 — |/'` and review the diff).
`scripts/seed-onboarding-status.sh:40`: row → `"| ${repo} | — | — | — | — | not onboarded | — |"`.
`onboard.yml:729`: build `consumers_cell` from the per-target result JSON (`.gitops_consumers | map(.repo) | join(", ")`, default `—`; the results JSON written per matrix target must carry `gitops_consumers` from `$PROFILE` — add it where `pr_a_status`/`pr_b_status` are written) and emit `| $target | $today | ${PIN_VERSION:-v4} | $pa_md | $pb_md | $status | $consumers_cell |`.

- [ ] **Step 3: Verify**

Run: `actionlint .github/workflows/onboard.yml && shellcheck scripts/seed-onboarding-status.sh && bash -n scripts/seed-onboarding-status.sh`
Expected: clean. Dry-check the awk upsert with a scratch copy of the doc and a fake 7-column row.

- [ ] **Step 4: Commit**

```bash
git add .github/workflows/onboard.yml docs/onboarding-status.md scripts/seed-onboarding-status.sh
git commit -m "feat(onboard): surface manifest-declared GitOps consumers in PR body and status doc"
```

---

### Task 18: Documentation

**Files:**
- Modify: `docs/operations.md` (new `## 11. Adopter Manifest` after § 10; § 5.7 note; § 7.2 row), `README.md` (one bullet in the onboarding section)

- [ ] **Step 1: Write § 11**

Content (headings): `### 11.1 When you need it` (root language marker + sub-dir Dockerfiles; non-default image names/contexts; charts next to code; e2e suites; declaring consumers) · `### 11.2 Schema v1` (the full example from the spec § 1 **with** `context`, then the semantics bullets verbatim from the spec) · `### 11.3 Per-component releases` (release-please monorepo mode, tags `v1.2.0` / `postfix-v1.2.0` / `demo-v0.3.0`, one combined release PR, `paths_released` gating, "a `fix(postfix): …` commit builds only postfix") · `### 11.4 Engines` (Go only; Bash detect exits with the documented message; drift on a Bash-engine sweep reports `error` for manifest repos — dispatch with `use_go_cli: true`) · `### 11.5 Lock and drift` (`inputs.manifest_sha256`; a manifest edit is `stale-lock`) · `### 11.6 GitOps consumers` (inventory only in v1; `mode: push` reserved; scope in file globs; **rule for GitOps repos: image references in `bootstrap/templates/**/*.j2` stay literal**) · `### 11.7 Relation to Dockerfile annotations` (still valid, manifest wins).

§ 5.7: add "Repos with `.github/onboard.yml` require `use_go_cli: true`." § 7.2 table: add a sentence to the `stale-lock` row: "also when `.github/onboard.yml` changed since the last render".

- [ ] **Step 2: README**

In the onboarding overview add: "Repos whose layout detection cannot infer (root module + image directories, charts next to code, e2e suites) declare it in `.github/onboard.yml` — see operations § 11."

- [ ] **Step 3: Commit**

```bash
git add docs/operations.md README.md
git commit -m "docs(operations): adopter manifest, per-component releases, engine and drift semantics"
```

---

### Task 19: Stage-2 release gate

**Files:** none (verification only)

- [ ] **Step 1: Full local verification**

```bash
go vet ./... && golangci-lint run ./... && go test ./... -cover
bats tests/shell/
actionlint
yamllint -s .github/
```
Expected: all green; Go coverage per package ≥ 90 %.

- [ ] **Step 2: Push the branch, open the PR** (`feat: adopter manifest + per-component releases`), let self-CI / integration run.

- [ ] **Step 3: Live-adopter byte-identity**

Dispatch `drift-check.yml` **from the PR branch** (templates render from `github.workflow_sha`, gotcha 5 in `CLAUDE-activeContext.md`). Every adopter in `docs/onboarding-status.md` must report `clean` (or exactly the status it reported in the last scheduled run — compare with the previous Monday's report). Any new `stale-lock` is a byte-identity regression: fix the template before merging.

- [ ] **Step 4: mailstack acceptance preview**

```bash
go build -o /tmp/skw ./cmd/sk-workflows
# in the mailstack checkout, on a scratch branch, add the manifest from Task 20 step 1 first
/tmp/skw preview -catalog-path . -repo-path ~/SourceCode/serverkraken/mailstack -target-repo serverkraken/mailstack -out /tmp/mailstack-preview
diff -u ~/SourceCode/serverkraken/mailstack/.github/workflows/ci.yml /tmp/mailstack-preview/.github/workflows/ci.yml
# repeat for prerelease.yml, release.yml, e2e.yml, release-please-config.json
```
Expected differences are only: per-image `scan-*` jobs, `test-helm` replaced by `unittest: true` on `lint-helm`, six single `docker-build-*` jobs instead of one `docker-build-multi`, path gates instead of `release_created`, monorepo release-please config. Anything else is a defect.

- [ ] **Step 5: Merge, let release-please cut v4.14.0**, confirm the `v4` floating tag moved.

---

## Stage 3 — mailstack

### Task 20: mailstack manifest, chart values, onboarding

**Repo:** `serverkraken/mailstack` (separate checkout). Requires catalog v4.14.0.

**Files:**
- Create: `.github/onboard.yml`
- Modify: `charts/mailstack/values.yaml`, `charts/mailstack/Chart.yaml`, `release-please-config.json` (will be replaced by the onboard PR), `renovate.json`

- [ ] **Step 1: Manifest**

```yaml
schema: 1
components:
  - path: .
    language: go
    dockerfiles:
      - path: images/tools/Dockerfile
        image: serverkraken/mailstack/tools
  - path: images/postfix
    image: serverkraken/mailstack/postfix
    context: .
  - path: images/dovecot
    image: serverkraken/mailstack/dovecot
    context: .
  - path: images/unbound
    image: serverkraken/mailstack/unbound
    context: .
  - path: images/fangfrisch
    image: serverkraken/mailstack/fangfrisch
    context: .
  - path: images/olefy
    image: serverkraken/mailstack/olefy
    context: .
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
    scope:
      - kubernetes/apps/mailstack/**
      - bootstrap/templates/kubernetes/apps/mailstack/**
```

- [ ] **Step 2: Chart decoupling**

`charts/mailstack/values.yaml`: give every image its own default tag (replace the `appVersion` fallback in the templates with the per-image value), e.g.
```yaml
images:
  postfix:    { repository: ghcr.io/serverkraken/mailstack/postfix,    tag: v1.1.1 }
  dovecot:    { repository: ghcr.io/serverkraken/mailstack/dovecot,    tag: v1.1.1 }
  unbound:    { repository: ghcr.io/serverkraken/mailstack/unbound,    tag: v1.1.1 }
  fangfrisch: { repository: ghcr.io/serverkraken/mailstack/fangfrisch, tag: v1.1.1 }
  olefy:      { repository: ghcr.io/serverkraken/mailstack/olefy,      tag: v1.1.1 }
  tools:      { repository: ghcr.io/serverkraken/mailstack/tools,      tag: v1.1.1 }
```
and update every template that read `.Chart.AppVersion`. `Chart.yaml`: drop the `# x-release-please-version` marker and its comment (the chart is now its own release-please package; `version:` is bumped by the `helm` strategy). Run `helm lint charts/mailstack && helm unittest charts/mailstack`.

- [ ] **Step 3: Renovate in mailstack** — `renovate.json`: enable `helm-values` on `charts/mailstack/values.yaml` and a rule so own images bump as `fix(chart)`:
```json
{
  "helm-values": { "fileMatch": ["^charts/mailstack/values\\.yaml$"] },
  "packageRules": [
    { "matchDatasources": ["docker"], "matchPackagePrefixes": ["ghcr.io/serverkraken/mailstack/"], "semanticCommitType": "fix", "semanticCommitScope": "chart", "automerge": true }
  ]
}
```
(merge into the existing config; keep its `extends`).

- [ ] **Step 4: PR** with manifest + chart + renovate (`feat: declare adopter manifest, per-image chart tags`). Merge.

- [ ] **Step 5: Onboard** — dispatch the catalog's `onboard.yml` for `serverkraken/mailstack` with `use_go_cli: true`, `pin_version: v4`. Review PR-A: rendered workflows must match the Task-19 acceptance list; the hand-written `test-helm` job and `e2e.yml` are replaced by rendered files; PR-B (legacy cleanup) should list nothing. Merge PR-A, then the release-please bootstrap PR it triggers (six new packages + chart in the manifest).

- [ ] **Step 6: Proof** — make a `fix(postfix): …` change under `images/postfix/`, merge, merge the release PR. Expected: tag `postfix-v1.1.2`, only `docker-build-images-postfix` + `scan-images-postfix` run in `release.yml`; no chart publish. Then a chart-only change → `mailstack-v0.3.0` + `helm-publish-charts-mailstack` only.

---

## Stage 4 — Renovate fast-track

### Task 21: Homelab preset — own images roll out immediately

**Repo:** `serverkraken/renovate-config`, file `homelab.json`.

- [ ] **Step 1:** Add to `packageRules` (before the "Cluster-carrying infra never automerges" rule so the infra exclusion still wins for its paths):
```json
{
  "description": "Own images (ghcr.io/serverkraken/**): no weekend schedule, no release-age gate, CI-gated automerge. They are signed, attested and Trivy-scanned at build time.",
  "matchDatasources": ["docker"],
  "matchPackagePrefixes": ["ghcr.io/serverkraken/"],
  "matchFileNames": ["kubernetes/apps/**", "bootstrap/templates/kubernetes/apps/**"],
  "schedule": ["at any time"],
  "minimumReleaseAge": null,
  "automerge": true,
  "automergeType": "pr"
}
```
Check with `npx renovate-config-validator homelab.json` (or the repo's existing validation workflow).

- [ ] **Step 2:** PR, merge. Observe the next mailstack/wartung release: the homelab-mail-nue / homelab-study PR should appear within the hosted Renovate's run interval (hours) and automerge once CI is green — in **both** the `.j2` template and the rendered path in one PR.

---

## Self-review (done while writing)

- **Spec coverage:** § 1 schema → Tasks 3, 4, 18; `context` amendment → Task 0; § 2 detect items 1-5 → Tasks 6, 7, 8; § 3 atoms → Tasks 1, 2; § 4 templates (release gating, prerelease loop, monorepo config, ci chart jobs, e2e skeleton) → Tasks 11-15; § 5 lock/drift → Tasks 9, 10; § 6 GitOps invariants → Task 18 § 11.6; interface contracts → contracts.md rows in Tasks 1, 2; test strategy (unit, bats fail-loud, golden, integration, mailstack acceptance) → Tasks 3-10, 8, 16, 1, 19; rollout stages → Tasks 19-21; acceptance criteria 1-7 → Tasks 19 (1, 2, 3), 20 (4), 4 (5), 8 (6), 17 (7). Out-of-scope items are not planned.
- **Placeholders:** the `…` in Task 13 mark lines copied unchanged from the existing template; the engineer has the full current file above (Task 12 quotes it by line). Task 9's `renderSingleService` helper is an instruction to extract, with the source test named.
- **Type consistency:** `manifest.Load(repoPath) (*Manifest, string, bool, error)` used identically in Tasks 4, 7; `inventoryDockerfiles(repo, componentPath, imageOverride)` in Task 7 only (callers updated there); profile JSON keys `manifest_sha256`, `workflows.e2e.{script,schedule}`, `release.dispatch_trigger`, `gitops_consumers`, `dockerfiles[].context/platforms`, `components[].unittest/version` agree across Tasks 5, 7, 9, 11-16; lock key order `rendered_at → inputs → files` in Tasks 9 and 16; atom outputs `paths_released`/`releases` spelled identically in Tasks 1, 12, 16.
