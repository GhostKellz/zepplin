# 🚀 Zepplin Commands Reference

Complete command reference for the Zepplin Zig Package Manager with ZQLITE persistent storage.

---

## 📦 **Package Management Commands**

### `zepplin init`
Initialize a new Zig project with Zepplin package management.

```bash
zepplin init
```

**What it does:**
- Creates `build.zig.zon` with package metadata
- Sets up basic project structure
- Initializes local package registry cache

**Example output:**
```
✅ Initialized new Zig project
📁 Created build.zig.zon
🗄️ Initialized package cache
```

---

### `zepplin add <package>`
Add a dependency to your project.

```bash
# Add latest version
zepplin add xev

# Add specific version
zepplin add xev@1.2.0

# Add from specific registry
zepplin add xev --registry https://packages.ziglang.org
```

**What it does:**
- Downloads package metadata from registry
- Updates `build.zig.zon` dependencies
- Resolves version conflicts
- Stores package in local cache (ZQLITE database)

**Example output:**
```
🔍 Resolving xev...
⬇️  Downloading xev@0.2.0
✅ Added xev@0.2.0 to dependencies
📝 Updated build.zig.zon
```

---

### `zepplin update`
Update all dependencies to their latest compatible versions.

```bash
zepplin update

# Update specific package
zepplin update xev

# Check for updates without applying
zepplin update --dry-run
```

**What it does:**
- Checks registry for newer versions
- Resolves dependency conflicts
- Updates package cache
- Regenerates lock file

---

### `zepplin build`
Build the project with all dependencies resolved.

```bash
zepplin build

# Build specific target
zepplin build --target x86_64-linux

# Build with optimization
zepplin build --release-fast
```

**What it does:**
- Ensures all dependencies are available
- Invokes `zig build` with proper module paths
- Caches build artifacts

---

## 🌐 **Registry & Publishing Commands**

### `zepplin publish`
Publish your package to the registry.

```bash
zepplin publish

# Publish to specific registry
zepplin publish --registry https://my-registry.com

# Dry run (validate without publishing)
zepplin publish --dry-run
```

**Requirements:**
- Must be authenticated (`zepplin login`)
- Valid `build.zig.zon` with package metadata
- Git repository with proper tags

**What it does:**
- Validates package metadata
- Creates package archive
- Uploads to registry
- Updates package index

---

### `zepplin login [registry]`
Authenticate with a package registry.

```bash
# Login to default registry
zepplin login

# Login to specific registry
zepplin login https://packages.ziglang.org

# Login with API token
zepplin login --token YOUR_API_TOKEN
```

**What it does:**
- Prompts for credentials or API token
- Stores authentication in secure storage
- Validates registry connection

---

## 🖥️ **Server Commands**

### `zepplin serve <port>`
Start the local package registry server.

```bash
# Start on default port 8080
zepplin serve 8080

# Start on custom port
zepplin serve 3000

# Start with custom data directory
zepplin serve 8080 --data-dir ./registry-data
```

**What it does:**
- Starts HTTP server with REST API
- Serves web UI for package browsing
- Uses ZQLITE database for persistent storage
- Provides package upload/download endpoints

**API Endpoints:**
- `GET /api/packages` - List all packages
- `GET /api/packages/{name}` - Get package details
- `POST /api/packages` - Upload new package
- `GET /api/stats` - Registry statistics
- `GET /` - Web UI

**Example output:**
```
🚀 Zepplin Registry Server starting on http://localhost:8080
📦 Ready to serve packages!
🗄️ Using ZQLITE database: ./data/registry.db
```

---

## 🔧 **Utility Commands**

### `zepplin help`
Show command help and usage information.

```bash
zepplin help

# Get help for specific command
zepplin help add
zepplin help publish
```

---

## 📊 **Database & Cache Commands**

### `zepplin cache`
Manage local package cache.

```bash
# Show cache statistics
zepplin cache stats

# Clear cache
zepplin cache clear

# Verify cache integrity
zepplin cache verify

# Show cache location
zepplin cache info
```

**What it does:**
- Manages ZQLITE database cache
- Shows storage usage and statistics
- Verifies package integrity
- Cleans up orphaned packages

---

## 🔍 **Search & Discovery Commands**

### `zepplin search <query>`
Search for packages in the registry.

```bash
# Search by name
zepplin search http

# Search with filters
zepplin search "web framework" --author ziglang

# Search specific registry
zepplin search json --registry https://packages.ziglang.org
```

**What it does:**
- Queries package registry
- Searches names, descriptions, and authors
- Shows package metadata and versions
- Supports filtering and sorting

---

## 🐳 **Docker Commands**

### Docker Compose
Run the complete Zepplin stack with Docker.

```bash
# Start registry server with database
docker-compose up

# Start in background
docker-compose up -d

# View logs
docker-compose logs -f

# Stop services
docker-compose down
```

**Services:**
- `zepplin` - Main registry server (port 8080)
- `nginx` - Reverse proxy (port 80)
- Persistent ZQLITE database storage

---

## 📁 **File Structure**

```
your-project/
├── build.zig              # Zig build script
├── build.zig.zon          # Package metadata & dependencies
├── src/                   # Source code
├── .zepplin/              # Zepplin configuration
│   ├── cache/             # Package cache (ZQLITE database)
│   └── config.toml        # Local configuration
└── zig-out/               # Build artifacts
```

---

## 🌟 **Advanced Usage Examples**

### Setting up a Private Registry
```bash
# Start private registry
zepplin serve 8080 --data-dir ./private-registry

# Configure client to use private registry
echo 'default_registry = "http://localhost:8080"' > .zepplin/config.toml

# Publish to private registry
zepplin publish --registry http://localhost:8080
```

### Monorepo Package Management
```bash
# Initialize workspace
zepplin init --workspace

# Add local dependencies
zepplin add ./packages/common --local
zepplin add ./packages/web --local

# Build entire workspace
zepplin build --workspace
```

### CI/CD Integration
```bash
# In your CI pipeline
zepplin login --token $ZEPPLIN_TOKEN
zepplin build --release-fast
zepplin publish --dry-run  # Validate before publishing
zepplin publish            # Publish if validation passes
```

---

## 🚨 **Troubleshooting**

### Common Issues

**Database corruption:**
```bash
zepplin cache verify
zepplin cache clear
```

**Authentication problems:**
```bash
zepplin login --force  # Force re-authentication
```

**Build failures:**
```bash
zepplin update --force  # Force dependency update
zig build clean         # Clean build cache
```

**Registry connection issues:**
```bash
# Check registry status
curl http://localhost:8080/api/stats

# Use different registry
zepplin add package --registry https://backup-registry.com
```

---

## 🔧 **Configuration**

### Global Configuration (`~/.zepplin/config.toml`)
```toml
default_registry = "https://packages.ziglang.org"
cache_dir = "~/.zepplin/cache"
max_cache_size = "5GB"
auth_token_file = "~/.zepplin/auth"

[registries]
main = "https://packages.ziglang.org"
private = "http://localhost:8080"
backup = "https://backup-registry.com"
```

### Project Configuration (`.zepplin/config.toml`)
```toml
registry = "private"
build_cache = true
auto_update = false

[dependencies]
prefer_local = true
version_strategy = "conservative"
```

---

## 📈 **Performance Notes**

With ZQLITE v0.4.0 integration:
- **90% faster** package searches (B-tree indexing)
- **95% faster** cache operations (LRU optimization)
- **50% less** memory fragmentation (pooled allocation)
- **Native JOIN queries** for complex dependency resolution
- **Aggregate functions** for registry statistics

---

## 🔗 **Related Documentation**

- [ZQLITE_NEW_DEV_NOTES.md](ZQLITE_NEW_DEV_NOTES.md) - ZQLITE v0.4.0 migration guide
- [README.md](README.md) - Project overview and setup
- [LXC-SETUP.md](LXC-SETUP.md) - Proxmox LXC deployment
- [ZQLITE_INTEGRATION.md](ZQLITE_INTEGRATION.md) - Technical integration details

---

**🎉 Happy packaging with Zepplin!**
