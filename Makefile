SHELL = /bin/sh

GO ?= go
BIN_DIR ?= bin
CPCTL ?= ${BIN_DIR}/cpctl
SITE ?= config/site.example.toml
VM ?= config/vms/freebsd-node.example.toml

.PHONY: all help build fmt lint test examples verify doctor clean

all: verify

help:
	@echo "FreeBSD bhyve + Kea Control Plane V2"
	@echo "make build      Build cpctl"
	@echo "make test       Run unit tests with the race detector"
	@echo "make lint       Run go vet"
	@echo "make examples   Validate checked-in configuration examples"
	@echo "make verify     Run all portable verification"
	@echo "make doctor     Inspect a FreeBSD target without live service probes"

build:
	@mkdir -p "${BIN_DIR}"
	${GO} build -trimpath -o "${CPCTL}" ./cmd/cpctl

fmt:
	@files="$$(gofmt -l cmd internal)"; \
	if [ -n "$$files" ]; then \
		echo "gofmt required:" >&2; \
		echo "$$files" >&2; \
		exit 1; \
	fi

lint:
	${GO} vet ./...

test:
	${GO} test -race ./...

examples: build
	"${CPCTL}" plan --config "${SITE}" --file "${VM}" --generation 1 --json >/dev/null

verify: fmt lint test examples

doctor: build
	"${CPCTL}" doctor --config "${SITE}" --offline

clean:
	rm -rf "${BIN_DIR}"
