package detect

import (
	"reflect"
	"testing"
)

// Ein Repo mit tofu/ und Shell-Skripten muss beide Signale tragen — und
// dabei ein Go-Repo BLEIBEN. Die Signale sind additiv, nicht klassifizierend.
func TestIaCAndShellSignals(t *testing.T) {
	p := detectFixture(t, "iac-shell-repo").Profile

	if p.IaC == nil {
		t.Fatal("erwartet ein iac-Signal, bekam nil")
	}
	if got, want := p.IaC.Directories, []string{"tofu"}; !reflect.DeepEqual(got, want) {
		t.Errorf("iac.directories = %v, erwartet %v", got, want)
	}

	if p.Shell == nil {
		t.Fatal("erwartet ein shell-Signal, bekam nil")
	}
	want := []string{".taskfiles/**/*.sh", "scripts/**/*.sh"}
	if got := p.Shell.Paths; !reflect.DeepEqual(got, want) {
		t.Errorf("shell.paths = %v, erwartet %v", got, want)
	}

	if p.Components[0].PrimaryLanguage != "go" {
		t.Errorf("primary_language = %q, erwartet \"go\" — die Signale duerfen die Sprache nicht ueberschreiben",
			p.Components[0].PrimaryLanguage)
	}
}

// Der Kern der Rueckwaertskompatibilitaet: ein Repo ohne .tf und ohne .sh
// darf KEINE der beiden Schluessel im Profil tragen. `omitempty` sorgt dafuer,
// dass das gerenderte Profil-JSON bestehender Adopter byte-identisch bleibt —
// genau das prueft check-rendered-goldens.sh.
func TestNoIaCOrShellSignalWhenAbsent(t *testing.T) {
	p := detectFixture(t, "go-repo").Profile
	if p.IaC != nil {
		t.Errorf("go-repo darf kein iac-Signal haben, bekam %+v", p.IaC)
	}
	if p.Shell != nil {
		t.Errorf("go-repo darf kein shell-Signal haben, bekam %+v", p.Shell)
	}
}
