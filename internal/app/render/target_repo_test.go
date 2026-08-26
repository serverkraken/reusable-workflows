package render

import (
	"encoding/json"
	"testing"
)

// Die Templates interpolieren target_repo direkt:
//
//	oci_registry: ghcr.io/{{ .profile.target_repo }}/charts
//
// Ist der Wert leer, entsteht `ghcr.io//charts` - syntaktisch einwandfreies
// YAML mit einer Registry, die es nicht gibt. actionlint sieht davon nichts,
// weil es ein gueltiger String ist.
//
// onboard-render.sh faengt das laengst ab, und der Kommentar dort behauptet,
// der Go-Pfad tue es auch - belegt aber mit `preview`, einem anderen
// Unterbefehl. `render` selbst hatte den Rueckfall nie. Gemessen an der Fixture
// service-with-helm:
//
//	Go    oci_registry: ghcr.io//charts
//	Bash  oci_registry: ghcr.io/demo/charts
//
// repoName() steht in derselben Datei und leitet genau diesen Rueckfall her -
// es wurde bloss nur fuer den $REPO-Ersatz benutzt.

func TestFillTargetRepoUsesFallbackWhenEmpty(t *testing.T) {
	for _, c := range []struct {
		name, raw, fallback, want string
	}{
		{"leer", `{"target_repo":"","schema_version":1}`, "demo", "demo"},
		{"fehlt ganz", `{"schema_version":1}`, "demo", "demo"},
		{"gesetzt bleibt unberuehrt", `{"target_repo":"serverkraken/svc"}`, "demo", "serverkraken/svc"},
		{"kein Rueckfall verfuegbar", `{"target_repo":""}`, "", ""},
	} {
		t.Run(c.name, func(t *testing.T) {
			out, err := fillTargetRepo([]byte(c.raw), c.fallback)
			if err != nil {
				t.Fatal(err)
			}
			var m map[string]any
			if err := json.Unmarshal(out, &m); err != nil {
				t.Fatal(err)
			}
			got, _ := m["target_repo"].(string)
			if got != c.want {
				t.Fatalf("target_repo=%q, erwartet %q", got, c.want)
			}
		})
	}
}

func TestFillTargetRepoKeepsUnmodelledFields(t *testing.T) {
	// Der Kontext reicht das Profil weiter, wie es ist. Ein Umweg ueber
	// domain.Profile wuerde jedes Feld verlieren, das dort (noch) nicht
	// modelliert ist - und die Templates lesen aus dem JSON, nicht aus der
	// Struktur.
	out, err := fillTargetRepo([]byte(`{"target_repo":"","kuenftiges_feld":{"a":[1,2]}}`), "demo")
	if err != nil {
		t.Fatal(err)
	}
	var m map[string]any
	if err := json.Unmarshal(out, &m); err != nil {
		t.Fatal(err)
	}
	if _, ok := m["kuenftiges_feld"]; !ok {
		t.Fatalf("unbekanntes Feld verloren: %s", out)
	}
}

func TestFillTargetRepoRejectsBrokenJSON(t *testing.T) {
	if _, err := fillTargetRepo([]byte(`{nope`), "demo"); err == nil {
		t.Fatal("erwartet: Fehler bei kaputtem Profil-JSON")
	}
}
