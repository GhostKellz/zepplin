# 🚀 Zeppelin-Zion Integration TODO

## Overview
This document outlines the specific functionality that needs to be implemented in Zeppelin to enable seamless integration with Zion v0.6.0. Based on analysis of Zion's current GitHub API usage and registry requirements.

---

## 🎯 Priority 1: Core API Endpoints (GitHub-Compatible)

### Package Version Management
**Endpoint**: `GET /api/v1/packages/{owner}/{repo}/releases`
```json
// Response format (GitHub-compatible)
[
  {
    "tag_name": "v1.2.3",
    "name": "Release v1.2.3", 
    "published_at": "2024-01-15T10:30:00Z",
    "prerelease": false,
    "tarball_url": "https://zig.cktech.org/api/v1/packages/cktech/zcrypto/download/v1.2.3",
    "zipball_url": "https://zig.cktech.org/api/v1/packages/cktech/zcrypto/download/v1.2.3?format=zip"
  }
]
```

**Endpoint**: `GET /api/v1/packages/{owner}/{repo}/tags`
```json
// Fallback format for packages without formal releases
[
  {
    "name": "v1.2.3",
    "tarball_url": "https://zig.cktech.org/api/v1/packages/cktech/zcrypto/download/v1.2.3"
  }
]
```

### Package Download
**Endpoint**: `GET /api/v1/packages/{owner}/{repo}/download/{version}`
- **Returns**: Direct tarball download (Content-Type: application/gzip)
- **Headers**: 
  - `Content-Disposition: attachment; filename="zcrypto-v1.2.3.tar.gz"`
  - `X-SHA256-Hash: abc123...` (for Zion's integrity verification)

### Package Search
**Endpoint**: `GET /api/v1/search`
**Query Parameters**:
- `q`: Search term
- `language`: Filter by language (should support "zig")
- `sort`: Sort by "stars", "updated", "created"
- `order`: "desc" or "asc"
- `per_page`: Results per page (default: 10)

```json
// Response format
{
  "total_count": 42,
  "items": [
    {
      "name": "zcrypto",
      "full_name": "cktech/zcrypto",
      "description": "Cryptographic library for Zig",
      "stargazers_count": 156,
      "language": "zig",
      "updated_at": "2024-01-15T10:30:00Z",
      "clone_url": "https://zig.cktech.org/cktech/zcrypto.git"
    }
  ]
}
```

---

## 🔧 Priority 2: Authentication & Security

### API Token Support
- **Header**: `Authorization: Bearer <token>` or `Authorization: token <token>`
- **Environment Variable**: `ZEPPELIN_TOKEN` support in Zion
- **Scope-based permissions**: read, write, admin

### Package Signature Support (Ed25519)
```json
// Extended package metadata
{
  "signatures": [
    {
      "keyid": "ed25519_abc123",
      "signature": "base64_encoded_signature"
    }
  ],
  "signed_by": "cktech"
}
```

### Rate Limiting (GitHub-Compatible)
- **Headers**: 
  - `X-RateLimit-Limit: 60`
  - `X-RateLimit-Remaining: 59`
  - `X-RateLimit-Reset: 1640995200`
- **Anonymous**: 60 requests/hour
- **Authenticated**: 5000 requests/hour

---

## 🏗️ Priority 3: Package Management Features

### Package Publishing API
**Endpoint**: `POST /api/v1/packages`
**Content-Type**: `multipart/form-data`
**Fields**:
- `package`: tarball file
- `metadata`: JSON metadata
- `signature`: Optional Ed25519 signature

```json
// Metadata format
{
  "name": "zcrypto",
  "version": "1.2.3",
  "author": "cktech",
  "description": "Cryptographic library for Zig",
  "license": "MIT",
  "zig_version": "0.13.0",
  "dependencies": {
    "zstd": "1.0.0"
  }
}
```

### Package Deletion
**Endpoint**: `DELETE /api/v1/packages/{owner}/{repo}/versions/{version}`
- Requires authentication
- Soft delete with tombstone record
- Maintains integrity of dependent packages

### Package Statistics
**Endpoint**: `GET /api/v1/packages/{owner}/{repo}/stats`
```json
{
  "download_count": 1234,
  "version_count": 8,
  "latest_version": "1.2.3",
  "created_at": "2023-06-01T00:00:00Z",
  "updated_at": "2024-01-15T10:30:00Z"
}
```

---

## 📦 Priority 4: Zion-Specific Integration

### Registry Configuration Endpoint
**Endpoint**: `GET /api/v1/registry/config`
```json
{
  "name": "zig.cktech.org",
  "version": "1.0.0",
  "api_version": "v1",
  "features": [
    "package_search",
    "signature_verification", 
    "bulk_operations",
    "webhooks"
  ],
  "limits": {
    "max_package_size": "50MB",
    "max_packages_per_user": 100
  }
}
```

### Bulk Package Operations
**Endpoint**: `POST /api/v1/packages/bulk`
```json
// Request: Add multiple packages at once
{
  "operation": "add",
  "packages": ["cktech/zcrypto", "cktech/zquic", "cktech/zhttp"]
}
```

### Package Aliases & Short Names
**Configuration**: Server-side mapping for Zion's short name resolution
```toml
# zeppelin.toml registry config
[aliases]
zcrypto = "cktech/zcrypto" 
zquic = "cktech/zquic"
zhttp = "cktech/zhttp"

[organizations]
cktech = ["zcrypto", "zquic", "zhttp", "zjson"]
```

---

## 🔄 Priority 5: Caching & Performance

### HTTP Caching Headers
- **ETag**: For conditional requests
- **Cache-Control**: `public, max-age=3600` for package metadata
- **Last-Modified**: For client-side cache validation

### Package Mirroring Support
**Endpoint**: `POST /api/v1/mirror`
```json
{
  "source_registry": "https://github.com",
  "packages": ["mitchellh/libxev", "karlseguin/http.zig"],
  "sync_schedule": "daily"
}
```

### CDN Integration
- Support for external CDN (CloudFlare, AWS CloudFront)
- Proper cache headers for static assets
- Gzip compression for all text responses

---

## 🌐 Priority 6: Web Interface Enhancements

### Package Browser Integration
- **URL Structure**: `https://zig.cktech.org/packages/{owner}/{repo}`
- **Documentation Hosting**: Serve generated docs from package tarballs
- **README Rendering**: Markdown support with syntax highlighting

### Search Interface
- Real-time search with autocomplete
- Category filtering (crypto, http, json, etc.)
- Popularity sorting by download count

### User Dashboard
- Package management interface
- Publishing history and statistics
- API token management

---

## 🔍 Priority 7: Monitoring & Analytics

### Package Analytics
**Endpoint**: `GET /api/v1/analytics/packages/{owner}/{repo}`
```json
{
  "downloads": {
    "total": 5432,
    "last_30_days": 234,
    "by_version": {
      "1.2.3": 3000,
      "1.2.2": 2000,
      "1.2.1": 432
    }
  },
  "geographical": {
    "US": 2500,
    "EU": 1800,
    "AS": 1132
  }
}
```

### Health Check Endpoints
- `GET /health` - Basic health status
- `GET /metrics` - Prometheus-compatible metrics
- `GET /api/v1/status` - Detailed system status

---

## 🔄 Implementation Phases

### Phase 1: Core API (Week 1-2)
1. GitHub-compatible endpoints (`/releases`, `/tags`, `/download`)
2. Basic search functionality
3. Package metadata storage
4. Tarball download with SHA256 hashes

### Phase 2: Authentication (Week 3)
1. API token system
2. Rate limiting implementation
3. Basic permission system
4. User management

### Phase 3: Publishing (Week 4)
1. Package upload endpoint
2. Version management
3. Signature verification (Ed25519)
4. Package validation

### Phase 4: Integration (Week 5)
1. Zion-specific features (aliases, bulk ops)
2. Configuration endpoints
3. Caching optimizations
4. Documentation generation

### Phase 5: Production Ready (Week 6)
1. Monitoring and analytics
2. Performance optimizations
3. Security hardening
4. Documentation and deployment guides

---

## 🧪 Testing Requirements

### API Compatibility Tests
```bash
# Test Zion integration
zion config set registry https://zig.cktech.org
zion add zcrypto
zion add zquic@1.0.0
zion search crypto
```

### Performance Benchmarks
- Package search: <200ms response time
- Package download: >10MB/s transfer rate
- API requests: <100ms for metadata endpoints
- Concurrent users: Support 100+ simultaneous connections

### Security Testing
- API token validation
- Rate limiting enforcement  
- Package signature verification
- Input sanitization and validation

---

## 📋 Configuration Examples

### Zeppelin Server Config
```toml
# zeppelin.toml
[server]
host = "0.0.0.0"
port = 8080
registry_name = "zig.cktech.org"

[api]
version = "v1"
rate_limit_anonymous = 60
rate_limit_authenticated = 5000

[packages]
max_size = "50MB"
allowed_extensions = [".tar.gz", ".zip"]
require_signatures = false

[aliases]
zcrypto = "cktech/zcrypto"
zquic = "cktech/zquic"
```

### Zion Integration Config
```bash
# Environment variables for Zion
export ZION_REGISTRY_URL=https://zig.cktech.org
export ZION_REGISTRY_TOKEN=your_api_token
export ZION_REGISTRY_PRIORITY=zeppelin,github,zipistry
```

---

## 🎯 Success Criteria

1. **Zion Compatibility**: `zion add zcrypto` works seamlessly
2. **Performance**: Sub-second package resolution and download
3. **Reliability**: 99.9% uptime with proper error handling
4. **Security**: Ed25519 signature verification working
5. **Scalability**: Handle 1000+ packages and 10k+ daily downloads

This roadmap transforms Zeppelin from a prototype into a production-ready registry that seamlessly integrates with Zion, providing the foundation for a thriving Zig package ecosystem.
