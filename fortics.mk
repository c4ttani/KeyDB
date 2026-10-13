# Fortics local builds. Usage: make -f fortics.mk <target>   (make -f fortics.mk help)
# Kept apart from the top-level Makefile, which only forwards to src/ (upstream).

VERSION      := $(shell grep -oP 'KEYDB_REAL_VERSION "\K[^"]+' src/version.h)
GIT_SHA      := $(shell git rev-parse --short=8 HEAD 2>/dev/null || echo 00000000)
GAR_LOCATION ?= us-central1
GCP_PROJECT  ?= gcp-fortics-360context
GAR_REPO     ?= context360
IMAGE        ?= $(GAR_LOCATION)-docker.pkg.dev/$(GCP_PROJECT)/$(GAR_REPO)/keydb
LOCAL_IMAGE  ?= keydb-fortics:local
JOBS         ?= $(shell nproc)
TEST_UNITS   ?= unit/type/list unit/type/zset unit/type/stream unit/scripting unit/networking unit/moduleapi/blockedclient
PORT         ?= 6379

# Native build flags. NO_MOTD=yes avoids needing libcurl headers on dev machines.
BUILD_FLAGS  ?= BUILD_TLS=yes NO_MOTD=yes

.PHONY: help build test clean image run repro push

help: ## List targets
	@grep -E '^[a-z-]+:.*## ' $(MAKEFILE_LIST) | awk -F':.*## ' '{printf "  %-8s %s\n", $$1, $$2}'
	@echo "  version $(VERSION), commit $(GIT_SHA), image $(IMAGE)"

build: ## Compile keydb-server/keydb-cli natively into src/
	$(MAKE) -j$(JOBS) $(BUILD_FLAGS)

test: build ## Run the same test suites as the CI pipeline
	$(MAKE) -C tests/modules -j$(JOBS)
	@set -e; for t in $(TEST_UNITS); do ./runtest --single $$t --clients 4; done

clean: ## Remove native build output (including deps)
	$(MAKE) distclean

image: ## Build the Docker image locally as $(LOCAL_IMAGE)
	docker build -f pkg/docker/Dockerfile.fortics \
		--build-arg GIT_SHA=$(GIT_SHA) \
		--label org.opencontainers.image.revision=$(GIT_SHA) \
		-t $(LOCAL_IMAGE) .

run: image ## Run the image like the Nomad job (ACL user app/dev, AOF) on PORT
	docker run --rm -it -p $(PORT):6379 -e KEYDB_USERNAME=app -e KEYDB_PASSWORD=dev $(LOCAL_IMAGE) \
		sh -ec 'exec keydb-server --appendonly yes --user default off --user "$$KEYDB_USERNAME" on ">$$KEYDB_PASSWORD" ~* "&*" +@all'

repro: image ## Reproduce Snapchat/KeyDB#928 against the image (expects 0 orphans)
	@docker rm -f keydb-repro >/dev/null 2>&1 || true
	@docker run -d --name keydb-repro $(LOCAL_IMAGE) keydb-server --save "" >/dev/null; sleep 2
	@for i in $$(seq 1 30); do (docker exec keydb-repro timeout 2 keydb-cli blpop q 3000 >/dev/null &); done; sleep 1
	@for i in $$(seq 1 30); do docker exec keydb-repro keydb-cli rpush q x >/dev/null; done; sleep 3
	@n=$$(docker exec keydb-repro keydb-cli info clients | grep -oP 'clients_in_timeout_table:\K\d+'); \
		docker rm -f keydb-repro >/dev/null; \
		echo "clients_in_timeout_table=$$n"; [ "$$n" = 0 ]

push: image ## Manual push of $(GIT_SHA) to Artifact Registry (releases go through CI tags)
	gcloud auth configure-docker $(GAR_LOCATION)-docker.pkg.dev --quiet
	docker tag $(LOCAL_IMAGE) $(IMAGE):$(GIT_SHA)
	docker push $(IMAGE):$(GIT_SHA)
