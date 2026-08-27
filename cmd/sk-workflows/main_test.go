package main

import (
	"bytes"
	"os"
	"strings"
	"testing"
)

func TestRunDelegatesToCLI(t *testing.T) {
	var out, errb bytes.Buffer
	if code := run([]string{"--help"}, &out, &errb); code != 0 {
		t.Fatalf("code=%d", code)
	}
	if !strings.Contains(out.String(), "sk-workflows detect") {
		t.Fatalf("stdout=%q", out.String())
	}
}

func TestMainFunctionUsesExitCode(t *testing.T) {
	oldArgs := os.Args
	oldExit := exit
	defer func() {
		os.Args = oldArgs
		exit = oldExit
	}()

	os.Args = []string{"sk-workflows", "--help"}
	var got int
	exit = func(code int) {
		got = code
	}
	main()
	if got != 0 {
		t.Fatalf("exit code=%d", got)
	}
}

// Audit C-12. Vorher lief alles unter context.Background(), also ohne Frist.
// Haengt ein Unterprozess — `gh` an einer nicht antwortenden API, `git` an
// einem Credential-Prompt —, haengt die CLI, bis der Runner den ganzen Job
// abraeumt: ein Job-Timeout ohne Hinweis auf die Ursache statt eines Fehlers,
// den jemand lesen kann.
//
// Die Frist ist grosszuegig; geprueft wird hier vor allem, dass ein
// UNLESBARER Override nicht stillschweigend auf die Vorgabe zurueckfaellt.
// Wer die Frist setzt, will sie geaendert haben — ein ignorierter Wert waere
// genau die Sorte stiller Wirkungslosigkeit, die dieser Audit reihenweise
// gefunden hat.
func TestRunRejectsUnparsableTimeoutOverride(t *testing.T) {
	for _, raw := range []string{"nonsense", "-5m", "0", "45"} {
		t.Setenv("SK_WORKFLOWS_TIMEOUT", raw)
		var out, errb bytes.Buffer
		code := run([]string{"detect", "-h"}, &out, &errb)
		if code != 2 {
			t.Errorf("SK_WORKFLOWS_TIMEOUT=%q: exit=%d, want 2", raw, code)
		}
		if !strings.Contains(errb.String(), "SK_WORKFLOWS_TIMEOUT") {
			t.Errorf("SK_WORKFLOWS_TIMEOUT=%q: Meldung nennt die Variable nicht: %q", raw, errb.String())
		}
	}
}

// Gegenprobe: ein GUELTIGER Override wird angenommen und aendert nichts am
// normalen Ablauf.
func TestRunAcceptsValidTimeoutOverride(t *testing.T) {
	t.Setenv("SK_WORKFLOWS_TIMEOUT", "45m")
	var out, errb bytes.Buffer
	code := run([]string{"detect", "-h"}, &out, &errb)
	if strings.Contains(errb.String(), "SK_WORKFLOWS_TIMEOUT") {
		t.Fatalf("gueltiger Wert wurde beanstandet: %q", errb.String())
	}
	_ = code
}
