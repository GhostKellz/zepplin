# GitHub OAuth Setup for Zepplin Registry

This guide walks you through setting up GitHub OAuth authentication for your Zepplin package registry as a secondary authentication option alongside Azure AD.

## Prerequisites

- GitHub account with admin access to your organization (if using GitHub Organizations)
- Your Zepplin registry domain (e.g., `zig.cktech.org`)
- Completed Azure AD setup (primary authentication)

## Step 1: Create GitHub OAuth App

### 1.1 Navigate to OAuth Apps
1. Go to [GitHub.com](https://github.com)
2. Click your profile picture → **Settings**
3. In the left sidebar, click **Developer settings**
4. Click **OAuth Apps**
5. Click **New OAuth App**

> **For Organizations**: If you want the app under an organization, go to your Organization → **Settings** → **Developer settings** → **OAuth Apps** → **New OAuth App**

### 1.2 Configure OAuth App Settings

Fill out the OAuth App form:

- **Application name**: `Zepplin Package Registry`
- **Homepage URL**: `https://zig.cktech.org`
- **Application description**: 
  ```
  Zig package registry with OAuth authentication. 
  Allows developers to publish and manage Zig packages.
  ```
- **Authorization callback URL**: `https://zig.cktech.org/api/v1/auth/oauth/github/callback`

Click **Register application**.

### 1.3 Add Additional Callback URLs (Optional)
For development/testing environments:
1. Click **Update application**
2. In **Authorization callback URL**, you can only have one URL
3. For multiple environments, create separate OAuth Apps:
   - **Development**: `http://localhost:8080/api/v1/auth/oauth/github/callback`
   - **Staging**: `https://staging.zig.cktech.org/api/v1/auth/oauth/github/callback`
   - **Production**: `https://zig.cktech.org/api/v1/auth/oauth/github/callback`

## Step 2: Configure App Settings

### 2.1 Update Application Settings
1. **Upload Logo**: Add your Zepplin logo (recommended size: 200x200px)
2. **Application description**: Make it detailed for user trust
3. **Application homepage**: Link to your main registry page

### 2.2 Generate Client Secret
1. In your OAuth App settings, click **Generate a new client secret**
2. **⚠️ IMPORTANT**: Copy the client secret immediately - you won't be able to see it again!
3. Store it securely (use Docker secrets, environment variables, etc.)

## Step 3: Configure Scopes and Permissions

### 3.1 Default Scopes
GitHub OAuth Apps request scopes during the authorization flow. Zepplin requests:

- **`read:user`**: Read user profile information
- **`user:email`**: Access user email addresses

These are requested dynamically and don't need to be configured in the OAuth App settings.

### 3.2 Optional Enhanced Scopes
For advanced features, you might want to request additional scopes:

- **`read:org`**: Read organization membership (for organization-based package permissions)
- **`public_repo`**: Access public repositories (for automatic package import)

Update the scope in `src/auth/auth_github.zig`:
```zig
.scope = try allocator.dupe(u8, "read:user user:email read:org"),
```

## Step 4: Gather Configuration Values

From your OAuth App settings page, collect:

| Setting | Location | Environment Variable |
|---------|----------|---------------------|
| **Client ID** | OAuth App settings | `GITHUB_CLIENT_ID` |
| **Client Secret** | Generated secret | `GITHUB_CLIENT_SECRET` |

## Step 5: Configure Environment Variables

### 5.1 Production Environment (.env)
```bash
# GitHub OAuth Configuration  
GITHUB_CLIENT_ID=Iv1.1234567890abcdef
GITHUB_CLIENT_SECRET=1234567890abcdef1234567890abcdef12345678

# Application Configuration (if not already set for Azure AD)
REDIRECT_BASE_URL=https://zig.cktech.org
ZEPPLIN_DOMAIN=zig.cktech.org
JWT_SECRET=your_strong_jwt_secret_here
ZEPPLIN_SECRET_KEY=your_strong_app_secret_here
```

### 5.2 Docker Compose
Update your `docker-compose.yml`:

```yaml
services:
  zepplin-registry:
    environment:
      # Azure AD (primary)
      - AZURE_TENANT_ID=${AZURE_TENANT_ID}
      - AZURE_CLIENT_ID=${AZURE_CLIENT_ID}
      - AZURE_CLIENT_SECRET=${AZURE_CLIENT_SECRET}
      
      # GitHub OAuth (secondary)
      - GITHUB_CLIENT_ID=${GITHUB_CLIENT_ID}
      - GITHUB_CLIENT_SECRET=${GITHUB_CLIENT_SECRET}
      
      # Common settings
      - REDIRECT_BASE_URL=${REDIRECT_BASE_URL}
      - JWT_SECRET=${JWT_SECRET}
      - ZEPPLIN_SECRET_KEY=${ZEPPLIN_SECRET_KEY}
```

## Step 6: Test the Integration

### 6.1 Verify Configuration
1. Start your Zepplin registry
2. Navigate to `https://zig.cktech.org/auth`
3. You should see both:
   - **"Sign in with Microsoft"** button (Azure AD)
   - **"Sign in with GitHub"** button (GitHub OAuth)
4. Click **"Sign in with GitHub"**
5. You should be redirected to GitHub for authorization
6. After granting permissions, you should return to Zepplin with a JWT token

### 6.2 Test Both Providers
Verify that both authentication methods work:

1. **Azure AD Flow**:
   - Click "Sign in with Microsoft"
   - Complete Microsoft authentication
   - Verify JWT token contains Microsoft user info

2. **GitHub Flow**:
   - Click "Sign in with GitHub"  
   - Complete GitHub authentication
   - Verify JWT token contains GitHub user info

## Step 7: Troubleshooting

### 7.1 Common Issues

| Error | Cause | Solution |
|-------|-------|----------|
| `redirect_uri_mismatch` | Callback URL doesn't match | Check OAuth App callback URL settings |
| `bad_client_id` | Invalid client ID | Verify `GITHUB_CLIENT_ID` from OAuth App |
| `bad_client_secret` | Invalid client secret | Regenerate and update client secret |
| `Authentication system not configured` | Missing environment variables | Verify GitHub env vars are set |

### 7.2 Debug GitHub OAuth Flow

Enable debug logging:
```bash
ZEPPLIN_LOG_LEVEL=debug
```

Check Zepplin logs for detailed OAuth flow information:
```bash
docker logs zepplin-registry -f
```

### 7.3 Test API Endpoints

Test the GitHub OAuth endpoints manually:

```bash
# Test login initiation
curl -v "https://zig.cktech.org/api/v1/auth/oauth/github/login"

# Should redirect to GitHub with proper parameters
```

## Step 8: Advanced Configuration

### 8.1 Organization-Based Access Control

If you want to restrict access to members of your GitHub organization:

1. **Update OAuth App**: Set it up under your organization
2. **Request `read:org` scope**: Add to the scope in auth_github.zig
3. **Implement organization check**: Add logic in the callback handler

Example scope update:
```zig
// In src/auth/auth_github.zig
.scope = try allocator.dupe(u8, "read:user user:email read:org"),
```

### 8.2 Link Multiple Accounts

Users can link both Microsoft and GitHub accounts to the same Zepplin account:

1. User signs in with Microsoft (creates account)
2. User can later visit account settings and "Link GitHub Account"
3. Both identities are associated with the same user

This is handled by the unified auth system in `src/auth/unified_auth.zig`.

### 8.3 Automatic Package Import

For users who sign in with GitHub, you can automatically discover their Zig packages:

1. Request `public_repo` scope
2. Use GitHub API to find repositories with `build.zig` files
3. Offer to import these as packages

## Step 9: Production Security Checklist

### 9.1 Security Review
- [ ] Client secret stored securely (not in code)
- [ ] HTTPS enabled for callback URLs
- [ ] Callback URLs limited to your domains
- [ ] Different secrets for different environments
- [ ] OAuth App configured with minimal required scopes
- [ ] Regular secret rotation planned

### 9.2 Rate Limiting
GitHub has rate limits for OAuth apps:
- **5,000 requests per hour** per OAuth App
- **1,000 requests per hour** per user per OAuth App

Monitor your usage in the GitHub OAuth App settings.

### 9.3 Webhook Setup (Optional)
For real-time updates when users change their GitHub profile:

1. Go to your OAuth App settings
2. Set up webhooks for user events
3. Update user info in Zepplin when GitHub profile changes

## Step 10: User Experience Optimization

### 10.1 Login Flow Design
Consider the user experience for dual authentication:

1. **Primary**: Show Microsoft login prominently (for enterprise users)
2. **Secondary**: Show GitHub login for developers
3. **Account Linking**: Allow users to connect both accounts
4. **Profile Management**: Let users choose preferred login method

### 10.2 Package Publishing Permissions
Design permissions based on authentication method:

- **Microsoft users**: Full access (enterprise trust)
- **GitHub users**: May require additional verification
- **Linked accounts**: Enhanced trust level

## Step 11: Monitoring and Analytics

### 11.1 Authentication Metrics
Track these metrics:

- Login success/failure rates by provider
- User preference between Microsoft vs GitHub
- Account linking frequency
- Failed authentication attempts

### 11.2 GitHub-Specific Monitoring
- OAuth app rate limit usage
- Most common GitHub organizations
- Repository import success rates

## Support Resources

- [GitHub OAuth Apps Documentation](https://docs.github.com/en/apps/oauth-apps)
- [GitHub API Rate Limiting](https://docs.github.com/en/rest/overview/resources-in-the-rest-api#rate-limiting)
- [GitHub OAuth Scopes](https://docs.github.com/en/apps/oauth-apps/building-oauth-apps/scopes-for-oauth-apps)
- [Zepplin GitHub Issues](https://github.com/your-org/zepplin/issues)

---

**Next Steps**: 
1. Complete both Azure AD and GitHub OAuth setup
2. Test the dual authentication system
3. Configure user account linking
4. Set up monitoring and analytics
5. Deploy to production with `docker-compose up -d`