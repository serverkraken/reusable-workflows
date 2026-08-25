package defaultsfs

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/serverkraken/reusable-workflows/internal/domain"
)

// Warum diese Tests: `json.Unmarshal` einer leeren Datei ist erfolgreich und
// liefert den Nullwert. Fuer RepoDefaults heisst das "alle Schutzschalter aus".
// Gemessen ergab das gegen ein geschuetztes Repo den PUT
//
//	{"required_pull_request_reviews":null,"enforce_admins":false,
//	 "required_linear_history":false,"required_conversation_resolution":false,...}
//
// Der Branch-Schutz waere abgeraeumt worden, und der Lauf haette
// defaults_applied=true gemeldet.
func writeConfig(t *testing.T, body string) string {
	t.Helper()
	root := t.TempDir()
	dir := filepath.Join(root, "catalog")
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, "onboard-defaults.json"), []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}
	return root
}

func TestReadDefaultsRejectsEmptyObject(t *testing.T) {
	_, err := Store{}.ReadDefaults(writeConfig(t, `{}`))
	if err == nil {
		t.Fatal("eine leere Konfiguration muss abgelehnt werden, sie bedeutet sonst 'alle Schalter aus'")
	}
	if !strings.Contains(err.Error(), "_schema_version") {
		t.Fatalf("Fehler soll die Ursache benennen, war: %v", err)
	}
}

func TestReadDefaultsRejectsForeignSchema(t *testing.T) {
	_, err := Store{}.ReadDefaults(writeConfig(t, `{"_schema_version": 99}`))
	if err == nil {
		t.Fatal("eine fremde Schemafassung muss abgelehnt werden statt teilweise gelesen")
	}
}

func TestReadDefaultsRejectsTruncatedFile(t *testing.T) {
	// Abgeschnitten mitten im JSON: hier faengt schon der Parser.
	_, err := Store{}.ReadDefaults(writeConfig(t, `{"_schema_version": 1, "branch_pro`))
	if err == nil {
		t.Fatal("abgeschnittenes JSON muss abgelehnt werden")
	}
}

func TestReadDefaultsAcceptsSupportedSchema(t *testing.T) {
	cfg, err := Store{}.ReadDefaults(writeConfig(t, `{"_schema_version": 1}`))
	if err != nil {
		t.Fatalf("die unterstuetzte Fassung muss durchkommen: %v", err)
	}
	if cfg.SchemaVersion != domain.SupportedDefaultsSchema {
		t.Fatalf("SchemaVersion=%d, erwartet %d", cfg.SchemaVersion, domain.SupportedDefaultsSchema)
	}
}

// Die ausgelieferte Konfiguration muss die Pruefung bestehen — sonst hat der
// Fix den Produktivpfad gebrochen.
func TestShippedConfigPassesValidation(t *testing.T) {
	root, err := filepath.Abs("../../..")
	if err != nil {
		t.Fatal(err)
	}
	_, err = Store{}.ReadDefaults(root)
	if err != nil {
		t.Fatalf("catalog/onboard-defaults.json besteht die eigene Pruefung nicht: %v", err)
	}
}
