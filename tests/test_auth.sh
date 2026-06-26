#!/bin/bash

# Simple auth flow test script for Zepplin
# Usage: ./test_auth.sh [port]

PORT=${1:-8080}
BASE_URL="http://localhost:$PORT"

echo "🧪 Testing Zepplin Auth Flow on $BASE_URL"
echo "========================================="

# Test 1: Register a new user
echo "📝 Test 1: Register new user"
REGISTER_RESPONSE=$(curl -s -w "\nHTTP_CODE:%{http_code}" \
  -X POST \
  -H "Content-Type: application/json" \
  -d '{"username":"testuser","email":"test@example.com","password":"testpass123"}' \
  "$BASE_URL/api/v1/auth/register" 2>/dev/null)

HTTP_CODE=$(echo "$REGISTER_RESPONSE" | grep "HTTP_CODE:" | cut -d: -f2)
RESPONSE_BODY=$(echo "$REGISTER_RESPONSE" | grep -v "HTTP_CODE:")

if [[ "$HTTP_CODE" == "201" ]]; then
    echo "✅ Registration successful (HTTP $HTTP_CODE)"
    TOKEN=$(echo "$RESPONSE_BODY" | grep -o '"token":"[^"]*"' | cut -d'"' -f4)
    echo "🔑 Token: $TOKEN"
else
    echo "❌ Registration failed (HTTP $HTTP_CODE)"
    echo "Response: $RESPONSE_BODY"
fi

echo ""

# Test 2: Login with the same user
echo "🔐 Test 2: Login with user"
LOGIN_RESPONSE=$(curl -s -w "\nHTTP_CODE:%{http_code}" \
  -X POST \
  -H "Content-Type: application/json" \
  -d '{"username":"testuser","password":"testpass123"}' \
  "$BASE_URL/api/v1/auth/login" 2>/dev/null)

HTTP_CODE=$(echo "$LOGIN_RESPONSE" | grep "HTTP_CODE:" | cut -d: -f2)
RESPONSE_BODY=$(echo "$LOGIN_RESPONSE" | grep -v "HTTP_CODE:")

if [[ "$HTTP_CODE" == "200" ]]; then
    echo "✅ Login successful (HTTP $HTTP_CODE)"
    TOKEN=$(echo "$RESPONSE_BODY" | grep -o '"token":"[^"]*"' | cut -d'"' -f4)
    echo "🔑 Token: $TOKEN"
else
    echo "❌ Login failed (HTTP $HTTP_CODE)"
    echo "Response: $RESPONSE_BODY"
fi

echo ""

# Test 3: Test authenticated endpoint
if [[ -n "$TOKEN" ]]; then
    echo "👤 Test 3: Get user profile with token"
    PROFILE_RESPONSE=$(curl -s -w "\nHTTP_CODE:%{http_code}" \
      -H "Authorization: Bearer $TOKEN" \
      "$BASE_URL/api/v1/auth/me" 2>/dev/null)
    
    HTTP_CODE=$(echo "$PROFILE_RESPONSE" | grep "HTTP_CODE:" | cut -d: -f2)
    RESPONSE_BODY=$(echo "$PROFILE_RESPONSE" | grep -v "HTTP_CODE:")
    
    if [[ "$HTTP_CODE" == "200" ]]; then
        echo "✅ Profile access successful (HTTP $HTTP_CODE)"
        echo "👤 Profile: $RESPONSE_BODY"
    else
        echo "❌ Profile access failed (HTTP $HTTP_CODE)"
        echo "Response: $RESPONSE_BODY"
    fi
else
    echo "⚠️  Test 3: Skipped (no token available)"
fi

echo ""

# Test 4: Test without authentication
echo "🚫 Test 4: Try to access profile without token"
NO_AUTH_RESPONSE=$(curl -s -w "\nHTTP_CODE:%{http_code}" \
  "$BASE_URL/api/v1/auth/me" 2>/dev/null)

HTTP_CODE=$(echo "$NO_AUTH_RESPONSE" | grep "HTTP_CODE:" | cut -d: -f2)
RESPONSE_BODY=$(echo "$NO_AUTH_RESPONSE" | grep -v "HTTP_CODE:")

if [[ "$HTTP_CODE" == "401" ]]; then
    echo "✅ Properly rejected unauthorized access (HTTP $HTTP_CODE)"
else
    echo "❌ Should have rejected unauthorized access (HTTP $HTTP_CODE)"
    echo "Response: $RESPONSE_BODY"
fi

echo ""
echo "🏁 Auth flow test complete!"