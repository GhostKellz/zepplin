# Multi-stage Docker build for Zepplin Registry

# Frontend stage - build the Astro static site with Bun
FROM oven/bun:1 AS frontend-builder
WORKDIR /fe

# Install dependencies first for better caching
COPY frontend/package.json frontend/bun.lock ./
RUN bun install --frozen-lockfile

# Build the static site (astro.config outDir '../dist' → /dist)
COPY frontend/ ./
RUN bun run build

FROM alpine:3.19 AS zig-builder

# Install build dependencies
RUN apk add --no-cache \
  curl \
  xz \
  sqlite-dev \
  build-base \
  git \
  jq \
  && rm -rf /var/cache/apk/*

# Install Zig master build (dynamically fetches latest from index.json)
RUN ZIG_URL=$(curl -sL https://ziglang.org/download/index.json | jq -r '.master."x86_64-linux".tarball') \
  && echo "Downloading Zig from: $ZIG_URL" \
  && curl -L "$ZIG_URL" -o /tmp/zig.tar.xz \
  && tar -xJf /tmp/zig.tar.xz -C /opt \
  && ln -s /opt/zig-x86_64-linux-*/zig /usr/local/bin/zig \
  && rm /tmp/zig.tar.xz \
  && zig version

# Build stage
FROM zig-builder AS builder

WORKDIR /app

# Copy build files first for better caching
COPY build.zig build.zig.zon ./

# Copy source code (build.zig only needs src/)
COPY src/ ./src/

# Build the application with optimizations
RUN zig build -Doptimize=ReleaseFast

# Runtime stage - Debian for glibc compatibility with Zig 0.16 std.Io
FROM debian:bookworm-slim

# Install runtime dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
  libsqlite3-0 \
  ca-certificates \
  curl \
  wget \
  && rm -rf /var/lib/apt/lists/*

# Create non-root user for security
RUN groupadd -g 1001 zepplin && \
  useradd -m -s /bin/bash -u 1001 -g zepplin zepplin

# Create application directories with proper permissions
RUN mkdir -p /app/data /app/logs && \
  chown -R zepplin:zepplin /app

# Copy the compiled binary
COPY --from=builder /app/zig-out/bin/zepplin /usr/local/bin/zepplin
RUN chmod +x /usr/local/bin/zepplin

# Copy the built static frontend and independent assets
COPY --from=frontend-builder /dist /app/dist
COPY assets/ /app/assets/

# Switch to non-root user
USER zepplin
WORKDIR /app

# Create persistent volume mount point
VOLUME ["/app/data"]

# Expose application port (nginx will proxy to this)
EXPOSE 8888

# Health check for container orchestration
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
  CMD wget --no-verbose --tries=1 --spider http://localhost:8888/health || exit 1

# Set environment variables for production
ENV ZIG_ENV=production
ENV ZEPPLIN_DATA_DIR=/app/data
ENV ZEPPLIN_LOG_LEVEL=info
ENV ZEPPLIN_DOMAIN=zig.cktech.org
ENV ZEPPLIN_REGISTRY_NAME="CKTech Zig Registry"

# Default command - start the registry server with explicit data directory
CMD ["zepplin", "serve", "8888", "/app/data"]
