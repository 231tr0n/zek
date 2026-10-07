IMAGE              ?= zek
# Pin the latest versions explicitly; bump these to move to a newer release.
ALPINE_VERSION     ?= 3.24.1
KUBERNETES_VERSION ?= v1.37.0

DOCKER ?= docker

# Per-build id comes from git: the short commit SHA, suffixed with "-dirty"
# when the working tree has uncommitted changes. No stored state, so the id is
# the same on every machine with the same commit. Override BUILD_ID to tag a
# build differently. Builds of the same commit reuse the same tag.
BUILD_ID  ?= $(shell git describe --always --dirty 2>/dev/null || echo unknown)
TAG       := $(ALPINE_VERSION)-$(KUBERNETES_VERSION)-$(BUILD_ID)
# Stable name for the newest build of this alpine/k8s combination, so
# scripts can pin the combo without tracking the git-based BUILD_ID.
COMBO_TAG := $(ALPINE_VERSION)-$(KUBERNETES_VERSION)-latest

.PHONY: build build-nocache lint help

# Shared build+tag recipe; $(1) is extra docker build flags (build-nocache
# passes --no-cache to force the image preload step to re-run).
define build_image
	$(DOCKER) build $(1) -t $(IMAGE):$(TAG) \
	--build-arg ALPINE_VERSION=$(ALPINE_VERSION) \
	--build-arg KUBERNETES_VERSION=$(KUBERNETES_VERSION) .
	$(DOCKER) tag $(IMAGE):$(TAG) $(IMAGE):latest
	$(DOCKER) tag $(IMAGE):$(TAG) $(IMAGE):$(COMBO_TAG)
endef

build: ## Build + tag $(IMAGE):$(TAG), $(IMAGE):$(COMBO_TAG) and :latest
	$(call build_image)

build-nocache: ## Build, forcing the image preload step to re-run
	$(call build_image,--no-cache)

# Keep in sync with .github/workflows/lint.yml (same image, packages and go installs).
lint: ## Run ./lint.sh in a fedora:latest container, exactly like CI
	$(DOCKER) run --rm \
		-v "$(CURDIR):/repo:z" -w /repo \
		fedora:latest bash -c ' \
			set -euo pipefail; \
			dnf install -y git shellcheck nodejs npm golang haproxy; \
			go install mvdan.cc/sh/v3/cmd/shfmt@latest; \
			go install github.com/reteps/dockerfmt@latest; \
			go install sigs.k8s.io/yaml/yamlfmt@latest; \
			go install github.com/rhysd/actionlint/cmd/actionlint@latest; \
			export PATH="$$(go env GOPATH)/bin:$$PATH"; \
			git config --global --add safe.directory "*"; \
			shellcheck --version | sed -n "2p"; \
			npx --yes prettier --version; \
			dockerfmt version; \
			shfmt --version | sed -n "1p"; \
			yamlfmt -h | sed -n "1p"; \
			actionlint --version | sed -n "1p"; \
			haproxy -v | sed -n "1p"; \
			./lint.sh'

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-15s\033[0m %s\n", $$1, $$2}'
