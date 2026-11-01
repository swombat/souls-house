# Build context: services/comms-connector (as for services/mnemodyne-embeddings).
#   docker build -t <registry>/souls-house-comms-whatsapp services/comms-connector
# Pin both base images by digest before publishing (see README.md "Deploying").
FROM golang:1.27.2-trixie@sha256:47667934874913a449b96faa7ef4777fa285d9ec29126ee80ed61c45b7cccf0e AS build
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
FROM gcr.io/distroless/base-debian13:nonroot@sha256:f9518b74815721f537a7458cc693b4406208c04fce23bbffab511516117f34fd
COPY --from=build /out/comms-connector /comms-connector
COPY --from=build --chown=65532:65532 /out/data /data
ENV GOTRACEBACK=none COMMS_DATA_DIR=/data
USER 65532:65532
VOLUME ["/data"]
EXPOSE 8443
ENTRYPOINT ["/comms-connector"]
