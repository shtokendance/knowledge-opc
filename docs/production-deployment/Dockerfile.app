# Production Dockerfile for knowledge-opc-app
# Artifact / Output: /app/WeKnora (Binary), Container Image: <registry>/knowledge-opc-app:<version>

# ---------------------------------------------------------------------------
# Stage 1: Build stage
# ---------------------------------------------------------------------------
FROM golang:1.26-bookworm AS builder

WORKDIR /app

# Build args
ARG GOPRIVATE_ARG
ARG GOPROXY_ARG=https://goproxy.cn,direct
ARG GOSUMDB_ARG=off
ARG APK_MIRROR_ARG=mirrors.tencent.com
ARG WITH_ANYDOC=1

ENV GOPRIVATE=${GOPRIVATE_ARG}
ENV GOPROXY=${GOPROXY_ARG}
ENV GOSUMDB=${GOSUMDB_ARG}

# Replace mirror if specified and install build prerequisites
RUN if [ -n "$APK_MIRROR_ARG" ]; then \
        sed -i "s@deb.debian.org@${APK_MIRROR_ARG}@g" /etc/apt/sources.list.d/debian.sources; \
    fi && \
    apt-get update && \
    apt-get install -y --no-install-recommends git build-essential libsqlite3-dev curl ca-certificates

# Install database migration tool
RUN go install -tags 'postgres' github.com/golang-migrate/migrate/v4/cmd/migrate@latest

# Copy dependency files
COPY go.mod go.sum ./
COPY third_party/anydoc-go/go.mod third_party/anydoc-go/go.mod
RUN --mount=type=cache,target=/go/pkg/mod go mod download

# Download duckdb dependency
COPY cmd/download cmd/download
RUN go run cmd/download/duckdb/duckdb.go

# Copy full source tree
COPY . .
RUN --mount=type=cache,target=/go/pkg/mod bash ./scripts/copy-licenses.sh /license-bundle

# Injected build variables
ARG VERSION_ARG=v2.0.0
ARG COMMIT_ID_ARG=unknown
ARG BUILD_TIME_ARG=unknown
ARG GO_VERSION_ARG=1.26

ENV VERSION=${VERSION_ARG}
ENV COMMIT_ID=${COMMIT_ID_ARG}
ENV BUILD_TIME=${BUILD_TIME_ARG}
ENV GO_VERSION=${GO_VERSION_ARG}

# Rust toolchain for anydoc (in-process document parser)
ENV RUSTUP_HOME=/usr/local/rustup CARGO_HOME=/usr/local/cargo
ENV PATH=/usr/local/cargo/bin:$PATH
ENV RUSTUP_DIST_SERVER=https://rsproxy.cn
ENV RUSTUP_UPDATE_ROOT=https://rsproxy.cn/rustup

RUN if [ "$WITH_ANYDOC" = "1" ]; then \
        curl --proto '=https' --tlsv1.2 -sSf https://rsproxy.cn/rustup-init.sh | sh -s -- -y --default-toolchain stable --profile minimal && \
        mkdir -p /usr/local/cargo && \
        printf '[source.crates-io]\nreplace-with = "rsproxy-sparse"\n[source.rsproxy-sparse]\nregistry = "sparse+https://rsproxy.cn/index/"\n' > /usr/local/cargo/config.toml && \
        cd third_party/anydoc-go/native && \
        cargo build --release && \
        cp target/release/libanydoc_engine.a /usr/local/lib/ && \
        cd /app; \
    fi

# Build binary
RUN --mount=type=cache,target=/go/pkg/mod \
    CGO_ENABLED=1 \
    CGO_CFLAGS="-I/root/.duckdb" \
    CGO_LDFLAGS="-L/root/.duckdb -lduckdb" \
    go build -tags "${WITH_ANYDOC:+anydoc}" -ldflags=" \
      -X 'main.Version=${VERSION}' \
      -X 'main.CommitID=${COMMIT_ID}' \
      -X 'main.BuildTime=${BUILD_TIME}' \
      -X 'main.GoVersion=${GO_VERSION}'" \
      -o WeKnora cmd/server/main.go

# ---------------------------------------------------------------------------
# Stage 2: Runtime environment
# ---------------------------------------------------------------------------
FROM debian:bookworm-slim

WORKDIR /app

ARG APK_MIRROR_ARG=mirrors.tencent.com

# Create dedicated non-root application user
RUN useradd -m -s /bin/bash appuser

RUN apt-get update && \
    apt-get install -y --no-install-recommends ca-certificates && \
    rm -rf /var/lib/apt/lists/*

RUN if [ -n "$APK_MIRROR_ARG" ]; then \
        sed -i "s@deb.debian.org@${APK_MIRROR_ARG}@g" /etc/apt/sources.list.d/debian.sources; \
    fi && \
    apt-get update && \
    apt-get install -y --no-install-recommends \
        build-essential postgresql-client tzdata sed curl bash vim wget \
        libsqlite3-0 \
        python3 python3-pip python3-dev libffi-dev libssl-dev \
        nodejs npm \
        gosu \
        ffmpeg && \
    python3 -m pip install --break-system-packages --upgrade pip setuptools wheel && \
    mkdir -p /home/appuser/.local/bin && \
    curl -LsSf https://astral.sh/uv/install.sh | CARGO_HOME=/home/appuser/.cargo UV_INSTALL_DIR=/home/appuser/.local/bin sh && \
    chown -R appuser:appuser /home/appuser && \
    ln -sf /home/appuser/.local/bin/uvx /usr/local/bin/uvx && \
    chmod +x /usr/local/bin/uvx && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

# Create working data directories
RUN mkdir -p /data/files && \
    chown -R appuser:appuser /app /data/files

# Copy tools & configurations from builder stage
COPY --from=builder /go/bin/migrate /usr/local/bin/
COPY --from=builder /app/config ./config
COPY --from=builder /app/scripts ./scripts
COPY --from=builder /app/migrations ./migrations
COPY --from=builder /app/dataset/samples ./dataset/samples
COPY --from=builder /root/.duckdb /home/appuser/.duckdb
COPY --from=builder /app/WeKnora .
COPY --from=builder /license-bundle/ ./

COPY --from=builder /app/scripts/docker-entrypoint.sh ./scripts/docker-entrypoint.sh
RUN chmod +x ./scripts/*.sh

EXPOSE 8080

ENTRYPOINT ["./scripts/docker-entrypoint.sh"]
CMD ["./WeKnora"]
