# Multi-stage Docker build for Zepplin
FROM alpine:3.19 AS zig-builder

# Install dependencies
RUN apk add --no-cache \
    curl \
    xz \
    && rm -rf /var/cache/apk/*

# Install Zig
ARG ZIG_VERSION=0.13.0
RUN curl -L "https://ziglang.org/download/${ZIG_VERSION}/zig-linux-x86_64-${ZIG_VERSION}.tar.xz" | tar -xJ -C /opt \
    && ln -s "/opt/zig-linux-x86_64-${ZIG_VERSION}/zig" /usr/local/bin/zig

# Build stage
FROM zig-builder AS builder

WORKDIR /app
COPY . .

# Build the application
RUN zig build -Doptimize=ReleaseFast

# Runtime stage
FROM alpine:3.19

# Install runtime dependencies
RUN apk add --no-cache \
    ca-certificates \
    && rm -rf /var/cache/apk/*

# Create non-root user
RUN addgroup -g 1000 zepplin && \
    adduser -D -s /bin/sh -u 1000 -G zepplin zepplin

# Create data directories
RUN mkdir -p /data/packages /data/index && \
    chown -R zepplin:zepplin /data

# Copy binary
COPY --from=builder /app/zig-out/bin/zepplin /usr/local/bin/zepplin
RUN chmod +x /usr/local/bin/zepplin

# Switch to non-root user
USER zepplin

# Create volume for persistent data
VOLUME ["/data"]

# Expose port
EXPOSE 8080

# Health check
HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
    CMD wget --no-verbose --tries=1 --spider http://localhost:8080/ || exit 1

# Default command
CMD ["zepplin", "serve", "8080"]
