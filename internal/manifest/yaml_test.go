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
		"nested sequence":    "a:\n  - - b\n",
	}
	for name, src := range tests {
		t.Run(name, func(t *testing.T) {
			if _, err := parseYAML(src); err == nil || !strings.HasPrefix(err.Error(), "line ") {
				t.Fatalf("err=%v", err)
			}
		})
	}
}

func TestParseYAMLNestedSequenceMessage(t *testing.T) {
	_, err := parseYAML("a:\n  - - b\n")
	if err == nil || !strings.Contains(err.Error(), "line 2: nested sequences are not supported") {
		t.Fatalf("err=%v", err)
	}
}

func TestParseYAMLEmptyIsEmptyMap(t *testing.T) {
	root, err := parseYAML("# nothing\n\n")
	if err != nil || root.Kind != KindMap || len(root.Keys) != 0 {
		t.Fatalf("root=%+v err=%v", root, err)
	}
}

func TestParseYAMLSequenceStartError(t *testing.T) {
	src := `- item1
- item2
`
	_, err := parseYAML(src)
	if err == nil || !strings.HasPrefix(err.Error(), "line ") {
		t.Fatalf("expected error starting with 'line ', got %v", err)
	}
}

func TestParseYAMLFlowSequences(t *testing.T) {
	src := `items: [a, b, c]
empty: []
quoted: ["x", 'y']
mixed: [foo, "bar", 'baz']
`
	root, err := parseYAML(src)
	if err != nil {
		t.Fatal(err)
	}
	items := root.Map["items"].Seq
	if len(items) != 3 || items[0].Scalar != "a" || items[1].Scalar != "b" || items[2].Scalar != "c" {
		t.Fatalf("items=%+v", items)
	}
	empty := root.Map["empty"].Seq
	if len(empty) != 0 {
		t.Fatalf("empty should be empty, got %+v", empty)
	}
	quoted := root.Map["quoted"].Seq
	if len(quoted) != 2 || !quoted[0].Quoted || !quoted[1].Quoted {
		t.Fatalf("quoted=%+v", quoted)
	}
}

func TestParseYAMLSequenceWithMappingItems(t *testing.T) {
	src := `items:
  - key1: value1
    key2: value2
  - key3: value3
`
	root, err := parseYAML(src)
	if err != nil {
		t.Fatal(err)
	}
	items := root.Map["items"].Seq
	if len(items) != 2 {
		t.Fatalf("expected 2 items, got %d", len(items))
	}
	if items[0].Map["key1"].Scalar != "value1" {
		t.Fatalf("key1=%+v", items[0].Map["key1"])
	}
	if items[0].Map["key2"].Scalar != "value2" {
		t.Fatalf("key2=%+v", items[0].Map["key2"])
	}
	if items[1].Map["key3"].Scalar != "value3" {
		t.Fatalf("key3=%+v", items[1].Map["key3"])
	}
}

func TestParseYAMLCommentEdgeCases(t *testing.T) {
	src := `key1: value # comment
key2: "value#notcomment"
key3: 'value#notcomment'
key4: value#notcomment
`
	root, err := parseYAML(src)
	if err != nil {
		t.Fatal(err)
	}
	if root.Map["key1"].Scalar != "value" {
		t.Fatalf("key1 should be 'value', got %q", root.Map["key1"].Scalar)
	}
	if root.Map["key2"].Scalar != "value#notcomment" {
		t.Fatalf("key2 should preserve #, got %q", root.Map["key2"].Scalar)
	}
	if root.Map["key3"].Scalar != "value#notcomment" {
		t.Fatalf("key3 should preserve #, got %q", root.Map["key3"].Scalar)
	}
	if root.Map["key4"].Scalar != "value#notcomment" {
		t.Fatalf("key4 should preserve #, got %q", root.Map["key4"].Scalar)
	}
}
