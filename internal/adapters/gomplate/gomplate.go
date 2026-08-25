package gomplate

import (
	"bytes"
	"context"
	"fmt"
	"os"
	"os/exec"
	"strings"
)

type Adapter struct {
	Binary string
}

func (a Adapter) Execute(ctx context.Context, templatePath, outputPath, contextPath string) error {
	binary := a.Binary
	if binary == "" {
		binary = "gomplate"
	}
	cmd := exec.CommandContext(ctx, binary, "-c", ".="+contextPath, "-f", templatePath, "-o", outputPath)
	var stderr bytes.Buffer
	cmd.Stderr = &stderr
	if err := cmd.Run(); err != nil {
		return fmt.Errorf("%w: %s", err, stderr.String())
	}

	// gomplate schreibt die Datei selbst und beendet mit 0, auch wenn das
	// Template nichts ergeben hat — etwa weil jeder Zweig darin falsch war
	// (Audit C-6). Der Renderer nahm das an, der Lock hashte die leere Datei,
	// und der Lauf blieb gruen: ein zertifizierter leerer Workflow im
	// Adopter-Repo, den GitHub kommentarlos ignoriert.
	//
	// Keine der gerenderten Dateien darf leer sein — die kleinste eingecheckte
	// Golden-Ausgabe hat 19 Byte (`.release-please-manifest.json`). Auch
	// reiner Whitespace zaehlt: der Bash-Renderer normalisiert leeren Inhalt zu
	// einem einzelnen Zeilenumbruch, und "eine Datei mit nur \n" ist derselbe
	// Fehler in anderer Verkleidung.
	out, err := os.ReadFile(outputPath)
	if err != nil {
		return fmt.Errorf("rendered output unreadable: %w", err)
	}
	if strings.TrimSpace(string(out)) == "" {
		return fmt.Errorf("template %s rendered nothing; refusing to write an empty %s", templatePath, outputPath)
	}
	return nil
}
