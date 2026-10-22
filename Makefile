# Everything here runs offline except docs. No test in this repository touches
# a network.

BIN := bin/zc-care
# local builds carry the git version with a -dev suffix
VERSION ?= $(shell git describe --tags --always --dirty 2>/dev/null | sed 's/^v//')-dev
LDFLAGS := -X main.version=$(VERSION)
# CI pins the same version in ci.yml and release.yml.
GOLANGCI_LINT_VERSION := 2.15.0
# The release build, as release.yml makes it.
BUILD_FLAGS := -trimpath -ldflags "-s -w $(LDFLAGS)"

.PHONY: all build run test hook-test test-unit race cover lint fmt install app app-icon app-test app-install evals docs-gen docs docs-serve clean vuln verify

all: lint test build

build:
	CGO_ENABLED=0 go build $(BUILD_FLAGS) -o $(BIN) ./cmd/zc-care

run: build
	$(BIN) $(ARGS)

test:
	go test ./...

test-unit:
	go test -short ./...

# The PreToolUse guard in the plugin; part of lint, so test stays plain go test.
hook-test:
	sh plugin/hooks/guard-apply_test.sh

race:
	go test -race ./...

# -coverpkg: most code is exercised through the CLI tests in cmd/, which
# per-package counting would not credit.
cover:
	go test -coverpkg=./... -coverprofile=coverage.out ./...
	go tool cover -func=coverage.out | tail -1

lint: hook-test
	@test -z "$$(gofmt -l .)" || { gofmt -l .; echo "not gofmt-clean"; exit 1; }
	go vet ./...
	@command -v golangci-lint >/dev/null 2>&1 || { echo "golangci-lint not installed: brew install golangci-lint (CI pins $(GOLANGCI_LINT_VERSION))" >&2; exit 1; }
	@golangci-lint version 2>&1 | grep -q '$(GOLANGCI_LINT_VERSION)' || { echo "golangci-lint $$(golangci-lint version --short 2>/dev/null || echo unknown) found, CI pins $(GOLANGCI_LINT_VERSION)" >&2; exit 1; }
	golangci-lint run

fmt:
	gofmt -w .

install: build
	mkdir -p "$(HOME)/.local/bin"
	cp $(BIN) "$(HOME)/.local/bin/zc-care.new"
	mv "$(HOME)/.local/bin/zc-care.new" "$(HOME)/.local/bin/zc-care"
	@echo "installed $(VERSION) to ~/.local/bin/zc-care (add to PATH if needed)"

# The menu bar app, app: a SwiftPM package, macOS only.
APP := bin/app.noindex/ZCCare.app

app: build
	VERSION=$(VERSION) CLI=$(BIN) app/package.sh $(APP)

# Redraws the app's icons from app/icon/mark.svg.
app-icon:
	swift app/icon/make-icon.swift app/Resources

app-test:
	swift test --package-path app

# A Finder-opened app gets no shell environment, so the config the shell
# names is handed to it once; the app's Choose Config changes it later. The
# CLI the app carries is linked onto PATH, as the cask does.
app-install: app
	rm -rf "$(HOME)/Applications/ZCCare.app"
	mkdir -p "$(HOME)/Applications"
	cp -R $(APP) "$(HOME)/Applications/ZCCare.app"
	mkdir -p "$(HOME)/.local/bin"
	ln -sf "$(HOME)/Applications/ZCCare.app/Contents/MacOS/zc-care" "$(HOME)/.local/bin/zc-care"
	@if [ -n "$$ZC_CARE_CONFIG" ]; then defaults write dev.zoolcoder.zccare configPath "$$ZC_CARE_CONFIG"; fi
	@echo "installed ~/Applications/ZCCare.app and linked its CLI to ~/.local/bin; open it once, then tick Open at login"

evals: ## run the plugin eval suite (plugin/evals/), needs the claude CLI
	claude plugin eval plugin --no-publish --threshold 0.8

docs-gen: ## rewrite the generated command reference from the usage text
	UPDATE_DOCS=1 go test ./cmd/zc-care -run TestCommandReferenceMatchesUsage

docs:
	@if [ ! -d node_modules ] || [ package-lock.json -nt node_modules ]; then npm ci; fi
	npm run docs

docs-serve: docs
	npx --yes http-server build/site -p 8080 -c-1

clean:
	rm -rf bin dist build coverage.out

# govulncheck, pinned by the tool directive in go.mod, like CI.
vuln:
	go tool govulncheck ./...

verify:
	go mod verify
