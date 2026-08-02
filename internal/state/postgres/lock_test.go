package postgres

import (
	"strings"
	"testing"
)

func TestResourceLockKeyIsTextSafeAndUnambiguous(t *testing.T) {
	key := resourceLockKey("lab-01", "node-01")
	if strings.ContainsRune(key, '\x00') {
		t.Fatalf("lock key contains NUL: %q", key)
	}
	if resourceLockKey("a|2:vm|1:b", "c") == resourceLockKey("a", "b|2:vm|1:c") {
		t.Fatal("length-prefixed lock keys collided")
	}
	if key != resourceLockKey("lab-01", "node-01") {
		t.Fatal("lock key is not deterministic")
	}
}
