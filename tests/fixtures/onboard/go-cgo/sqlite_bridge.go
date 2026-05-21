package main

/*
#include <stdlib.h>
*/
import "C"

// Touches cgo so onboard-detect flags this fixture as cgo-using even without
// the go-sqlite3 indirect link path. Mirrors what real adopters (skytrack)
// look like once a package imports a C-bridging library.
func cgoTouch() {
	_ = C.malloc(0)
}
