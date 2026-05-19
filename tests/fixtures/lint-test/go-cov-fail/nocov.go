package gocovfail

// Untested returns a constant. Coverage = 0 % because no _test.go exists.
func Untested() int {
	return 1
}
