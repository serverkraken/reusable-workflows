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
		"tab indent":         "a:\n\tb: 1\n",
		"duplicate key":      "a: 1\na: 2\n",
		"bad indent":         "a:\n   b: 1\n",
		"anchor":             "a: &x 1\n",
		"flow map":           "a: {b: 1}\n",
		"multiline scalar":   "a: |\n  text\n",
		"seq under scalar":   "a: 1\n  - b\n",
		"missing value":      "a:\n",
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

// Audit A-10. Windows-Editoren und einige Generatoren schreiben einen UTF-8-BOM
// an den Dateianfang. Er klebte am ersten Schluessel, und der Adopter bekam
// eine Meldung, die niemand deuten kann:
//
//	line 1: unknown key "\ufeffschema" (allowed: schema, components, …)
func TestParseYAMLStripsLeadingBOM(t *testing.T) {
	const bom = "\ufeff"
	node, err := parseYAML(bom + "schema: 1\ncomponents:\n  - path: .\n")
	if err != nil {
		t.Fatalf("BOM sollte entfernt werden: %v", err)
	}
	if _, ok := node.Map["schema"]; !ok {
		keys := make([]string, 0, len(node.Map))
		for k := range node.Map {
			keys = append(keys, k)
		}
		t.Fatalf("schema fehlt, Schluessel: %q", keys)
	}

	// Gegenprobe: NUR am Dateianfang. Mitten im Dokument ist U+FEFF ein
	// regulaeres Zeichen und darf nicht verschwinden — sonst wuerde der Parser
	// still Daten veraendern.
	node, err = parseYAML("schema: 1\nname: a" + bom + "b\n")
	if err != nil {
		t.Fatalf("parse: %v", err)
	}
	if got := node.Map["name"].Scalar; got != "a"+bom+"b" {
		t.Fatalf("BOM mitten im Wert wurde veraendert: %q", got)
	}
}

// Audit A-9. In einfachen Anfuehrungszeichen ist ” das einzige Escape, das
// YAML kennt, und es steht fuer ein einzelnes '. Vorher blieb der Wert
// woertlich.
//
// Reichweite ehrlich: ueber KEIN Manifest-Feld erreichbar — jedes String-Feld
// laeuft gegen ein Muster, und keines laesst ein ' zu (derselbe Grund, aus dem
// J-7 und J-21 widerlegt wurden). Deshalb wird hier der Dekoder direkt
// geprueft und nicht ueber Parse().
func TestScalarDecodesDoubledSingleQuotes(t *testing.T) {
	for _, tc := range []struct{ in, want string }{
		{`'bob''s-api'`, `bob's-api`},
		{`''''`, `'`},
		{`'a''''b'`, `a''b`},
		{`'ohne'`, `ohne`},
	} {
		n, err := scalar(tc.in, 1)
		if err != nil {
			t.Fatalf("%s: %v", tc.in, err)
		}
		if n.Scalar != tc.want {
			t.Errorf("scalar(%s) = %q, want %q", tc.in, n.Scalar, tc.want)
		}
	}

	// Doppelte Anfuehrungszeichen bleiben BEWUSST uninterpretiert: dort kennt
	// YAML Backslash-Escapes, und die halb zu unterstuetzen waere schlechter
	// als gar nicht.
	n, err := scalar(`"a''b"`, 1)
	if err != nil {
		t.Fatalf("%v", err)
	}
	if n.Scalar != `a''b` {
		t.Errorf(`scalar("a''b") = %q, want unveraendert`, n.Scalar)
	}
}

// Audit A-8. Der Fall `{...}` auf oberster Ebene hatte laengst eine klare
// Meldung; INNERHALB einer Flow-Sequenz fehlte sie. `[{path: .}]` lief durch
// scalar(), `{path: .` wurde ein STRING, und der Fehler tauchte erst eine
// Schicht spaeter als "expected a mapping" auf — eine Meldung ueber die
// Struktur, die nicht verraet, dass dieser Parser Flow-Mappings gar nicht
// kennt.
func TestParseYAMLFlowSequenceWithMappingItemFailsClearly(t *testing.T) {
	_, err := parseYAML("components: [{path: ., language: go}]\n")
	if err == nil {
		t.Fatal("erwartet einen Fehler")
	}
	if !strings.Contains(err.Error(), "flow mappings are not supported") {
		t.Errorf("Meldung nennt die Ursache nicht: %v", err)
	}
	if !strings.Contains(err.Error(), "block sequence") {
		t.Errorf("Meldung nennt den Ausweg nicht: %v", err)
	}

	// Gegenprobe: eine Flow-Sequenz aus SKALAREN bleibt unterstuetzt — der
	// Kopf dieser Datei sichert genau das zu.
	node, err := parseYAML("scope: [a/**, b/**]\n")
	if err != nil {
		t.Fatalf("Skalar-Flow-Sequenz muss weiter gehen: %v", err)
	}
	if len(node.Map["scope"].Seq) != 2 {
		t.Fatalf("scope=%+v", node.Map["scope"])
	}
}
