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
	// NEBEN das Ziel rendern, dann umbenennen (Audit C-9).
	//
	// `gomplate -o <ziel>` schreibt direkt dorthin und streamt dabei. Bricht
	// das Template mittendrin ab, bleibt eine HALBE Datei liegen. Gemessen an
	// einer Vorlage, die 50 Zeilen ausgibt und in Zeile 51 auf einen fehlenden
	// Schluessel laeuft:
	//
	//	gomplate: map has no entry for key "nichtVorhanden"   (rc != 0)
	//	out.yml:  741 Byte, 50 Zeilen                         liegt trotzdem da
	//
	// outputPath liegt im Adopter-Checkout. Der Renderer meldet den Fehler und
	// der Lauf wird rot — die verstuemmelte Workflow-Datei bleibt aber im
	// Arbeitsverzeichnis stehen, wo ein Wiederholungslauf, ein spaeterer
	// Schritt oder ein Mensch sie einchecken kann. Dieselbe Ueberlegung wie
	// bei I-18, wo der gomplate-Download aus demselben Grund neben das Ziel
	// geladen wird.
	//
	// Die temporaere Datei liegt im GLEICHEN Verzeichnis, damit os.Rename ein
	// atomarer Rename auf demselben Dateisystem ist und nicht ein Kopieren
	// ueber eine Grenze hinweg. ensureInsideTarget hat outputPath bereits
	// geprueft; ein Geschwister davon liegt damit ebenfalls innerhalb.
	tmpPath := outputPath + ".sk-render"
	// Nach erfolgreichem Rename ein No-op; der Rueckgabewert ist bewusst
	// verworfen: liegt die Datei nicht mehr, ist genau das der
	// gewuenschte Zustand.
	defer func() { _ = os.Remove(tmpPath) }()

	cmd := exec.CommandContext(ctx, binary, "-c", ".="+contextPath, "-f", templatePath, "-o", tmpPath)
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
	out, err := os.ReadFile(tmpPath)
	if err != nil {
		return fmt.Errorf("rendered output unreadable: %w", err)
	}
	if strings.TrimSpace(string(out)) == "" {
		// Die Meldung sagte schon immer "refusing to write an empty" — bis
		// C-9 war die Datei zu diesem Zeitpunkt aber laengst geschrieben.
		// Jetzt stimmt die Aussage: geprueft wird die temporaere Datei, und
		// das Ziel wird gar nicht erst angefasst.
		return fmt.Errorf("template %s rendered nothing; refusing to write an empty %s", templatePath, outputPath)
	}

	if err := os.Rename(tmpPath, outputPath); err != nil {
		return fmt.Errorf("could not move the rendered output into place: %w", err)
	}
	return nil
}
