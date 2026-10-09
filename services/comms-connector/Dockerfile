# Build context: services/comms-connector (as for services/mnemodyne-embeddings).
# Not built or deployed in slice 1. Pin both base images by digest before use.
FROM golang:1.27.2-bookworm AS build
WORKDIR /src
ENV CGO_ENABLED=1 \
    CGO_CFLAGS="-O2 -DSQLITE_TEMP_STORE=3" \
    GOFLAGS=-mod=readonly \
    GOTRACEBACK=none
COPY go.mod go.sum ./
RUN go mod download && go mod verify
COPY . .
RUN go vet ./... && go test -count=1 ./... \
 && go build -trimpath -ldflags="-s -w" -o /out/comms-connector ./cmd/comms-connector \
 && mkdir -p /out/data

# glibc runtime for the cgo binary; nonroot (65532), no shell.
FROM gcr.io/distroless/base-debian12:nonroot
COPY --from=build /out/comms-connector /comms-connector
COPY --from=build --chown=65532:65532 /out/data /data
ENV GOTRACEBACK=none COMMS_DATA_DIR=/data
USER 65532:65532
VOLUME ["/data"]
EXPOSE 8080
ENTRYPOINT ["/comms-connector"]
