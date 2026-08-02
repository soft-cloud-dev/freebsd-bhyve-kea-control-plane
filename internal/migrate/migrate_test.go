package migrate

import "testing"

func TestEmbeddedMigrationsAreOrderedAndChecksummed(t *testing.T) {
	runner, err := New()
	if err != nil {
		t.Fatal(err)
	}
	if len(runner.migrations) == 0 {
		t.Fatal("no embedded migrations")
	}
	for index, migration := range runner.migrations {
		if migration.Version <= 0 || len(migration.Checksum) != 64 || migration.SQL == "" {
			t.Fatalf("invalid migration: %#v", migration)
		}
		if index > 0 && runner.migrations[index-1].Version >= migration.Version {
			t.Fatalf("migrations are not strictly ordered: %#v", runner.migrations)
		}
	}
}
