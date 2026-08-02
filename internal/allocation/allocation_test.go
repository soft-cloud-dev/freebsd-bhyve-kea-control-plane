package allocation

import "testing"

func TestAddressesInclusive(t *testing.T) {
	addresses, err := Addresses("10.0.20.10", "10.0.20.12")
	if err != nil {
		t.Fatal(err)
	}
	if len(addresses) != 3 || addresses[0].String() != "10.0.20.10" || addresses[2].String() != "10.0.20.12" {
		t.Fatalf("unexpected addresses: %#v", addresses)
	}
}

func TestMACDeterministicAndLocal(t *testing.T) {
	first := MAC("lab-01", "node-01", 0)
	second := MAC("lab-01", "node-01", 0)
	other := MAC("lab-01", "node-01", 1)
	if first != second || first == other {
		t.Fatalf("unexpected identity first=%s second=%s other=%s", first, second, other)
	}
	if first[:2] != "02" && first[:2] != "06" && first[:2] != "0a" && first[:2] != "0e" {
		// The low two bits must encode locally administered unicast. The higher bits are hash-derived.
		var firstOctet uint8
		if _, err := fmt.Sscanf(first[:2], "%02x", &firstOctet); err != nil || firstOctet&0x03 != 0x02 {
			t.Fatalf("not a locally administered unicast MAC: %s", first)
		}
	}
}

func TestStorageNames(t *testing.T) {
	if got := Dataset("zroot/vm/", "node-01"); got != "zroot/vm/node-01" {
		t.Fatal(got)
	}
	if got := Zvol("zroot/vm", "node-01"); got != "zroot/vm/node-01/disk0" {
		t.Fatal(got)
	}
}
