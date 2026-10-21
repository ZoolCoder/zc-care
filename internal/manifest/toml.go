package manifest

import (
	"regexp"
	"strconv"
)

var bareKey = regexp.MustCompile(`^[A-Za-z0-9_-]+$`)

// TOMLKey is k as a TOML key: bare when it may be, else quoted.
func TOMLKey(k string) string {
	if bareKey.MatchString(k) {
		return k
	}
	return strconv.Quote(k)
}
