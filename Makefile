# Everything here runs offline except docs. No test in this repository touches
# a network.

BIN := bin/zc-care
# local builds carry the git version with a -dev suffix
VERSION ?= $(shell git describe --tags --always --dirty 2>/dev/null | sed 's/^v//')-dev
LDFLAGS := -X main.version=$(VERSION)

.PHONY: all build run test test-unit race cover lint fmt install app app-icon app-test app-install evals docs docs-serve clean

all: lint test build

build:
	go build -ldflags "$(LDFLAGS)" -o $(BIN) ./cmd/zc-care

run: build
	$(BIN) $(ARGS)

test:
	go test ./...

test-unit:
	go test -short ./...

race:
	go test -race ./...

# -coverpkg: most code is exercised through the CLI tests in cmd/, which
# per-package counting would not credit.
cover:
	go test -coverpkg=./... -coverprofile=coverage.out ./...
	go tool cover -func=coverage.out | tail -1

lint:
	@test -z "$$(gofmt -l .)" || { gofmt -l .; echo "not gofmt-clean"; exit 1; }
	go vet ./...
	@if command -v golangci-lint >/dev/null 2>&1; then golangci-lint run; else echo "golangci-lint not installed, go vet only"; fi

fmt:
	gofmt -w .

install: build
	mkdir -p $(HOME)/.local/bin
	cp $(BIN) $(HOME)/.local/bin/zc-care.new
	mv $(HOME)/.local/bin/zc-care.new $(HOME)/.local/bin/zc-care
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
	rm -rf $(HOME)/Applications/ZCCare.app
	mkdir -p $(HOME)/Applications
	cp -R $(APP) $(HOME)/Applications/ZCCare.app
	mkdir -p $(HOME)/.local/bin
	ln -sf $(HOME)/Applications/ZCCare.app/Contents/MacOS/zc-care $(HOME)/.local/bin/zc-care
	@if [ -n "$$ZC_CARE_CONFIG" ]; then defaults write dev.zoolcoder.zccare configPath "$$ZC_CARE_CONFIG"; fi
	@echo "installed ~/Applications/ZCCare.app and linked its CLI to ~/.local/bin; open it once, then tick Open at login"

evals: ## run the plugin eval suite (plugin/evals/), needs the claude CLI
	claude plugin eval plugin --no-publish --threshold 0.8

docs-gen: ## rewrite the generated command reference from the usage text
	UPDATE_DOCS=1 go test ./cmd/zc-care -run TestCommandReferenceMatchesUsage

docs:
	[ -d node_modules ] || npm ci
	npm run docs

docs-serve: docs
	npx --yes http-server build/site -p 8080 -c-1

clean:
	rm -rf bin dist build coverage.out
