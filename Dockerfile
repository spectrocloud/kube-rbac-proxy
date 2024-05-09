ARG GOARCH=amd64
ARG GOOS=linux
FROM --platform=linux/amd64 gcr.io/spectro-images-public/golang:1.22-alpine as builder
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

ENV GOPRIVATE="github.com/spectrocloud"
ENV CGO_ENABLED=0
RUN if [ ${CRYPTO_LIB} ]; \
    then \
      go-build-fips.sh -o /usr/local/bin/kube-rbac-proxy cmd/kube-rbac-proxy/main.go ;\
    else \
      go-build-static.sh -o /usr/local/bin/kube-rbac-proxy cmd/kube-rbac-proxy/main.go ;\
    fi

FROM  gcr.io/distroless/static
WORKDIR /

ARG BINARY=kube-rbac-proxy-$GOOS-$GOARCH
COPY cmd/kube-rbac-proxy/_output/$BINARY /usr/local/bin/kube-rbac-proxy

EXPOSE 8080
USER 65532:65532
ENTRYPOINT ["/usr/local/bin/kube-rbac-proxy"]
