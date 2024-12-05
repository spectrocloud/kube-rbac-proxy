all: check-license build generate test

GO111MODULE=on
export GO111MODULE

GITHUB_URL=github.com/brancz/kube-rbac-proxy
GOOS?=$(shell uname -s | tr A-Z a-z)
GOARCH?=$(shell go env GOARCH)
OUT_DIR=cmd/kube-rbac-proxy/_output
BIN?=kube-rbac-proxy
VERSION?=$(shell cat VERSION)-$(shell git rev-parse --short HEAD)
PKGS=$(shell go list ./... | grep -v /test/e2e)
DOCKER_REPO?=quay.io/brancz/kube-rbac-proxy
KUBECONFIG?=$(HOME)/.kube/config
CONTAINER_NAME?=$(DOCKER_REPO):$(VERSION)

# Fips Flags
FIPS_ENABLE ?= ""
BUILDER_GOLANG_VERSION ?= 1.23
BUILD_ARGS = --build-arg CRYPTO_LIB=${FIPS_ENABLE} --build-arg BUILDER_GOLANG_VERSION=${BUILDER_GOLANG_VERSION}

IMG_PATH ?= "gcr.io/spectro-dev-public"
IMG_TAG ?= "latest"
IMG_SERVICE_URL ?= ${IMG_PATH}

RELEASE_LOC := release
ifeq ($(FIPS_ENABLE),yes)
  RELEASE_LOC := release-fips
  CGO_FLAG=1
  LDFLAGS=-ldflags "-linkmode=external  -extldflags -static"
endif

CGO_FLAG ?= 0
LDFLAGS ?= ""
SPECTRO_VERSION ?= 4.0.0-dev
TAG ?= v0.14.0-spectro-${SPECTRO_VERSION}

KRP_IMG ?= ${IMG_SERVICE_URL}/${RELEASE_LOC}/kube-rbac-proxy:${IMG_TAG}
# ALL_ARCH = amd64 arm arm64 ppc64le s390x

REGISTRY ?= gcr.io/spectro-dev-public/${RELEASE_LOC}
CORE_IMAGE_NAME ?= kube-rbac-proxy
IMG ?= $(REGISTRY)/$(CORE_IMAGE_NAME)

ARCH ?= amd64
ALL_ARCH=amd64 arm64
ALL_PLATFORMS=$(addprefix linux/,$(ALL_ARCH))
ALL_BINARIES ?= $(addprefix $(OUT_DIR)/$(BIN)-, \
				$(addprefix linux-,$(ALL_ARCH)) \
				darwin-amd64 \
				windows-amd64.exe)

TOOLS_BIN_DIR?=$(shell pwd)/tmp/bin
export PATH := $(TOOLS_BIN_DIR):$(PATH)

EMBEDMD_BINARY=$(TOOLS_BIN_DIR)/embedmd
TOOLING=$(EMBEDMD_BINARY)

#### BUILD BINARIES
binary-arm64: ## Run this command from inside cmd/kube-rbac-proxy
	cd cmd/kube-rbac-proxy && GOOS=linux GOARCH=arm64 go build --installsuffix cgo -o  _output/kube-rbac-proxy-linux-arm64
	cd ../..

binary-amd64: ## Run this command from inside cmd/kube-rbac-proxy
	cd cmd/kube-rbac-proxy && GOOS=linux GOARCH=amd64 go build --installsuffix cgo -o  _output/kube-rbac-proxy-linux-amd64
	cd ../..

#### DOCKER BUILD
.PHONY: docker-build
docker-build:  $(OUT_DIR)/$(BIN)-linux-$(ARCH) Dockerfile## Build the docker image for controller-manager
	docker buildx build --load --platform linux/${ARCH} ${BUILD_ARGS} --build-arg BINARY=$(BIN)-linux-$(ARCH) --build-arg ARCH=$(ARCH) . -t $(IMG)-$(ARCH):$(TAG)
	@echo $(IMG)-$(ARCH):$(TAG)

.PHONY: docker-build-all ## Build all the architecture docker images
docker-build-all: $(addprefix docker-build-,$(ALL_ARCH))

docker-build-%: ## Build docker images for a given ARCH
	$(MAKE) ARCH=$* docker-build

#### DOCKER PUSH
.PHONY: docker-push
docker-push: ## Push the docker image
	docker push $(IMG)-$(ARCH):$(TAG)

.PHONY: docker-push-all ## Push all the architecture docker images
docker-push-all: $(addprefix docker-push-,$(ALL_ARCH))
	$(MAKE) docker-push-core-manifest

docker-push-%: ## Docker push
	$(MAKE) ARCH=$* docker-push

.PHONY: docker-push-core-manifest
docker-push-core-manifest: ## Push the fat manifest docker image.
	## Minimum docker version 18.06.0 is required for creating and pushing manifest images.
	$(MAKE) docker-push-manifest IMAGE=$(IMG) MANIFEST_FILE=$(CORE_MANIFEST_FILE)

.PHONY: docker-push-manifest
docker-push-manifest: ## Push the manifest image
	docker manifest create --amend $(IMAGE):$(TAG) $(shell echo $(ALL_ARCH) | sed -e "s~[^ ]*~$(IMAGE)\-&:$(TAG)~g")
	@for arch in $(ALL_ARCH); do docker manifest annotate --arch $${arch} ${IMAGE}:${TAG} ${IMAGE}-$${arch}:${TAG}; done
	docker manifest push --purge ${IMAGE}:${TAG}

.PHONY: docker
docker:
	docker buildx build --platform linux/amd64,linux/arm64 --push . -t ${KRP_IMG} ${BUILD_ARGS} -f Dockerfile

check-license:
	@echo ">> checking license headers"
	@./scripts/check_license.sh

crossbuild: $(ALL_BINARIES)

$(OUT_DIR)/$(BIN): $(OUT_DIR)/$(BIN)-$(GOOS)-$(GOARCH)
	cp $(OUT_DIR)/$(BIN)-$(GOOS)-$(GOARCH) $(OUT_DIR)/$(BIN)

$(OUT_DIR)/$(BIN)-%:
	@echo ">> building for $(GOOS)/$(GOARCH) to $(OUT_DIR)/$(BIN)-$*"
	GOARCH=$(word 2,$(subst -, ,$(*:.exe=))) \
	GOOS=$(word 1,$(subst -, ,$(*:.exe=))) \
	CGO_ENABLED=$(CGO_FLAG) go build --installsuffix cgo -o  $(OUT_DIR)/$(BIN)-$* $(LDFLAGS) $(GITHUB_URL)/cmd/kube-rbac-proxy

clean:
	-rm -r $(OUT_DIR)

build: clean $(OUT_DIR)/$(BIN)

update-go-deps:
	@for m in $$(go list -mod=readonly -m -f '{{ if and (not .Indirect) (not .Main)}}{{.Path}}{{end}}' all); do \
		go get -d $$m; \
	done
	go mod tidy

container: $(OUT_DIR)/$(BIN)-$(GOOS)-$(GOARCH) Dockerfile
	docker build --build-arg CRYPTO_LIB=${FIPS_ENABLE} --build-arg BINARY=$(BIN)-$(GOOS)-$(GOARCH) --build-arg GOARCH=$(GOARCH) -t $(CONTAINER_NAME)-$(GOARCH) .
ifeq ($(GOARCH), amd64)
	docker tag $(DOCKER_REPO):$(VERSION)-$(GOARCH) $(CONTAINER_NAME)
endif

manifest-tool:
	curl -fsSL https://github.com/estesp/manifest-tool/releases/download/v1.0.2/manifest-tool-linux-amd64 > ./manifest-tool
	chmod +x ./manifest-tool

push-%:
	$(MAKE) GOARCH=$* container
	docker push $(DOCKER_REPO):$(VERSION)-$*

comma:= ,
empty:=
space:= $(empty) $(empty)
manifest-push: manifest-tool
	./manifest-tool push from-args --platforms $(subst $(space),$(comma),$(ALL_PLATFORMS)) --template $(DOCKER_REPO):$(VERSION)-ARCH --target $(DOCKER_REPO):$(VERSION)

push: crossbuild manifest-tool $(addprefix push-,$(ALL_ARCH)) manifest-push

curl-container:
	docker build -f ./examples/example-client/Dockerfile -t quay.io/brancz/krp-curl:v0.0.2 .

run-curl-container:
	@echo 'Example: curl -v -s -k -H "Authorization: Bearer `cat /var/run/secrets/kubernetes.io/serviceaccount/token`" https://kube-rbac-proxy.default.svc:8443/metrics'
	kubectl run -i -t krp-curl --image=quay.io/brancz/krp-curl:v0.0.2 --restart=Never --command -- /bin/sh

grpcc-container:
	docker build -f ./examples/grpcc/Dockerfile -t mumoshu/grpcc:v0.0.1 .

test: test-unit test-e2e

test-unit:
	go test -v -race -count=1 $(PKGS)

test-e2e:
	go test -timeout 55m -v ./test/e2e/ $(TEST_RUN_ARGS) --kubeconfig=$(KUBECONFIG)

test-local-setup: clean $(OUT_DIR)/$(BIN)-$(GOOS)-$(GOARCH) Dockerfile
	docker build --build-arg BINARY=$(BIN)-$(GOOS)-$(GOARCH) \
	  --build-arg GOOS=$(GOOS) --build-arg GOARCH=$(GOARCH) \
	  -t $(CONTAINER_NAME)-$(GOARCH) .
	docker tag $(DOCKER_REPO):$(VERSION)-$(GOARCH) $(DOCKER_REPO):local

test-local: test-local-setup kind-create-cluster test

kind-delete-cluster:
	kind delete cluster

kind-create-cluster: kind-delete-cluster
	kind create cluster --config ./test/e2e/kind-config/kind-config.yaml
	kind load docker-image $(DOCKER_REPO):local

generate: build $(EMBEDMD_BINARY)
	@echo ">> generating examples"
	@./scripts/generate-examples.sh
	@echo ">> generating docs"
	@./scripts/generate-help-txt.sh
	@$(EMBEDMD_BINARY) -w `find ./ -name "*.md" -print`

$(TOOLS_BIN_DIR):
	@mkdir -p $(TOOLS_BIN_DIR)

$(TOOLING): $(TOOLS_BIN_DIR)
	@echo Installing tools from scripts/tools.go
	@cat scripts/tools.go | grep _ | awk -F'"' '{print $$2}' | GOBIN=$(TOOLS_BIN_DIR) xargs -tI % go install -mod=readonly -modfile=scripts/go.mod %

.PHONY: all check-license crossbuild build container push push-% manifest-push curl-container test test-unit test-e2e generate update-go-deps clean kind-delete-cluster kind-create-cluster
