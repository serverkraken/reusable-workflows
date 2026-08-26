package drift

import (
	"strings"
	"testing"
)

// Gefunden ueber das Suchmuster "Pfad verlaesst den Checkout", nicht ueber die
// Fundliste.
//
// Die beiden Vergleichsschleifen joinen die Lock-Schluessel direkt an den
// Zielpfad. Ein Lock mit `"../geheim/secret.txt"` liess drift die Datei
// AUSSERHALB des Repos lesen und im Bericht nennen:
//
//	status=modified
//	modified=../geheim/secret.txt
//
// Damit ist der Drift-Bericht ein Existenz- und Inhalts-Orakel gegen den
// Runner: existiert die Datei, und stimmt ihr sha256 mit einem gewaehlten Wert
// ueberein? Auf einem self-hosted Runner ist das dessen Dateisystem.
//
// Geprueft wird beim LADEN des Locks, damit es auch fuer jede kuenftige
// Nutzung der Dateiliste gilt. Der Bash-Pfad prueft dasselbe.

func TestLockPathInsideTargetRejectsEscapes(t *testing.T) {
	for _, rel := range []string{
		"../geheim/secret.txt",
		"..",
		"a/../../b",
		"/etc/hosts",
	} {
		if err := lockPathInsideTarget(rel); err == nil {
			t.Errorf("%q wurde akzeptiert, zeigt aber aus dem Repo heraus", rel)
		}
	}
}

func TestLockPathInsideTargetAcceptsOrdinaryEntries(t *testing.T) {
	// Gegenprobe: die Pruefung darf nichts abweisen, was ein echter Lock
	// enthaelt. `a/../b` bleibt drin — es loest zu `b` auf.
	for _, rel := range []string{
		".github/workflows/ci.yml",
		"release-please-config.json",
		".release-please-manifest.json",
		"a/../b",
	} {
		if err := lockPathInsideTarget(rel); err != nil {
			t.Errorf("%q wurde abgewiesen: %v", rel, err)
		}
	}
}

func TestLockPathErrorNamesThePath(t *testing.T) {
	// Ohne den Pfad im Text muesste jemand den ganzen Lock durchsuchen.
	err := lockPathInsideTarget("../geheim/secret.txt")
	if err == nil || !strings.Contains(err.Error(), "../geheim/secret.txt") {
		t.Fatalf("Fehlertext nennt den Pfad nicht: %v", err)
	}
}
