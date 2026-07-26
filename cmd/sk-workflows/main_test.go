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
