# Multi-stage Docker build for Zepplin Registry
FROM alpine:3.19 AS zig-builder

# Install build dependencies
RUN apk add --no-cache \
    curl \
    xz \
    sqlite-dev \
    build-base \
    git \
    && rm -rf /var/cache/apk/*

# Install Zig (latest dev build)
# You can override this with --build-arg ZIG_VERSION=0.15.0-dev.xyz
ARG ZIG_VERSION=0.15.0-dev.885+e83776595
RUN curl -L "https://ziglang.org/builds/zig-x86_64-linux-${ZIG_VERSION}.tar.xz" | tar -xJ -C /opt \
    && ln -s "/opt/zig-x86_64-linux-${ZIG_VERSION}/zig" /usr/local/bin/zig \
    && zig version

# Build stage
FROM zig-builder AS builder

WORKDIR /app

# Copy build files first for better caching
COPY build.zig build.zig.zon ./

# Copy source code
COPY src/ ./src/

# Build the application with optimizations
RUN zig build -Doptimize=ReleaseFast

# Runtime stage - minimal Alpine with SQLite
FROM alpine:3.19

# Install runtime dependencies including SQLite development libraries
RUN apk add --no-cache \
    sqlite \
    sqlite-dev \
    sqlite-libs \
    ca-certificates \
    tzdata \
    curl \
    wget \
    && rm -rf /var/cache/apk/*

# Create non-root user for security
RUN addgroup -g 1001 zepplin && \
    adduser -D -s /bin/sh -u 1001 -G zepplin zepplin

# Create application directories with proper permissions
RUN mkdir -p /app/data /app/logs && \
    chown -R zepplin:zepplin /app

# Copy the compiled binary
COPY --from=builder /app/zig-out/bin/zepplin /usr/local/bin/zepplin
RUN chmod +x /usr/local/bin/zepplin

# Switch to non-root user
USER zepplin
WORKDIR /app

# Create persistent volume mount point
VOLUME ["/app/data"]

# Expose application port (nginx will proxy to this)
EXPOSE 8080

# Health check for container orchestration
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
    CMD wget --no-verbose --tries=1 --spider http://localhost:8080/health || exit 1

# Set environment variables for production
ENV ZIG_ENV=production
ENV ZEPPLIN_DATA_DIR=/app/data
ENV ZEPPLIN_LOG_LEVEL=info
ENV ZEPPLIN_DOMAIN=zig.cktech.org
ENV ZEPPLIN_REGISTRY_NAME="CKTech Zig Registry"

# Default command - start the registry server
CMD ["zepplin", "serve", "8080"]
