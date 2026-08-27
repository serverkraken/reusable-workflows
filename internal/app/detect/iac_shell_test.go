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

// Ein Kindmodul ist KEIN Stack. `working_directories` in tofu-validate.yml
// ist als "ein Stack pro Zeile" dokumentiert, und im Modulordner liegt keine
// .terraform.lock.hcl — `init -lockfile=readonly` koennte dort gar nicht
// durchlaufen. Ohne den Filter meldete die Erkennung
// ["tofu", "tofu/modules/server"] (nachgestellt).
func TestIaCSkipsChildModules(t *testing.T) {
	p := detectFixture(t, "iac-nested-module").Profile

	if p.IaC == nil {
		t.Fatal("erwartet ein iac-Signal, bekam nil")
	}
	if got, want := p.IaC.Directories, []string{"tofu"}; !reflect.DeepEqual(got, want) {
		t.Errorf("iac.directories = %v, erwartet %v — tofu/modules/server ist ein Modul, kein Stack", got, want)
	}
}

// Die `modules/`-Heuristik muss SEGMENTgenau sein: `mymodules` und
// `modules-old` sind normale Verzeichnisnamen und duerfen nicht mitgefiltert
// werden. Zwilling der jq-Bedingung in classify_iac_signal.
func TestIsChildModulePath(t *testing.T) {
	for _, tc := range []struct {
		dir  string
		want bool
	}{
		{"tofu", false},
		{"tofu/modules/server", true},
		{"modules/server", true},
		{"modules", true},
		{"tofu/mymodules/server", false},
		{"tofu/modules-old/server", false},
		{"tofu/submodules", false},
		{".", false},
	} {
		if got := isChildModulePath(tc.dir); got != tc.want {
			t.Errorf("isChildModulePath(%q) = %v, erwartet %v", tc.dir, got, tc.want)
		}
	}
}

// Symlinks zaehlen in KEINER der beiden Engines. Die Fixture legt neben den
// echten Dateien ein Verzeichnis an, das ausschliesslich Symlinks enthaelt —
// einen gueltigen und einen kaputten je Endung. Zaehlte der Walker Symlinks
// mit, erschiene `linked-only` als Stack und als Shell-Glob; die Bash-Engine
// (`find -type f`) meldete beides nicht, und genau das war die Abweichung.
func TestSignalsIgnoreSymlinks(t *testing.T) {
	p := detectFixture(t, "symlinked-signals").Profile

	if p.IaC == nil {
		t.Fatal("erwartet ein iac-Signal, bekam nil")
	}
	if got, want := p.IaC.Directories, []string{"tofu"}; !reflect.DeepEqual(got, want) {
		t.Errorf("iac.directories = %v, erwartet %v — linked-only enthaelt nur Symlinks (einer davon kaputt)", got, want)
	}
	if p.Shell == nil {
		t.Fatal("erwartet ein shell-Signal, bekam nil")
	}
	if got, want := p.Shell.Paths, []string{"scripts/**/*.sh"}; !reflect.DeepEqual(got, want) {
		t.Errorf("shell.paths = %v, erwartet %v", got, want)
	}
	// Ein kaputter Symlink ist kein unlesbarer Pfad: geprueft wird der Typ des
	// Eintrags, nicht sein Ziel. Er darf deshalb auch keine Warnung erzeugen.
	for _, w := range p.Warnings {
		if w.Code == "path_unreadable" {
			t.Errorf("kaputter Symlink erzeugte eine path_unreadable-Warnung: %+v", w)
		}
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
