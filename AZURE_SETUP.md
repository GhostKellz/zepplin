# Azure AD (Microsoft Entra ID) Setup for Zepplin Registry

This guide walks you through setting up Microsoft Entra ID (formerly Azure AD) authentication for your Zepplin package registry deployment.

## Prerequisites

- Access to Azure Portal with permissions to create App Registrations
- Admin access to your Azure AD tenant (or ability to request admin consent)
- Your Zepplin registry domain (e.g., `zig.cktech.org`)

## Step 1: Create App Registration

### 1.1 Navigate to App Registrations
1. Go to [Azure Portal](https://portal.azure.com)
2. Navigate to **Azure Active Directory** (or **Microsoft Entra ID**)
3. Click **App registrations** in the left sidebar
4. Click **+ New registration**

### 1.2 Configure Basic Settings
Fill out the registration form:

- **Name**: `Zepplin Package Registry`
- **Supported account types**: Choose one of:
  - **Single tenant**: Only users in your organization
  - **Multitenant**: Users in any organization (recommended for public registry)
- **Redirect URI**: 
  - Platform: **Web**
  - URL: `https://zig.cktech.org/api/v1/auth/oidc/microsoft/callback`

Click **Register**.

## Step 2: Configure Authentication Settings

### 2.1 Update Authentication
1. In your new app registration, go to **Authentication**
2. Under **Implicit grant and hybrid flows**, check:
   - ✅ **ID tokens (used for implicit and hybrid flows)**
3. Under **Advanced settings**:
   - **Allow public client flows**: **No**
   - **Treat application as a public client**: **No**
4. Click **Save**

### 2.2 Add Additional Redirect URIs (Optional)
If you need development/testing URLs:
- `http://localhost:8080/api/v1/auth/oidc/microsoft/callback` (for local development)
- `https://staging.zig.cktech.org/api/v1/auth/oidc/microsoft/callback` (for staging)

## Step 3: Configure API Permissions

### 3.1 Add Microsoft Graph Permissions
1. Go to **API permissions**
2. Click **+ Add a permission**
3. Select **Microsoft Graph**
4. Choose **Delegated permissions**
5. Add these permissions:
   - ✅ **User.Read** (Read user profile)
   - ✅ **openid** (Sign users in)
   - ✅ **profile** (View users' basic profile)
   - ✅ **email** (View users' email address)

### 3.2 Grant Admin Consent
1. Click **Grant admin consent for [Your Organization]**
2. Click **Yes** when prompted
3. Verify all permissions show **Granted for [Your Organization]**

## Step 4: Create Client Secret

### 4.1 Generate Secret
1. Go to **Certificates & secrets**
2. Click **+ New client secret**
3. Configure the secret:
   - **Description**: `Zepplin Registry Production`
   - **Expires**: **24 months** (recommended) or **Custom** for longer
4. Click **Add**
5. **⚠️ IMPORTANT**: Copy the **Value** immediately - you won't be able to see it again!

### 4.2 Security Best Practices
- Store the client secret securely (use Azure Key Vault, Docker secrets, or similar)
- Never commit secrets to version control
- Rotate secrets before expiration
- Use different secrets for different environments (dev/staging/prod)

## Step 5: Configure Branding (Optional)

### 5.1 Update Branding
1. Go to **Branding & properties**
2. Update these fields:
   - **Name**: `Zepplin Package Registry`
   - **Logo**: Upload your Zepplin logo (240x240px recommended)
   - **Home page URL**: `https://zig.cktech.org`
   - **Privacy statement URL**: `https://zig.cktech.org/privacy`
   - **Terms of service URL**: `https://zig.cktech.org/terms`

## Step 6: Gather Configuration Values

From your App Registration **Overview** page, collect:

| Setting | Location | Environment Variable |
|---------|----------|---------------------|
| **Application (client) ID** | Overview page | `AZURE_CLIENT_ID` |
| **Directory (tenant) ID** | Overview page | `AZURE_TENANT_ID` |
| **Client Secret Value** | Certificates & secrets | `AZURE_CLIENT_SECRET` |

## Step 7: Configure Environment Variables

### 7.1 Production Environment (.env)
```bash
# Azure AD Configuration
AZURE_TENANT_ID=12345678-1234-1234-1234-123456789012
AZURE_CLIENT_ID=87654321-4321-4321-4321-210987654321
AZURE_CLIENT_SECRET=your_client_secret_value_here

# Application Configuration
REDIRECT_BASE_URL=https://zig.cktech.org
ZEPPLIN_DOMAIN=zig.cktech.org
JWT_SECRET=your_strong_jwt_secret_here
ZEPPLIN_SECRET_KEY=your_strong_app_secret_here
```

### 7.2 Docker Compose
Update your `docker-compose.yml`:

```yaml
services:
  zepplin-registry:
    environment:
      - AZURE_TENANT_ID=${AZURE_TENANT_ID}
      - AZURE_CLIENT_ID=${AZURE_CLIENT_ID}
      - AZURE_CLIENT_SECRET=${AZURE_CLIENT_SECRET}
      - REDIRECT_BASE_URL=${REDIRECT_BASE_URL}
      - JWT_SECRET=${JWT_SECRET}
      - ZEPPLIN_SECRET_KEY=${ZEPPLIN_SECRET_KEY}
```

## Step 8: Test the Integration

### 8.1 Verify Configuration
1. Start your Zepplin registry
2. Navigate to `https://zig.cktech.org/auth`
3. Click **"Sign in with Microsoft"**
4. You should be redirected to Microsoft login
5. After successful login, you should return to Zepplin with a JWT token

### 8.2 Troubleshooting

**Common Issues:**

| Error | Cause | Solution |
|-------|-------|----------|
| `AADSTS50011: redirect_uri_mismatch` | Redirect URI doesn't match | Double-check redirect URI in app registration |
| `AADSTS700016: Invalid client secret` | Wrong client secret | Regenerate and update client secret |
| `AADSTS90002: Tenant not found` | Invalid tenant ID | Verify `AZURE_TENANT_ID` from Overview page |
| `Authentication system not configured` | Missing environment variables | Verify all required env vars are set |

**Debug Logs:**
Enable debug logging by setting `ZEPPLIN_LOG_LEVEL=debug` to see detailed OAuth flow information.

## Step 9: Production Security Checklist

### 9.1 Security Review
- [ ] Client secret stored securely (not in code)
- [ ] HTTPS enabled for all redirect URIs
- [ ] Admin consent granted for required permissions
- [ ] Different secrets for different environments
- [ ] Redirect URIs limited to your domains only
- [ ] Application configured as confidential client
- [ ] Strong JWT secret generated
- [ ] Regular secret rotation planned

### 9.2 Monitoring
- Set up alerts for authentication failures
- Monitor app registration certificate/secret expiration
- Review sign-in logs in Azure AD regularly

## Step 10: Advanced Configuration

### 10.1 Custom Claims (Optional)
To get additional user information, you can configure optional claims:

1. Go to **Token configuration**
2. Click **+ Add optional claim**
3. Select token type: **ID**
4. Add claims like:
   - `family_name`
   - `given_name`
   - `preferred_username`
   - `picture`

### 10.2 Conditional Access (Enterprise)
For enterprise deployments, consider setting up Conditional Access policies:
- Require MFA for package publishing
- Restrict access to specific IP ranges
- Require compliant devices

### 10.3 Application Roles (Advanced)
To implement role-based access control:

1. Go to **App roles**
2. Create roles like:
   - `PackagePublisher`
   - `Admin`
   - `ReadOnly`
3. Assign users to roles in **Enterprise Applications**

## Support

If you encounter issues:

1. Check the [Zepplin GitHub Issues](https://github.com/your-org/zepplin/issues)
2. Review Azure AD sign-in logs in the Azure Portal
3. Enable debug logging in Zepplin for detailed error messages
4. Consult the [Microsoft identity platform documentation](https://docs.microsoft.com/en-us/azure/active-directory/develop/)

---

**Next Steps**: After completing Azure AD setup, consider setting up [GitHub OAuth](./GITHUB_OAUTH_SETUP.md) as an additional authentication option.