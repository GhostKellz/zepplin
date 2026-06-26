#!/bin/bash

# Test script for package upload/download flow
# Usage: ./test_package_flow.sh [port]

PORT=${1:-8080}
BASE_URL="http://localhost:$PORT"

echo "📦 Testing Zepplin Package Flow on $BASE_URL"
echo "============================================"

# Create a test package file
echo "📝 Creating test package..."
mkdir -p test_package
echo "const std = @import(\"std\");" > test_package/main.zig
echo '{"name": "test-package", "version": "1.0.0"}' > test_package/package.json
tar -czf test-package-1.0.0.tar.gz test_package/
echo "✅ Created test-package-1.0.0.tar.gz"

# Test 1: Register user and get token
echo ""
echo "👤 Test 1: Register user for upload"
REGISTER_RESPONSE=$(curl -s -w "\nHTTP_CODE:%{http_code}" \
  -X POST \
  -H "Content-Type: application/json" \
  -d '{"username":"testdev","email":"test@dev.com","password":"testpass123"}' \
  "$BASE_URL/api/v1/auth/register" 2>/dev/null)

HTTP_CODE=$(echo "$REGISTER_RESPONSE" | grep "HTTP_CODE:" | cut -d: -f2)
RESPONSE_BODY=$(echo "$REGISTER_RESPONSE" | grep -v "HTTP_CODE:")

if [[ "$HTTP_CODE" == "201" ]]; then
    echo "✅ User registration successful (HTTP $HTTP_CODE)"
    TOKEN=$(echo "$RESPONSE_BODY" | grep -o '"token":"[^"]*"' | cut -d'"' -f4)
    echo "🔑 Token: ${TOKEN:0:20}..."
else
    echo "❌ User registration failed (HTTP $HTTP_CODE)"
    echo "Response: $RESPONSE_BODY"
fi

echo ""

# Test 2: Upload package
if [[ -n "$TOKEN" ]]; then
    echo "📤 Test 2: Upload package"
    UPLOAD_RESPONSE=$(curl -s -w "\nHTTP_CODE:%{http_code}" \
      -X POST \
      -H "Authorization: Bearer $TOKEN" \
      -F "owner=testdev" \
      -F "repo=test-package" \
      -F "tag_name=1.0.0" \
      -F "name=Test Package" \
      -F "body=A simple test package for Zepplin" \
      -F "draft=false" \
      -F "prerelease=false" \
      -F "file=@test-package-1.0.0.tar.gz" \
      "$BASE_URL/api/v1/packages/testdev/test-package/releases" 2>/dev/null)
    
    HTTP_CODE=$(echo "$UPLOAD_RESPONSE" | grep "HTTP_CODE:" | cut -d: -f2)
    RESPONSE_BODY=$(echo "$UPLOAD_RESPONSE" | grep -v "HTTP_CODE:")
    
    if [[ "$HTTP_CODE" == "201" ]]; then
        echo "✅ Package upload successful (HTTP $HTTP_CODE)"
        echo "📦 Release created: $RESPONSE_BODY"
    else
        echo "❌ Package upload failed (HTTP $HTTP_CODE)"
        echo "Response: $RESPONSE_BODY"
    fi
else
    echo "⚠️  Test 2: Skipped (no token available)"
fi

echo ""

# Test 3: Download package
echo "📥 Test 3: Download package"
DOWNLOAD_RESPONSE=$(curl -s -w "\nHTTP_CODE:%{http_code}" \
  -L \
  -o "downloaded-package.zpkg" \
  "$BASE_URL/api/v1/packages/testdev/test-package/download/1.0.0" 2>/dev/null)

HTTP_CODE=$(echo "$DOWNLOAD_RESPONSE" | grep "HTTP_CODE:" | cut -d: -f2)

if [[ "$HTTP_CODE" == "200" && -f "downloaded-package.zpkg" ]]; then
    FILE_SIZE=$(stat -c%s "downloaded-package.zpkg" 2>/dev/null || stat -f%z "downloaded-package.zpkg" 2>/dev/null)
    echo "✅ Package download successful (HTTP $HTTP_CODE)"
    echo "📁 Downloaded file size: $FILE_SIZE bytes"
    
    # Verify file content
    echo "🔍 Verifying downloaded content..."
    if file downloaded-package.zpkg | grep -q "gzip"; then
        echo "✅ Downloaded file appears to be a valid archive"
    else
        echo "⚠️  Downloaded file may not be a valid archive"
    fi
else
    echo "❌ Package download failed (HTTP $HTTP_CODE)"
fi

echo ""

# Test 4: Get package info
echo "📋 Test 4: Get package information"
INFO_RESPONSE=$(curl -s -w "\nHTTP_CODE:%{http_code}" \
  "$BASE_URL/api/v1/packages/testdev/test-package" 2>/dev/null)

HTTP_CODE=$(echo "$INFO_RESPONSE" | grep "HTTP_CODE:" | cut -d: -f2)
RESPONSE_BODY=$(echo "$INFO_RESPONSE" | grep -v "HTTP_CODE:")

if [[ "$HTTP_CODE" == "200" ]]; then
    echo "✅ Package info retrieved successfully (HTTP $HTTP_CODE)"
    echo "📊 Package info: $RESPONSE_BODY"
else
    echo "❌ Package info retrieval failed (HTTP $HTTP_CODE)"
    echo "Response: $RESPONSE_BODY"
fi

echo ""

# Test 5: List releases
echo "📜 Test 5: List package releases"
RELEASES_RESPONSE=$(curl -s -w "\nHTTP_CODE:%{http_code}" \
  "$BASE_URL/api/v1/packages/testdev/test-package/releases" 2>/dev/null)

HTTP_CODE=$(echo "$RELEASES_RESPONSE" | grep "HTTP_CODE:" | cut -d: -f2)
RESPONSE_BODY=$(echo "$RELEASES_RESPONSE" | grep -v "HTTP_CODE:")

if [[ "$HTTP_CODE" == "200" ]]; then
    echo "✅ Releases listed successfully (HTTP $HTTP_CODE)"
    echo "📋 Releases: $RESPONSE_BODY"
else
    echo "❌ Releases listing failed (HTTP $HTTP_CODE)"
    echo "Response: $RESPONSE_BODY"
fi

echo ""

# Cleanup
echo "🧹 Cleaning up test files..."
rm -rf test_package test-package-1.0.0.tar.gz
if [[ -f "downloaded-package.zpkg" ]]; then
    rm downloaded-package.zpkg
fi

echo ""
echo "🏁 Package flow test complete!"
echo ""
echo "Summary:"
echo "- User registration: $(if [[ -n "$TOKEN" ]]; then echo "✅ Success"; else echo "❌ Failed"; fi)"
echo "- Package upload: $(if [[ "$HTTP_CODE" == "201" ]]; then echo "✅ Success"; else echo "❌ Failed/Skipped"; fi)"
echo "- Package download: $(if [[ -f "downloaded-package.zpkg" ]]; then echo "✅ Success"; else echo "❌ Failed"; fi)"
echo "- Package info: Available via API"
echo "- Release listing: Available via API"