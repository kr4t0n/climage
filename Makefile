# climage — local build/test/publish helpers.
# Configuration comes from .env (see .env.example); every value is overridable
# on the command line, e.g. `make build IMAGE_TAG=test NODE_VERSION=22`.

-include .env

DOCKERHUB_USERNAME ?= $(shell echo $$DOCKERHUB_USERNAME)
IMAGE_NAME         ?= climage
IMAGE_TAG          ?= dev
PLATFORMS          ?= linux/amd64,linux/arm64

# Version pins deliberately have no default here: the Dockerfile's ARG defaults
# are the single source of truth, and a second copy silently drifts out of date.
# Each is forwarded only when deliberately set, so `make build UV_VERSION=0.12.5`
# still works and a bare `make build` matches what CI publishes.
VERSION_ARGS := NODE_VERSION PYTHON_VERSION UV_VERSION RUFF_VERSION \
                GO_VERSION RUST_VERSION

# ...and "deliberately" means the command line or .env (included above, so its
# values have origin `file`) — never the ambient environment. The official node
# base image exports NODE_VERSION, so running make *inside* climage would
# otherwise pin the build to the host container's Node patch release.
# `origin` returns "command line" for an override; firstword avoids quoting it.
build_arg = $(if $(filter file command,$(firstword $(origin $(1)))),--build-arg $(1)=$($(1)))

# Variant selection mirrors the CI matrix, so `make test VARIANT=full` checks
# what CI checks. `base` is the one that publishes as `latest`, which is why it
# carries no build args of its own.
VARIANT ?= base
ifeq ($(filter $(VARIANT),base slim full),)
$(error VARIANT must be one of: base slim full (got '$(VARIANT)'))
endif

VARIANT_ARGS_base :=
VARIANT_ARGS_slim := --build-arg INSTALL_MEDIA=false --build-arg INSTALL_BUILD_TOOLS=false
VARIANT_ARGS_full := --build-arg INSTALL_ARGUS=true --build-arg INSTALL_BROWSER=true \
                     --build-arg INSTALL_GO=true --build-arg INSTALL_RUST=true

# Each variant gets its own local tag, so building one does not silently
# replace another and `make size VARIANT=slim` reports the image you expect.
TAG        := $(IMAGE_TAG)$(if $(filter-out base,$(VARIANT)),-$(VARIANT))
IMAGE      := $(IMAGE_NAME):$(TAG)
REMOTE     := $(DOCKERHUB_USERNAME)/$(IMAGE_NAME):$(TAG)
BUILD_ARGS := $(foreach v,$(VERSION_ARGS),$(call build_arg,$(v))) $(VARIANT_ARGS_$(VARIANT))

.DEFAULT_GOAL := help
.PHONY: help build test test-all run shell lint size push clean

help: ## Show this help
	@grep -hE '^[a-z-]+:.*?## ' $(MAKEFILE_LIST) | awk -F':.*?## ' '{printf "  \033[36m%-8s\033[0m %s\n", $$1, $$2}'

build: ## Build the image for the host architecture and load it locally
	docker build $(BUILD_ARGS) -t $(IMAGE) .

test: build ## Run the smoke test suite inside the freshly built image
	docker run --rm -v "$(CURDIR)/tests:/tests:ro" $(IMAGE) bash /tests/smoke.sh

test-all: ## Build and smoke-test every variant, as the CI matrix does
	@for v in base slim full; do \
		printf '\n==> %s\n' "$$v"; \
		$(MAKE) --no-print-directory test VARIANT=$$v || exit 1; \
	done

run: ## Run a one-off command in the image (make run CMD="rg --version")
	docker run --rm -v "$(CURDIR):/workspace" $(IMAGE) $(or $(CMD),bash -lc 'echo set CMD=...')

shell: ## Open an interactive shell with the current directory mounted
	docker run --rm -it -v "$(CURDIR):/workspace" $(IMAGE)

lint: ## Lint the Dockerfile and shell scripts (requires hadolint + shellcheck)
	hadolint --config .hadolint.yaml Dockerfile
	shellcheck scripts/*.sh tests/*.sh

size: ## Print the size of the built image
	@docker image inspect $(IMAGE) --format '{{.Size}}' | numfmt --to=iec

push: ## Build multi-arch and push to Docker Hub (CI normally does this)
	@test -n "$(DOCKERHUB_USERNAME)" || { echo "DOCKERHUB_USERNAME is unset; see .env.example" >&2; exit 1; }
	docker buildx build $(BUILD_ARGS) --platform $(PLATFORMS) -t $(REMOTE) --push .

clean: ## Remove the locally built image
	-docker image rm $(IMAGE)
