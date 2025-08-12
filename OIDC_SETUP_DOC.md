# OIDC/OAuth Setup Documentation for Zepplin

This guide walks through setting up Azure/Entra M365 OIDC and GitHub OAuth authentication for the Zepplin package registry.

## Table of Contents
1. [Azure/Entra M365 OIDC Setup](#azureentra-m365-oidc-setup)
2. [GitHub OAuth Setup](#github-oauth-setup)
3. [Zepplin Configuration](#zepplin-configuration)
4. [Testing Authentication](#testing-authentication)
5. [Troubleshooting](#troubleshooting)
6. [Security Best Practices](#security-best-practices)

---

## Azure/Entra M365 OIDC Setup

### Step 1: Register Application in Azure Portal

1. **Navigate to Azure Portal**
   - Go to https://portal.azure.com
   - Sign in with your Microsoft 365 admin account

2. **Access App Registrations**
   - Navigate to "Azure Active Directory" → "App registrations"
   - Click "New registration"

3. **Configure Basic Settings**
   ```
   Name: Zepplin Package Registry
   Supported account types: 
     - Single tenant (for internal org use)
     - OR Multitenant (for public registry)
   Redirect URI: 
     - Platform: Web
     - URI: https://zig.cktech.org/api/v1/auth/oidc/microsoft/callback
   ```

4. **Save Application (Client) ID and Tenant ID**
   - After registration, note down:
     - Application (client) ID: `xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx`
     - Directory (tenant) ID: `yyyyyyyy-yyyy-yyyy-yyyy-yyyyyyyyyyyy`

### Step 2: Configure Authentication

1. **Add Additional Redirect URIs**
   - Go to "Authentication" in left menu
   - Add these redirect URIs:
     ```
     https://zig.cktech.org/api/v1/auth/oidc/microsoft/callback
     http://localhost:8080/api/v1/auth/oidc/microsoft/callback (for development)
     ```

2. **Configure Implicit Grant and Hybrid Flows**
   - Check "ID tokens" under Implicit grant and hybrid flows
   - Save changes

3. **Configure Platform Settings**
   - Front-channel logout URL: `https://zig.cktech.org/logout`
   - Enable public client flows: No

### Step 3: Create Client Secret

1. **Navigate to Certificates & Secrets**
   - Click "New client secret"
   - Description: `Zepplin Registry Secret`
   - Expires: Choose appropriate expiration (recommend 12-24 months)

2. **Save Secret Value**
   - **IMPORTANT**: Copy the secret value immediately (you won't see it again)
   - Secret Value: `your-client-secret-here`

### Step 4: Configure API Permissions

1. **Add Permissions**
   - Click "Add a permission"
   - Select "Microsoft Graph"
   - Choose "Delegated permissions"
   - Add these permissions:
     ```
     - openid (Sign users in)
     - profile (View users' basic profile)
     - email (View users' email address)
     - User.Read (Sign in and read user profile)
     ```

2. **Grant Admin Consent** (if required)
   - Click "Grant admin consent for [Your Organization]"

### Step 5: Configure Token Settings (Optional)

1. **Navigate to Token Configuration**
   - Add optional claims if needed:
     - email
     - preferred_username
     - given_name
     - family_name

---

## GitHub OAuth Setup

### Step 1: Create GitHub OAuth App

1. **Navigate to GitHub Settings**
   - Go to https://github.com/settings/developers
   - Click "OAuth Apps" → "New OAuth App"

2. **Configure Application**
   ```
   Application name: Zepplin Package Registry
   Homepage URL: https://zig.cktech.org
   Application description: Package registry for Zig ecosystem
   Authorization callback URL: https://zig.cktech.org/api/v1/auth/oauth/github/callback
   Enable Device Flow: No (unchecked)
   ```

3. **Register Application**
   - Click "Register application"
   - Note down the Client ID

4. **Generate Client Secret**
   - Click "Generate a new client secret"
   - **IMPORTANT**: Copy the secret immediately
   - Client ID: `Iv1.xxxxxxxxxxxxxxxxx`
   - Client Secret: `github_pat_xxxxxxxxxxxxxxxxxxxxxxxxxxx`

### Step 2: Configure Webhooks (Optional)

1. **Add Webhook URL** (for package updates)
   ```
   Webhook URL: https://zig.cktech.org/api/webhooks/github
   Content type: application/json
   Secret: generate-a-secure-webhook-secret
   ```

2. **Select Events**
   - Releases (for auto-publishing)
   - Push (for repository updates)

---

## Zepplin Configuration

### Step 1: Environment Variables

Create a `.env` file in your Zepplin directory:

```bash
# Azure/Entra M365 OIDC Configuration
AZURE_TENANT_ID=yyyyyyyy-yyyy-yyyy-yyyy-yyyyyyyyyyyy
AZURE_CLIENT_ID=xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
AZURE_CLIENT_SECRET=your-azure-client-secret-here
AZURE_REDIRECT_URI=https://zig.cktech.org/api/v1/auth/oidc/microsoft/callback

# GitHub OAuth Configuration
GITHUB_CLIENT_ID=Iv1.xxxxxxxxxxxxxxxxx
GITHUB_CLIENT_SECRET=github_pat_xxxxxxxxxxxxxxxxxxxxxxxxxxx
GITHUB_REDIRECT_URI=https://zig.cktech.org/api/v1/auth/oauth/github/callback

# JWT Configuration
JWT_SECRET=generate-a-very-long-random-string-here
JWT_EXPIRY=86400  # 24 hours in seconds

# Base URLs
BASE_URL=https://zig.cktech.org
API_BASE_URL=https://zig.cktech.org/api/v1

# Session Configuration
SESSION_COOKIE_NAME=zepplin_session
SESSION_COOKIE_SECURE=true  # Set to false for development
SESSION_COOKIE_HTTPONLY=true
SESSION_COOKIE_SAMESITE=lax

# Optional: Organization Restrictions
AZURE_ALLOWED_TENANTS=tenant1,tenant2  # Comma-separated list
GITHUB_ALLOWED_ORGS=cktech,zigcommunity  # Comma-separated list
```

### Step 2: Update Zepplin Configuration

Add to your `config.zig` or server configuration:

```zig
const AuthConfig = struct {
    // Azure OIDC
    azure_enabled: bool = true,
    azure_tenant_id: []const u8,
    azure_client_id: []const u8,
    azure_client_secret: []const u8,
    azure_redirect_uri: []const u8,
    
    // GitHub OAuth
    github_enabled: bool = true,
    github_client_id: []const u8,
    github_client_secret: []const u8,
    github_redirect_uri: []const u8,
    
    // JWT Settings
    jwt_secret: []const u8,
    jwt_expiry: u32 = 86400, // 24 hours
    
    // Security
    allowed_domains: []const []const u8 = &.{},
    require_email_verification: bool = false,
};
```

### Step 3: Database Migration

Run the database migration to add OAuth tables:

```sql
-- Create auth_providers table
CREATE TABLE IF NOT EXISTS auth_providers (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    user_id INTEGER NOT NULL,
    provider TEXT NOT NULL,
    provider_user_id TEXT NOT NULL,
    email TEXT,
    display_name TEXT,
    avatar_url TEXT,
    access_token TEXT,
    refresh_token TEXT,
    token_expires_at INTEGER,
    raw_profile TEXT, -- JSON blob of full profile
    created_at INTEGER DEFAULT (unixepoch()),
    updated_at INTEGER DEFAULT (unixepoch()),
    FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE,
    UNIQUE(provider, provider_user_id)
);

-- Create sessions table
CREATE TABLE IF NOT EXISTS sessions (
    id TEXT PRIMARY KEY,
    user_id INTEGER NOT NULL,
    ip_address TEXT,
    user_agent TEXT,
    expires_at INTEGER NOT NULL,
    created_at INTEGER DEFAULT (unixepoch()),
    last_accessed INTEGER DEFAULT (unixepoch()),
    FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE
);

-- Add OAuth fields to users table
ALTER TABLE users ADD COLUMN auth_provider TEXT DEFAULT 'local';
ALTER TABLE users ADD COLUMN last_login INTEGER;
ALTER TABLE users ADD COLUMN login_count INTEGER DEFAULT 0;

-- Create indexes for performance
CREATE INDEX idx_auth_providers_user_id ON auth_providers(user_id);
CREATE INDEX idx_auth_providers_provider ON auth_providers(provider);
CREATE INDEX idx_sessions_user_id ON sessions(user_id);
CREATE INDEX idx_sessions_expires_at ON sessions(expires_at);
```

---

## Testing Authentication

### Test Azure/Entra M365 Login

1. **Start Zepplin Server**
   ```bash
   ./dev.sh serve
   ```

2. **Test Login Flow**
   ```bash
   # Navigate to login URL
   curl -v https://zig.cktech.org/api/v1/auth/oidc/microsoft/login
   
   # This should redirect to:
   https://login.microsoftonline.com/{tenant_id}/oauth2/v2.0/authorize?
     client_id={client_id}&
     response_type=code&
     redirect_uri=https://zig.cktech.org/api/v1/auth/oidc/microsoft/callback&
     scope=openid%20profile%20email&
     state={state_token}
   ```

3. **Verify Callback**
   - After successful login, Microsoft will redirect to your callback URL
   - Zepplin should exchange the code for tokens
   - User should be logged in with a session cookie

### Test GitHub Login

1. **Test Login Flow**
   ```bash
   # Navigate to login URL
   curl -v https://zig.cktech.org/api/v1/auth/oauth/github/login
   
   # This should redirect to:
   https://github.com/login/oauth/authorize?
     client_id={client_id}&
     redirect_uri=https://zig.cktech.org/api/v1/auth/oauth/github/callback&
     scope=read:user%20user:email&
     state={state_token}
   ```

2. **Verify User Data**
   ```bash
   # Check current user
   curl -H "Cookie: zepplin_session=xxx" \
        https://zig.cktech.org/api/v1/auth/me
   ```

### Test Account Linking

```bash
# Link GitHub to existing Microsoft account
curl -X POST https://zig.cktech.org/api/v1/auth/link \
     -H "Cookie: zepplin_session=xxx" \
     -d '{"provider": "github"}'
```

---

## Troubleshooting

### Common Azure/Entra Issues

1. **"AADSTS50011: Reply URL mismatch"**
   - Ensure redirect URI in app registration matches exactly
   - Check for trailing slashes
   - Verify HTTP vs HTTPS

2. **"AADSTS700016: Application not found"**
   - Verify tenant ID is correct
   - Check client ID is from correct app registration
   - Ensure app is not deleted or disabled

3. **"AADSTS7000218: Invalid client secret"**
   - Client secret may have expired
   - Special characters in secret need proper escaping
   - Generate new secret if needed

4. **"AADSTS50020: User account does not exist"**
   - User might be from different tenant
   - Check supported account types setting
   - Verify user has proper licenses

### Common GitHub Issues

1. **"Bad verification code"**
   - State parameter mismatch (CSRF protection)
   - Code already used (codes are single-use)
   - Code expired (10-minute validity)

2. **"Incorrect client credentials"**
   - Verify client ID and secret
   - Check for whitespace in environment variables
   - Ensure secret hasn't been revoked

3. **"404 Not Found" on callback**
   - Callback URL not registered correctly
   - Route not implemented in Zepplin

### Session Issues

1. **"User logged out immediately"**
   - Cookie settings too restrictive
   - JWT expiry too short
   - Session not persisted to database

2. **"Cannot link accounts"**
   - Email mismatch between providers
   - Account already linked
   - User ID conflict

---

## Security Best Practices

### 1. Environment Security
- **Never commit** `.env` files to version control
- Use environment-specific configurations
- Rotate secrets regularly (every 6-12 months)
- Use secret management services in production (Azure Key Vault, GitHub Secrets)

### 2. Token Security
```bash
# Generate secure JWT secret
openssl rand -base64 64

# Generate secure state tokens for OAuth
openssl rand -hex 32
```

### 3. Session Management
- Implement session timeout (idle and absolute)
- Clear sessions on logout
- Validate session on each request
- Log security events (login, logout, failed attempts)

### 4. Rate Limiting
```zig
const RateLimits = struct {
    login_attempts: u32 = 5,        // per 15 minutes
    api_calls: u32 = 1000,          // per hour
    failed_auth_lockout: u32 = 30,  // minutes
};
```

### 5. CORS Configuration
```zig
const CORSConfig = struct {
    allowed_origins: []const []const u8 = &.{
        "https://zig.cktech.org",
        "https://wiki.cktech.org",
    },
    allowed_methods: []const []const u8 = &.{"GET", "POST", "PUT", "DELETE"},
    allowed_headers: []const []const u8 = &.{"Content-Type", "Authorization"},
    credentials: bool = true,
};
```

### 6. Audit Logging
```zig
// Log authentication events
fn logAuthEvent(user_id: ?i64, event: []const u8, provider: []const u8, success: bool) !void {
    const query = 
        \\INSERT INTO audit_log (user_id, event, provider, success, ip_address, timestamp)
        \\VALUES (?, ?, ?, ?, ?, ?)
    ;
    // Implementation...
}
```

### 7. Production Checklist
- [ ] HTTPS only (no HTTP in production)
- [ ] Secure cookie flags set
- [ ] CSRF protection enabled
- [ ] Rate limiting configured
- [ ] Secrets in secure vault
- [ ] Monitoring and alerting setup
- [ ] Regular security audits
- [ ] Backup authentication method

---

## Implementation Timeline

### Phase 1: Basic Integration (2-3 hours)
- Set up Azure app registration
- Set up GitHub OAuth app
- Configure environment variables
- Implement basic auth flow

### Phase 2: Database & Sessions (2-3 hours)
- Run database migrations
- Implement session management
- Add user profile mapping
- Test login/logout flow

### Phase 3: Account Linking (1-2 hours)
- Implement account linking logic
- Handle email verification
- Test multiple provider scenarios

### Phase 4: UI Integration (2-3 hours)
- Add login buttons to UI
- Create account management page
- Implement logout functionality
- Add session indicators

### Phase 5: Testing & Polish (1-2 hours)
- End-to-end testing
- Error handling
- Documentation
- Security review

---

## Support Resources

### Microsoft Identity Platform
- [Documentation](https://docs.microsoft.com/en-us/azure/active-directory/develop/)
- [OAuth 2.0 Flow](https://docs.microsoft.com/en-us/azure/active-directory/develop/v2-oauth2-auth-code-flow)
- [Error Codes](https://docs.microsoft.com/en-us/azure/active-directory/develop/reference-aadsts-error-codes)

### GitHub OAuth
- [Documentation](https://docs.github.com/en/developers/apps/building-oauth-apps)
- [Scopes](https://docs.github.com/en/developers/apps/building-oauth-apps/scopes-for-oauth-apps)
- [API Reference](https://docs.github.com/en/rest/reference/oauth-authorizations)

### Zepplin Specific
- Repository: https://github.com/yourusername/zepplin
- Issues: https://github.com/yourusername/zepplin/issues
- Wiki: https://wiki.cktech.org (coming soon)

---

## Quick Reference Card

### Azure/Entra Endpoints
```
Authorize: https://login.microsoftonline.com/{tenant}/oauth2/v2.0/authorize
Token:     https://login.microsoftonline.com/{tenant}/oauth2/v2.0/token
UserInfo:  https://graph.microsoft.com/v1.0/me
Logout:    https://login.microsoftonline.com/{tenant}/oauth2/v2.0/logout
```

### GitHub Endpoints
```
Authorize: https://github.com/login/oauth/authorize
Token:     https://github.com/login/oauth/access_token
User:      https://api.github.com/user
Emails:    https://api.github.com/user/emails
```

### Zepplin Auth Endpoints
```
Microsoft Login:    GET  /api/v1/auth/oidc/microsoft/login
Microsoft Callback: GET  /api/v1/auth/oidc/microsoft/callback
GitHub Login:       GET  /api/v1/auth/oauth/github/login  
GitHub Callback:    GET  /api/v1/auth/oauth/github/callback
Current User:       GET  /api/v1/auth/me
Logout:            POST /api/v1/auth/logout
Link Account:      POST /api/v1/auth/link
Unlink Account:    POST /api/v1/auth/unlink
```

---

**Document Version**: 1.0.0  
**Last Updated**: August 2024  
**Author**: Zepplin Team