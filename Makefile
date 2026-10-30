IMAGE              ?= zek
# Pin the latest versions explicitly; bump these to move to a newer release.
ALPINE_VERSION     ?= 3.24.3
KUBERNETES_VERSION ?= v1.37.2

# Version aliases: hold alpine at major, minor or full while tracking either
# the kubernetes minor or full version. For the current pins that is 3-1.37,
# 3-1.37.1, 3.24-1.37, 3.24-1.37.1 and 3.24.3-1.37. The `v` prefix is dropped
# from kubernetes versions and `-` joins the two because Docker tags cannot
# contain `/`.
version_major = $(word 1,$(subst ., ,$(1)))
version_minor = $(call version_major,$(1)).$(word 2,$(subst ., ,$(1)))

ALPINE_MAJOR            := $(call version_major,$(ALPINE_VERSION))
ALPINE_MINOR            := $(call version_minor,$(ALPINE_VERSION))
KUBERNETES_VERSION_NO_V := $(patsubst v%,%,$(KUBERNETES_VERSION))
KUBERNETES_MINOR        := $(call version_minor,$(KUBERNETES_VERSION_NO_V))
VERSION_ALIAS_TAGS      := $(ALPINE_MAJOR)-$(KUBERNETES_MINOR) \
	$(ALPINE_MAJOR)-$(KUBERNETES_VERSION_NO_V) \
	$(ALPINE_MINOR)-$(KUBERNETES_MINOR) \
	$(ALPINE_MINOR)-$(KUBERNETES_VERSION_NO_V) \
	$(ALPINE_VERSION)-$(KUBERNETES_MINOR)

DOCKER ?= docker

# Per-build id comes from git: the short commit SHA, suffixed with "-dirty"
# when the working tree has uncommitted changes. No stored state, so the id is
# the same on every machine with the same commit. Override BUILD_ID to tag a
# build differently. Builds of the same commit reuse the same tag.
BUILD_ID   ?= $(shell git describe --always --dirty 2>/dev/null || echo unknown)
TAG        := $(ALPINE_VERSION)-$(KUBERNETES_VERSION)-$(BUILD_ID)
# Stable name for the newest build of this alpine/k8s combination, so
# scripts can pin the combo without tracking the git-based BUILD_ID.
COMBO_TAG  := $(ALPINE_VERSION)-$(KUBERNETES_VERSION)-latest
# Every derived tag except `latest`: the pinned combo plus the version aliases.
ALIAS_TAGS := $(COMBO_TAG) $(VERSION_ALIAS_TAGS)

# Shared build+tag recipe; $(1) is extra docker build flags (build-nocache
# passes --no-cache to force the image preload step to re-run). BuildKit adds
# a provenance attestation by default; `docker push` uploads it as an extra
# unknown/unknown manifest, which GHCR lists as an untagged sha256 version.
# Nothing here consumes it, so opt out.

.PHONY: build build-nocache push format lint help

define build_image
	$(DOCKER) build $(1) --provenance=false -t $(IMAGE):$(TAG) \
	--build-arg ALPINE_VERSION=$(ALPINE_VERSION) \
	--build-arg KUBERNETES_VERSION=$(KUBERNETES_VERSION) .
	$(DOCKER) tag $(IMAGE):$(TAG) $(IMAGE):latest
	@for tag in $(ALIAS_TAGS); do \
		$(DOCKER) tag $(IMAGE):$(TAG) "$(IMAGE):$$tag" || exit 1; \
	done
endef

build: ## Build and tag $(IMAGE):$(TAG), aliases and :latest
	$(call build_image)

build-nocache: ## Build, forcing the image preload step to re-run
	$(call build_image,--no-cache)

# Push the exact tags `build` creates. Explicit tags instead of
# `docker push --all-tags`: a persistent daemon may hold stale tags for the
# same repository, and those must not be published.
push: ## Push $(IMAGE):$(TAG), aliases and :latest
	$(DOCKER) push $(IMAGE):$(TAG)
	$(DOCKER) push $(IMAGE):latest
	@for tag in $(ALIAS_TAGS); do \
		$(DOCKER) push "$(IMAGE):$$tag" || exit 1; \
	done

# The fedora:latest container both lint and format run in: the same image,
# packages and tool versions CI uses (keep in sync with
# .github/workflows/lint.yml), so neither target needs local tool installs.
# $(1) is the bash command run inside /repo after the setup.
define fedora_bash
	$(DOCKER) run --rm \
	-v "$(CURDIR):/repo:z" -w /repo \
	fedora:latest bash -c ' \
	set -euo pipefail; \
	dnf install -y git shellcheck nodejs npm golang haproxy make python3-pip; \
	go install mvdan.cc/sh/v3/cmd/shfmt@latest; \
	go install github.com/reteps/dockerfmt@latest; \
	go install sigs.k8s.io/yaml/yamlfmt@latest; \
	go install github.com/rhysd/actionlint/cmd/actionlint@latest; \
	python3 -m pip install --root-user-action=ignore mbake; \
	export PATH="$$(go env GOPATH)/bin:$$PATH"; \
	git config --global --add safe.directory "*"; \
	$(1)'
endef

format: ## Reformat *.sh, *.md, *.yml/*.yaml, Dockerfiles and the Makefile in place (heredoc bodies excluded)
	$(call fedora_bash,./format.sh)

lint: ## Run ./lint.sh in a fedora:latest container, exactly like CI
	$(call fedora_bash, \
	shellcheck --version | sed -n "2p"; \
	npx --yes prettier --version; \
	dockerfmt version; \
	shfmt --version | sed -n "1p"; \
	go version -m "$$(command -v yamlfmt)" | awk "\$$1 == \"mod\" { print \"yamlfmt (\" \$$2 \") \" \$$3 }"; \
	mbake --version; \
	actionlint --version | sed -n "1p"; \
	haproxy -v | sed -n "1p"; \
	./lint.sh)

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-15s\033[0m %s\n", $$1, $$2}'
