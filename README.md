# Zepplin

> A lightweight, blazing-fast package manager and module registry client for the Zig ecosystem.

Zepplin is your minimal, high-performance companion for managing Zig projects and packages. Designed to bring the convenience of `cargo` and the scalability of a self-hosted registry to Zig, Zepplin helps developers stay focused on performance and simplicity — just like Zig itself.

---

## 🚀 Key Features

* ⚡ **Lightning-Fast CLI** written in Zig
* 📦 **Dependency Management** via local and remote registries
* 🌐 **Self-Hosted or Decentralized Registry** (static HTTPS or IPFS-based)
* 🏗️ **Project Initialization and Build Integration**
* 🔐 **GPG/Key Signing Support** for package authenticity
* 🔄 **Offline-First Workflow** with local caching
* 🧪 **Versioning + Compatibility Checks**
* 💬 **Readable zepplin.lock file** for reproducible builds

---

## 🔧 Commands

```sh
zepplin init               # Bootstrap a new Zig project
zepplin add xev            # Add a package from the registry
zepplin update             # Update dependencies
zepplin build              # Run zig build + dependency resolution
zepplin publish            # Package and push to the self-hosted registry
zepplin login              # Authenticate with your registry (optional)
```

---

## 🧱 Architecture

* `zepplin` CLI (Zig)
* `zepplin.lock` + `zepplin.toml` for dependency state
* Remote index: static files over HTTPS (or IPFS), signed JSON index
* Registry spec compatible with offline-first environments (mirrors, caching)
* Easy integration with `zigmod`, `gyro`, and native Zig `build.zig`

---

## 🔐 Self-Hosting

Zepplin supports hosting your own registry via:

* Static HTTPS + JSON index files
* GitHub Pages or Git repos
* IPFS decentralized hosting (optional)
* Signed package manifests for trustless fetches

### Example Directory Layout

```
registry/
├── index.json
├── packages/
│   ├── xev/
│   │   ├── 1.2.0/
│   │   │   └── xev.zpkg
```

---

## 🌍 Vision

Zepplin aims to:

* Be a `cargo`-like UX for Zig without overengineering
* Give developers tools to self-host, sign, and share code simply
* Evolve into a deployable build + packaging ecosystem (Zig-native Docker/Nix alt)

---

## 🛠️ Future Plans

* GUI registry browser for hosted registries
* Package metadata search and discovery
* Binary cache layer
* Hooks into Zig's compiler for richer dependency tooling

---

## 📜 License

MIT

> Made with Zig ⚡ | Inspired by Cargo 🚀 | Built for hackers 🛠️

