# syntax=docker/dockerfile:1
# Build stage runs on the builder's own architecture and cross-compiles,
# so multi-arch images build fast without QEMU.
FROM --platform=$BUILDPLATFORM golang:1.27-alpine AS build
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY *.go ./
ARG TARGETOS TARGETARCH
RUN CGO_ENABLED=0 GOOS=$TARGETOS GOARCH=$TARGETARCH \
    go build -trimpath -ldflags="-s -w" -o /out/quote-api .

# distroless/static: no shell, no package manager, numeric non-root user.
FROM gcr.io/distroless/static-debian13:nonroot
COPY --from=build /out/quote-api /quote-api
USER 65532:65532
EXPOSE 8080
ENTRYPOINT ["/quote-api"]
