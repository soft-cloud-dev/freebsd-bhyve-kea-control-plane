package allocation

import (
	"crypto/sha256"
	"errors"
	"fmt"
	"net/netip"
	"strings"
)

var ErrExhausted = errors.New("allocation pool exhausted")

func Addresses(first, last string) ([]netip.Addr, error) {
	start, err := netip.ParseAddr(first)
	if err != nil {
		return nil, fmt.Errorf("parse first host: %w", err)
	}
	end, err := netip.ParseAddr(last)
	if err != nil {
		return nil, fmt.Errorf("parse last host: %w", err)
	}
	if !start.Is4() || !end.Is4() || end.Less(start) {
		return nil, errors.New("allocation range must be an ordered IPv4 range")
	}
	addresses := make([]netip.Addr, 0)
	for current := start; ; current = current.Next() {
		addresses = append(addresses, current)
		if current == end {
			break
		}
		if !current.IsValid() || len(addresses) > 1<<20 {
			return nil, errors.New("allocation range is too large")
		}
	}
	return addresses, nil
}

func MAC(controlPlaneID, resource string, counter uint32) string {
	seed := fmt.Sprintf("%d:%s|%d:%s|%d", len(controlPlaneID), controlPlaneID, len(resource), resource, counter)
	digest := sha256.Sum256([]byte(seed))
	bytes := [6]byte{digest[0], digest[1], digest[2], digest[3], digest[4], digest[5]}
	bytes[0] = (bytes[0] | 0x02) & 0xfe
	return fmt.Sprintf("%02x:%02x:%02x:%02x:%02x:%02x", bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5])
}

func Dataset(root, resource string) string {
	return strings.TrimSuffix(root, "/") + "/" + resource
}

func Zvol(root, resource string) string {
	return Dataset(root, resource) + "/disk0"
}
