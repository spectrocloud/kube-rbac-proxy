ARG BUILDER_GOLANG_VERSION

FROM --platform=$TARGETPLATFORM us-docker.pkg.dev/palette-images/build-base-images/golang:${BUILDER_GOLANG_VERSION}-alpine as builder
ARG TARGETOS
ARG TARGETARCH
ARG CRYPTO_LIB
ENV GOEXPERIMENT=${CRYPTO_LIB:+boringcrypto}

WORKDIR /workspace
# Copy the Go Modules manifests
COPY go.mod go.mod
COPY go.sum go.sum
# cache deps before building and copying source so that we don't need to re-download as much
# and so that source changes don't invalidate our downloaded layer
RUN go mod download

# Copy the go source
COPY . .

RUN mkdir -p bin

RUN if [ ${CRYPTO_LIB} ]; \
    then \
      go-build-fips.sh -o bin/kube-rbac-proxy cmd/kube-rbac-proxy/main.go ;\
    else \
      go-build-static.sh -o bin/kube-rbac-proxy cmd/kube-rbac-proxy/main.go ;\
    fi

FROM  gcr.io/distroless/static

WORKDIR /bin
COPY --from=builder /workspace/bin/kube-rbac-proxy .

EXPOSE 8080
USER 65532:65532
ENTRYPOINT ["/bin/kube-rbac-proxy"]
