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
		// A leading `---` document start is idiomatic YAML and mandatory under
		// a strict yamllint (`document-start`), which several adopters run over
		// their whole tree — wartung's .yamllint.yml rejects the manifest
		// without it. There is exactly one document per manifest, so the marker
		// carries no meaning here beyond satisfying the linter: skip it.
		// A second `---` would start a new document, which this subset does not
		// support, so it still falls through to the parser and fails loudly.
		if len(out) == 0 && strings.TrimSpace(text) == "---" {
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
			// A block sequence may sit at its key's own indentation — YAML
			// allows both, and yamllint's `indentation` rule pushes whole
			// repos to this style (wartung's config rejects the indented
			// form outright). Only a sequence may do this: a mapping at the
			// key's indent is the next key, not a value.
			zeroIndented := p.pos < len(p.lines) &&
				p.lines[p.pos].indent == indent &&
				(strings.HasPrefix(p.lines[p.pos].text, "- ") || p.lines[p.pos].text == "-")
			if !zeroIndented && (p.pos >= len(p.lines) || p.lines[p.pos].indent <= indent) {
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
			// End of the sequence. For a zero-indented one this is the owning
			// mapping's next key, which that mapping then parses normally. For
			// an indented one the line sits deeper than the mapping, which
			// rejects it as unexpected indentation — either way the caller
			// produces the better message than a blanket error here would.
			break
		}
		rest := strings.TrimSpace(strings.TrimPrefix(l.text, "-"))
		if rest == "" {
			return nil, fmt.Errorf("line %d: empty sequence item", l.no)
		}
		if strings.HasPrefix(rest, "- ") || rest == "-" {
			return nil, fmt.Errorf("line %d: nested sequences are not supported", l.no)
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
