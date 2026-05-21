package main

import "testing"

// TestGreet covers greet(). Combined with TestMain_smoke calling main(),
// this gives the package 100% statement coverage, which lets test-go.yml's
// coverage gate exercise its NUMERIC comparison (threshold value 70 ⇐ 100)
// against a real run — that's the whole point of the vars-coercion caller.
func TestGreet(t *testing.T) {
	got := greet()
	want := "hello from minimal-go fixture"
	if got != want {
		t.Fatalf("greet() = %q, want %q", got, want)
	}
}

// TestMain_smoke invokes main() so its single statement counts as covered.
// main is just a regular function from the test binary's perspective; calling
// it is the canonical Go trick to bring a `package main` fixture above an
// arbitrary coverage threshold without splitting code across files.
func TestMain_smoke(t *testing.T) {
	main()
}
