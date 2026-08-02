package main

import (
	"os"

	"github.com/soft-cloud-dev/freebsd-bhyve-kea-control-plane/internal/cli"
)

func main() {
	os.Exit(cli.Run(os.Args[1:], os.Stdout, os.Stderr))
}
