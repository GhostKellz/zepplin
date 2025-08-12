# AUGUST WEEKEND TODO - Zepplin Package Registry v0.5.0

## Vision & Goals
Transform Zepplin into a production-ready Cargo replacement for Zig ecosystem, fully hosted at zig.cktech.org with seamless integration with zion (our Zig dev tool).

## Critical Issues Found

### 1. 🔴 Login/Auth System Broken
**Issue**: Getting 404 when clicking "Login" button
**Root Cause**: The `/login` route is missing from SPA routes in server.zig:502-506
**Fix Required**: 
- Add `/login` to SPA routes list to serve index.html
- Ensure auth.html is properly linked or create proper login page component
- Current auth endpoint exists at `/auth` but UI links to `/login`

### 2. 🔴 Package Publishing Not Working
**Issue**: Cannot publish packages through web UI
**Root Cause**: 
- Publishing requires authentication token
- No UI implementation for package upload form
- API exists at `/api/v1/packages/{owner}/{repo}/releases` but no web interface
**Fix Required**:
- Create package publishing UI component
- Add file upload interface with metadata fields
- Implement authentication flow for publishing

### 3. 🔴 Empty Package Categories
**Issue**: Web, Cryptography categories show no packages
**Root Cause**: 
- Only 4 mock packages in database (database_sqlite.zig:1043)
- No real packages published yet
- Categories not properly mapped to packages
**Fix Required**:
- Publish initial set of packages
- Implement category tagging system
- Add more mock data for development

## Weekend Priority Tasks

### Phase 1: Fix Critical Functionality (Saturday Morning)
- [ ] **Fix Login Route** 
  - Add `/login` to SPA routes in server.zig
  - Test auth flow end-to-end
  - Verify token generation and storage
  
- [ ] **Create Package Publishing UI**
  - Build upload form component
  - Add drag-and-drop for .tar.gz files
  - Include metadata fields (version, description, keywords)
  - Display publishing guidelines

- [ ] **Fix Category System**
  - Add category field to package schema
  - Update search to filter by category
  - Populate with initial categories

### Phase 2: Core Registry Features (Saturday Afternoon)
- [ ] **Implement build.zig.zon Integration**
  - Create endpoint for dependency resolution
  - Format: `https://zig.cktech.org/api/packages/{name}/zon`
  - Return proper .zon format with URL and hash
  - Support version constraints

- [ ] **Package Download System**
  - Ensure `/api/v1/packages/{owner}/{repo}/download/{version}` works
  - Add CDN support for package files
  - Implement download counting

- [ ] **User Registration Flow**
  - Create registration UI
  - Email verification (optional for MVP)
  - API token generation for CLI usage

### Phase 3: OIDC/OAuth Integration (Saturday Evening)
- [ ] **Azure/Entra M365 OIDC Integration**
  - Implement OIDC client in auth.zig
  - Add Microsoft identity platform endpoints
  - Configure tenant ID and client credentials
  - Handle ID tokens and refresh tokens
  - Map Azure AD claims to user profile

- [ ] **GitHub OAuth Integration**
  - Implement OAuth 2.0 flow
  - Configure GitHub App credentials
  - Handle authorization callback
  - Fetch user profile and organizations
  - Link GitHub username to packages

- [ ] **Unified Auth System**
  - Create auth provider abstraction
  - Support multiple identity providers
  - Account linking (link GitHub + M365)
  - Session management with JWT
  - Single Sign-On (SSO) experience

- [ ] **UI Components**
  - "Sign in with Microsoft" button
  - "Sign in with GitHub" button
  - Account linking interface
  - Provider selection screen
  - Profile management page

### Phase 4: Zion Tool Integration (Sunday Morning)
- [ ] **API Compatibility Layer**
  - Ensure API matches what zion expects
  - Support authentication via API tokens
  - Implement rate limiting

- [ ] **Dependency Resolution API**
  - Create `/api/resolve` endpoint
  - Support semantic versioning
  - Handle transitive dependencies

- [ ] **Package Manifest Support**
  - Parse build.zig.zon files
  - Extract dependencies automatically
  - Version constraint resolution

### Phase 5: Populate Registry (Sunday Noon)
- [ ] **Import Essential Packages**
  - Use ZiglibsImporter to import from ziglibs
  - Priority packages:
    - xev (async I/O)
    - zap (web framework)
    - sqlite (database)
    - known-folders
    - ziglyph (unicode)
    
- [ ] **Create CKTech Packages**
  - Publish shroud (crypto library)
  - Publish zion tool itself
  - Create example packages

- [ ] **Documentation Packages**
  - Getting started guide
  - API documentation
  - Integration examples

### Phase 6: Production Deployment (Sunday Afternoon)
- [ ] **Server Configuration**
  - Set up nginx reverse proxy
  - Configure SSL certificates
  - Set up systemd service

- [ ] **Database Migration**
  - Move from SQLite to PostgreSQL (optional)
  - Set up backup strategy
  - Configure connection pooling

- [ ] **Monitoring & Analytics**
  - Add error tracking
  - Implement usage analytics
  - Set up health checks

### Phase 7: UI/UX Polish & Documentation (Sunday Evening)
- [ ] **Getting Started Section**
  - Quick start guide on homepage
  - Installation instructions
  - Example projects
  - Link to future wiki.cktech.org

- [ ] **Search Enhancement**
  - Add filters (language, stars, updated)
  - Implement fuzzy search
  - Add sorting options

- [ ] **Package Page Improvements**
  - Show README rendering
  - Display dependency tree
  - Add installation command copy button
  - Show version history

- [ ] **OIDC Documentation**
  - Create OIDC_SETUP_DOC.md
  - Azure/Entra M365 configuration guide
  - GitHub OAuth app setup instructions
  - Environment variables documentation
  - Troubleshooting common issues

## Technical Implementation Details

### Authentication Fix
```zig
// In server.zig around line 502, add:
else if (std.mem.startsWith(u8, path, "/login")) {
    try self.serveStaticFile(stream, "web/templates/index.html");
}
```

### OIDC/OAuth Implementation

#### Azure/Entra M365 Configuration
```zig
// auth_oidc.zig - New file for OIDC support
const OIDCConfig = struct {
    tenant_id: []const u8,
    client_id: []const u8,
    client_secret: []const u8,
    redirect_uri: []const u8,
    authority: []const u8,  // https://login.microsoftonline.com/{tenant_id}
    scope: []const u8,      // "openid profile email"
};

// Endpoints
const authorization_endpoint = "https://login.microsoftonline.com/{tenant_id}/oauth2/v2.0/authorize";
const token_endpoint = "https://login.microsoftonline.com/{tenant_id}/oauth2/v2.0/token";
const userinfo_endpoint = "https://graph.microsoft.com/v1.0/me";
```

#### GitHub OAuth Configuration
```zig
// auth_github.zig - GitHub OAuth support
const GitHubOAuthConfig = struct {
    client_id: []const u8,
    client_secret: []const u8,
    redirect_uri: []const u8,
    scope: []const u8,  // "read:user user:email"
};

// Endpoints
const github_authorize = "https://github.com/login/oauth/authorize";
const github_token = "https://github.com/login/oauth/access_token";
const github_user = "https://api.github.com/user";
```

#### API Routes
```zig
// New auth routes in server.zig
"/api/v1/auth/oidc/microsoft/login"   // Initiate Microsoft login
"/api/v1/auth/oidc/microsoft/callback" // Handle Microsoft callback
"/api/v1/auth/oauth/github/login"      // Initiate GitHub login
"/api/v1/auth/oauth/github/callback"   // Handle GitHub callback
"/api/v1/auth/link"                    // Link accounts
"/api/v1/auth/providers"               // List linked providers
```

#### Environment Variables
```bash
# .env file
AZURE_TENANT_ID=your-tenant-id
AZURE_CLIENT_ID=your-client-id
AZURE_CLIENT_SECRET=your-client-secret
GITHUB_CLIENT_ID=your-github-client-id
GITHUB_CLIENT_SECRET=your-github-client-secret
REDIRECT_BASE_URL=https://zig.cktech.org
JWT_SECRET=your-jwt-secret
```

### Package Publishing API Format
```json
POST /api/v1/packages/{owner}/{repo}/releases
Content-Type: multipart/form-data

Fields:
- file: package.tar.gz
- tag_name: "v1.0.0"
- body: "Release description"
- draft: false
- prerelease: false
```

### build.zig.zon URL Format
```
https://zig.cktech.org/api/packages/{name}/tarball/{version}
https://zig.cktech.org/api/packages/{name}/hash/{version}
```

## Database Schema Updates Needed
- Add `category` field to packages table
- Add `keywords` array field
- Add `stats` table for analytics
- Add `organizations` table for namespacing
- Add `auth_providers` table for OAuth/OIDC:
  ```sql
  CREATE TABLE auth_providers (
      id INTEGER PRIMARY KEY,
      user_id INTEGER REFERENCES users(id),
      provider TEXT NOT NULL, -- 'microsoft', 'github', 'local'
      provider_id TEXT NOT NULL, -- External user ID
      email TEXT,
      display_name TEXT,
      access_token TEXT,
      refresh_token TEXT,
      token_expires_at INTEGER,
      created_at INTEGER DEFAULT CURRENT_TIMESTAMP,
      UNIQUE(provider, provider_id)
  );
  ```
- Add `sessions` table for JWT management:
  ```sql
  CREATE TABLE sessions (
      id TEXT PRIMARY KEY, -- JWT token ID
      user_id INTEGER REFERENCES users(id),
      expires_at INTEGER NOT NULL,
      created_at INTEGER DEFAULT CURRENT_TIMESTAMP
  );
  ```

## API Endpoints to Implement
- `GET /api/packages/trending` - Trending packages
- `GET /api/packages/categories` - List all categories
- `GET /api/packages/category/{name}` - Packages by category
- `GET /api/packages/{name}/versions` - All versions
- `GET /api/packages/{name}/zon` - build.zig.zon format
- `POST /api/packages/{name}/star` - Star package
- `GET /api/stats` - Registry statistics

## Testing Checklist
- [ ] User can register and login
- [ ] User can publish a package via CLI
- [ ] User can publish via web UI
- [ ] Package appears in search results
- [ ] Package can be downloaded
- [ ] build.zig.zon can resolve dependencies
- [ ] Categories show correct packages
- [ ] Authentication persists across sessions

## Success Metrics
- ✅ Full authentication flow working
- ✅ At least 20 packages published
- ✅ Categories populated with packages
- ✅ Zion tool can pull dependencies
- ✅ Search returns relevant results
- ✅ Download counter working
- ✅ Production deployment stable

## Notes from Chris
- Using Zig v0.15 dev (cutting edge)
- Want full Cargo replacement functionality
- Hosting at zig.cktech.org
- Wiki will be at wiki.cktech.org (static pages, can skip for now)
- Focus on core functionality over documentation initially

## Additional Recommendations from Analysis

### Immediate Wins (Do First)
1. **Fix the login route** - Simple one-line fix
2. **Import ziglibs packages** - Already have importer tool
3. **Add more mock data** - Expand getMockPackages() in database_sqlite.zig

### Architecture Improvements
1. **Implement package namespacing** - Like `@cktech/package-name`
2. **Add organization support** - Group packages under orgs
3. **Version constraint solver** - For complex dependency trees
4. **Package signing** - Use Ed25519 signatures for security

### Future Enhancements (Post-Weekend)
1. **Package documentation generation** - Auto-generate from source
2. **CI/CD integration** - GitHub Actions for auto-publishing
3. **Mirror support** - Allow custom registry mirrors
4. **Private packages** - Paid tier for private hosting
5. **WebAssembly playground** - Try packages in browser

## Commands for Testing

```bash
# Build and start server
./dev.sh build
./dev.sh serve

# Test package publishing
curl -X POST http://localhost:8080/api/v1/packages/test/mypackage/releases \
  -H "Authorization: Bearer YOUR_TOKEN" \
  -F "file=@package.tar.gz" \
  -F "tag_name=v1.0.0" \
  -F "body=Initial release"

# Test package download
curl http://localhost:8080/api/v1/packages/test/mypackage/download/v1.0.0

# Test search
curl http://localhost:8080/api/search?q=web
```

## Docker Deployment Commands
```bash
# Production deployment
docker-compose --profile production up -d

# Check logs
docker logs zepplin-registry

# Enter container for debugging
docker exec -it zepplin-registry /bin/sh
```

---
**Target Completion**: End of Weekend (Sunday Night)
**Priority**: CRITICAL - Get core functionality working for zig.cktech.org launch