<p align="center">
  <img src="assets/logo/dark-preview.png" alt="Zepplin Logo" width="400">
</p>

# ⚡ Zepplin

> A lightweight, blazing-fast package manager and self-hosted registry for the Zig ecosystem.

Zepplin is your minimal, high-performance companion for managing Zig projects and packages. Designed to bring the convenience of `cargo` and the scalability of Kellnr to Zig, Zepplin helps developers stay focused on performance and simplicity — just like Zig itself.

**🎉 WORKING PROTOTYPE - ALL THREE COMPONENTS IMPLEMENTED!**
- ✅ CLI Package Manager
- ✅ Self-Hosted Registry Server  
- ✅ Beautiful Web Interface
- ✅ Docker Support

![Zepplin Preview](assets/Zepplin_preview.png)

---

## 🚀 Quick Start

```bash
# Clone and build
git clone <your-repo-url>
cd zepplin
./scripts/dev.sh build

# Start the registry server
./scripts/dev.sh serve

# In another terminal, use the CLI
./scripts/dev.sh run init                    # Initialize a new project
./scripts/dev.sh run add xev                 # Add a package
./scripts/dev.sh run publish                 # Publish to registry
```

---

## 🔧 CLI Commands

```bash
zepplin init               # Bootstrap a new Zig project with zepplin.toml
zepplin add xev            # Add a package from the registry
zepplin add xev@1.2.0      # Add a specific version
zepplin update             # Update all dependencies
zepplin build              # Run zig build + dependency resolution
zepplin publish            # Package and push to the registry
zepplin login [registry]   # Authenticate with your registry
zepplin serve [port]       # Start the registry server (default: 8080)
zepplin browse             # Browse packages by category
zepplin trending           # Show trending packages
```

---

## 🌐 Self-Hosted Registry

Zepplin includes a built-in registry server with a beautiful web interface:

### Features
- **🎨 Modern Web UI** - Browse packages with a sleek, dark-themed interface
- **🔍 Real-time Search** - Find packages instantly
- **📊 Usage Statistics** - Track downloads and package metrics
- **🔐 Authentication** - Secure package publishing
- **🚀 RESTful API** - Full API for programmatic access
- **📦 Package Management** - Upload, version, and manage packages

### Web Interface
Visit `http://localhost:8080` after starting the server to access the web interface with:
- Package browser and search
- Download statistics
- Package details and documentation
- User management (coming soon)

### API Endpoints
```
GET  /                           # Web interface
GET  /api/packages               # List all packages
GET  /api/packages/{name}        # Get package details
POST /api/packages               # Publish a package (requires auth)
GET  /api/search?q={query}       # Search packages
```

---

## � Docker Deployment

### Quick Docker Run
```bash
# Build and run with Docker
./scripts/dev.sh docker-build
./scripts/dev.sh docker-run 8080

# Or manually
docker build -t zepplin -f release/Dockerfile .
docker run -p 8080:8080 -v zepplin-data:/data zepplin
```

### Production with Docker Compose
```bash
# Start the full stack (registry + nginx)
docker-compose -f release/docker-compose.yml --profile production up -d

# Development mode (registry only)
docker-compose -f release/docker-compose.yml up -d
```

The Docker setup includes:
- **Multi-stage builds** for minimal image size
- **Health checks** for reliability
- **Volume persistence** for package data
- **Nginx reverse proxy** with rate limiting and caching
- **Non-root user** for security

---

## 🏗️ Project Architecture

```
src/
├── main.zig           # Entry point (CLI + server mode)
├── root.zig           # Library exports
├── cli/               # Command-line interface
│   ├── cli.zig        # CLI command implementations
│   └── commands.zig   # Command parsing and help
├── server/            # Registry server
│   └── server.zig     # HTTP server and web UI
└── common/            # Shared types and utilities
    └── types.zig      # Package metadata, API types
```

### Configuration Files
- `zepplin.toml` - Project configuration and dependencies
- `zepplin.lock` - Locked dependency versions (like Cargo.lock)
- `release/docker-compose.yml` - Container orchestration
- `release/Dockerfile` - Container build
- `release/nginx/production.conf` - Reverse proxy configuration
- `release/.env.example` - Environment variable template

### Repository Layout
- `release/` - Dockerfile(s), docker-compose, nginx configs, env template
- `scripts/` - Dev, install, and provisioning scripts (`dev.sh`, `install.sh`, `setup-lxc.sh`)
- `tests/` - Standalone test programs and fixtures
- `docs/` - Documentation ([docs/README.md](docs/README.md))

---

## 📋 Development

### Prerequisites
- Zig 0.17.0-dev (master) — stable 0.16.x supported as a reference target
- Docker (optional, for containerized deployment)

### Development Workflow
```bash
# Build and test
./scripts/dev.sh build
./scripts/dev.sh test

# Run CLI commands
./scripts/dev.sh run help
./scripts/dev.sh run init

# Start development server
./scripts/dev.sh serve 3000

# Clean build artifacts
./scripts/dev.sh clean
```

### Development Script Commands
| Command | Description |
|---------|-------------|
| `build` | Build the project |
| `test` | Run all tests |
| `run [args...]` | Execute CLI with arguments |
| `serve [port]` | Start registry server |
| `docker-build` | Build Docker image |
| `docker-run [port]` | Run in Docker |
| `dev-up` | Start development environment |
| `dev-down` | Stop development environment |
| `clean` | Clean build artifacts |

---

## �️ Roadmap

### Phase 1: Core Functionality ✅
- [x] CLI command structure
- [x] Basic package management commands
- [x] HTTP registry server
- [x] Web interface
- [x] Docker deployment

### Phase 2: Package Management 🚧
- [ ] TOML configuration parsing
- [ ] Dependency resolution
- [ ] Package downloading and caching
- [ ] Integration with `zig build`
- [ ] Package validation and signing

### Phase 3: Registry Features 📋
- [ ] User authentication and authorization
- [ ] Package publishing workflow
- [ ] Search and discovery
- [ ] Usage analytics
- [ ] Package documentation hosting

### Phase 4: Advanced Features 🔮
- [ ] Binary caching
- [ ] Multi-registry support
- [ ] Package mirroring
- [ ] CI/CD integration
- [ ] Package vulnerability scanning

---

## 🔐 Security

- **Package Signing** - GPG/cryptographic verification
- **Rate Limiting** - Prevent abuse via nginx
- **Input Validation** - Strict parsing and validation
- **Container Security** - Non-root user, minimal attack surface
- **HTTPS Support** - TLS encryption for production

---

## 🤝 Contributing

1. Fork the repository
2. Create a feature branch
3. Make your changes
4. Run tests: `./scripts/dev.sh test`
5. Submit a pull request

---

## 📜 License

MIT

---

## 📚 Documentation

Full documentation lives in [`docs/`](docs/README.md). Highlights:

- **[Deployment Guide](docs/deployment/guide.md)** - Complete production deployment with nginx
- **[Deployment Quickstart](docs/deployment/quickstart.md)** - Quick deployment steps
- **[Environment Configuration](docs/deployment/environment.md)** - Runtime environment variables
- **[CLI Commands](docs/cli/commands.md)** - Command-line reference
- **[OIDC / OAuth Setup](docs/authentication/oidc.md)** - Microsoft/Entra and GitHub authentication
- **[GitHub OAuth Setup](docs/authentication/github-oauth.md)** - GitHub SSO configuration
- **[SQLite Backend](docs/integrations/sqlite.md)** - Database implementation details
- **[Zigistry Integration](docs/integrations/zigistry.md)** - Package discovery features

---

> Made with Zig ⚡ | Inspired by Cargo & Kellnr 🚀 | Built for hackers 🛠️

**Zepplin** brings the best of Rust's Cargo and private registry hosting to the Zig ecosystem, providing developers with a complete solution for package management and distribution.

**🎉 Production Ready**: Complete SQLite backend, Zigistry integration, Docker deployment, and nginx configuration included!

