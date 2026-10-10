# syntax=docker/dockerfile:1
FROM --platform=$BUILDPLATFORM golang:1.27-alpine AS build
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY *.go ./
ARG TARGETOS TARGETARCH
RUN CGO_ENABLED=0 GOOS=$TARGETOS GOARCH=$TARGETARCH \
    go build -trimpath -ldflags="-s -w" -o /out/quote-api .

FROM gcr.io/distroless/static-debian13:nonroot
COPY --from=build /out/quote-api /quote-api
USER 65532:65532
EXPOSE 8080
ENTRYPOINT ["/quote-api"]
