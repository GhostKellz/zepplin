# Changelog

All notable changes to Zepplin will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.6.1] - 2026-03-28

### Fixed

- **Dockerfile Zig Version**: Fixed hardcoded Zig version (0.16.0-dev.164) that was removed from upstream servers, causing Docker builds to fail
- Dockerfile now dynamically fetches latest Zig master build from ziglang.org/download/index.json using `jq`
- Added `jq` to Docker build dependencies for reliable JSON parsing

## [0.6.0] - 2026-03-28

### Added

- **Microsoft Entra OIDC Integration**: Full OAuth2/OIDC support for Microsoft 365 authentication including token exchange, user info retrieval, and token refresh
- **SMTP Email Integration**: Email verification, password reset, and package publish notifications via SMTP2Go
- **Real Zigistry HTTP Client**: Live integration with Zigistry.dev API for package search and discovery
- **Tar.gz Package Handling**: Native tar.gz compression and extraction for package distribution
- **Documentation Pages**: New web UI pages for Getting Started, API Reference, CLI Guide, and Contributing

### Changed

- **Zig 0.16.0 Migration**: Updated entire codebase to Zig 0.16.0-dev.3006 with new filesystem API (`std.Io.Dir`) and main function signature (`pub fn main(init: std.process.Init)`)
- **ArrayList API Update**: Migrated from deprecated `std.array_list.AlignedManaged` to `std.ArrayList` with new allocation patterns
- **Database Layer**: Replaced mock implementations with real zqlite Row API for user and package queries
- **Documentation Structure**: Reorganized docs into `docs/api/`, `docs/sso/`, and `docs/deployment/` directories

### Fixed

- GitHub OAuth URL encoding for redirect URIs and scopes
- Database `getUserByToken` and `getUserByUsername` now use real database queries
- Package search and listing functions properly iterate zqlite result sets
- Web GUI navigation links to documentation pages

### Dependencies

- Pinned zqlite to v1.5.4
- Pinned zsync to v0.7.8
- Removed shroud dependency (abandoned)

## [0.5.0] - 2026-03-15

### Added

- Initial GitHub OAuth integration
- Basic web UI with package browser
- CLI tools for package management
- SQLite database backend via zqlite

### Changed

- Migrated from file-based storage to database-backed metadata

## [0.4.0] - 2026-02-28

### Added

- Package publishing workflow
- Version semver parsing and validation
- Basic authentication system

## [0.3.0] - 2026-02-10

### Added

- HTTP server with routing
- Package download endpoints
- Basic package storage

## [0.2.0] - 2026-01-20

### Added

- Project structure and build system
- Configuration via TOML
- Environment variable support

## [0.1.0] - 2026-01-05

### Added

- Initial project setup
- Basic Zig build configuration
