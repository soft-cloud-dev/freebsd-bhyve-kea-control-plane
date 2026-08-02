package doctor

import "testing"

func TestParsePostgresTargetUnixSocket(t *testing.T) {
	target, err := parsePostgresTarget("host=/var/run/postgresql port=5433 dbname=controlplane user=controlplane")
	if err != nil {
		t.Fatal(err)
	}
	if target.Network != "unix" || target.Address != "/var/run/postgresql/.s.PGSQL.5433" {
		t.Fatalf("unexpected target: %#v", target)
	}
}

func TestParsePostgresTargetTCP(t *testing.T) {
	target, err := parsePostgresTarget("host=127.0.0.1 dbname=controlplane user=controlplane")
	if err != nil {
		t.Fatal(err)
	}
	if target.Network != "tcp" || target.Address != "127.0.0.1:5432" {
		t.Fatalf("unexpected target: %#v", target)
	}
}
