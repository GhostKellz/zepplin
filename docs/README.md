# Zepplin Documentation

Zepplin is a self-hostable package registry for Zig, backed by an embedded
database and a static frontend served by a Zig HTTP server. The documentation is
organized around getting the registry running, configuring authentication,
deploying to production, and integrating client tooling.

## Documentation Map

```mermaid
flowchart TD
    start["Start here<br/>docs/README.md"]

    start --> gs["Getting Started"]
    start --> cli["CLI"]
    start --> auth["Authentication"]
    start --> deploy["Deployment"]
    start --> integ["Integrations"]
    start --> project["Project"]

    gs --> frontend["frontend-setup.md"]

    cli --> commands["commands.md"]

    auth --> oidc["oidc.md"]
    auth --> github["github-oauth.md"]

    deploy --> guide["guide.md"]
    deploy --> quick["quickstart.md"]
    deploy --> env["environment.md"]
    deploy --> lxc["lxc-setup.md"]

    integ --> zqlite["zqlite.md"]
    integ --> sqlite["sqlite.md"]
    integ --> zion["zion.md"]
    integ --> zigistry["zigistry.md"]

    project --> compat["zig-compatibility.md"]
```

## Runtime Shape

```mermaid
flowchart LR
    client["Zig client / browser"] --> nginx["Reverse proxy<br/>(nginx, optional)"]
    nginx --> server["Zepplin HTTP server"]

    server --> static["Static frontend<br/>(dist/)"]
    server --> api["REST API<br/>(/api/v1)"]
    server --> authmod["Auth layer"]

    api --> db["Embedded database<br/>(zqlite)"]
    api --> store["Package storage"]

    authmod --> local["Local<br/>(Argon2id + session JWT)"]
    authmod --> entra["Microsoft / Entra<br/>(OIDC)"]
    authmod --> ghoauth["GitHub<br/>(OAuth2)"]
    authmod --> google["Google<br/>(OIDC)"]
```

## Authentication Flow

```mermaid
flowchart TD
    visitor{"How is the user signing in?"}

    visitor --> creds["Email / password"]
    visitor --> provider["OAuth / OIDC provider"]

    creds --> verify["Argon2id verify"]
    provider --> exchange["Authorization-code exchange"]

    exchange --> userinfo["Fetch provider profile"]
    userinfo --> persist["findOrCreateOAuthUser<br/>(provider, external_id)"]

    verify --> session["Issue session JWT (HS256)"]
    persist --> session

    session --> cookie["Set zepplin_token cookie<br/>+ localStorage keys"]
```

## Getting Started

- [Frontend Setup](getting-started/frontend-setup.md) - Build and run the Astro frontend that the server serves from `dist/`.

## CLI

- [Commands Reference](cli/commands.md) - Full command and flag reference for the Zepplin command-line tool.

## Authentication

- [OIDC / OAuth Setup](authentication/oidc.md) - Configure Microsoft/Entra OIDC and GitHub OAuth providers.
- [GitHub OAuth Setup](authentication/github-oauth.md) - Step-by-step GitHub OAuth app configuration.

## Deployment

- [Deployment Guide](deployment/guide.md) - Production deployment behind an external nginx reverse proxy.
- [Deployment Quickstart](deployment/quickstart.md) - Condensed checklist for a production deploy with OAuth.
- [Environment Configuration](deployment/environment.md) - Environment variables for configuring the server at runtime.
- [Proxmox LXC Setup](deployment/lxc-setup.md) - Provision and configure a Proxmox LXC container for the registry.

## Integrations

- [ZQLite Database](integrations/zqlite.md) - Using ZQLite as the embedded database engine.
- [SQLite Backend](integrations/sqlite.md) - SQLite-backed persistent storage details.
- [Zion Client](integrations/zion.md) - Integrating the Zion package manager with a Zepplin registry.
- [Zigistry](integrations/zigistry.md) - Zigistry interoperability and indexing notes.

## Project

- [Zig Compatibility](project/zig-compatibility.md) - Compatibility notes and breaking-change guidance across Zig versions.

## Quick Links

| Area | Path |
|------|------|
| Project README | [`../README.md`](../README.md) |
| Release notes | [`../CHANGELOG.md`](../CHANGELOG.md) |
| Build script | [`../build.zig`](../build.zig) |
| Package metadata | [`../build.zig.zon`](../build.zig.zon) |
| Server source | [`../src/server/server.zig`](../src/server/server.zig) |
| Auth modules | [`../src/auth/`](../src/auth/) |
