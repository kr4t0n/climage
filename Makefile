# climage — local build/test/publish helpers.
# Configuration comes from .env (see .env.example); every value is overridable
# on the command line, e.g. `make build IMAGE_TAG=test NODE_VERSION=20`.

-include .env

DOCKERHUB_USERNAME ?= $(shell echo $$DOCKERHUB_USERNAME)
IMAGE_NAME         ?= climage
IMAGE_TAG          ?= dev
PLATFORMS          ?= linux/amd64,linux/arm64

NODE_VERSION       ?= 22
PYTHON_VERSION     ?= 3.12
UV_VERSION         ?= 0.12.5
RUFF_VERSION       ?= 0.16.4

IMAGE      := $(IMAGE_NAME):$(IMAGE_TAG)
REMOTE     := $(DOCKERHUB_USERNAME)/$(IMAGE_NAME):$(IMAGE_TAG)
BUILD_ARGS := \
	--build-arg NODE_VERSION=$(NODE_VERSION) \
	--build-arg PYTHON_VERSION=$(PYTHON_VERSION) \
	--build-arg UV_VERSION=$(UV_VERSION) \
	--build-arg RUFF_VERSION=$(RUFF_VERSION)

.DEFAULT_GOAL := help
.PHONY: help build test run shell lint size push clean

help: ## Show this help
	@grep -hE '^[a-z-]+:.*?## ' $(MAKEFILE_LIST) | awk -F':.*?## ' '{printf "  \033[36m%-8s\033[0m %s\n", $$1, $$2}'

build: ## Build the image for the host architecture and load it locally
	docker build $(BUILD_ARGS) -t $(IMAGE) .

test: build ## Run the smoke test suite inside the freshly built image
	docker run --rm -v "$(CURDIR)/tests:/tests:ro" $(IMAGE) bash /tests/smoke.sh

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
