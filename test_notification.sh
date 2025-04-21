#!/usr/bin/env bash
# test_notification.sh
# Test script for webhook notifications in backup system

set -euo pipefail

# Source the environment file if it exists
ENV_FILE="${BACKUP_ENV_FILE:-$HOME/.backup_env}"
if [[ -f "$ENV_FILE" ]]; then
  source "$ENV_FILE"
fi

# Check if webhook URL is set
if [[ -z "${WEBHOOK_URL:-}" ]]; then
  echo "Error: WEBHOOK_URL is not set. Please set it in $ENV_FILE or as an environment variable."
  echo "Example: export WEBHOOK_URL='https://discord.com/api/webhooks/your-webhook-url'"
  exit 1
fi

# Function to test webhook notifications
test_notification() {
  local message="$1"
  local expected_status="$2"
  
  echo -e "\n=== Testing notification with message: '$message' ==="
  
  # Capture webhook response for error logging
  local response
  local status_code
  
  # Check if it's a Discord webhook
  if [[ "$WEBHOOK_URL" == *"discord.com"* ]]; then
    # Use Discord webhook format
    response=$(curl -s -w "\n%{http_code}" -X POST -H 'Content-Type: application/json' \
      -d "{\"content\":\"$message\"}" "$WEBHOOK_URL")
  else
    # Use generic/Slack webhook format
    response=$(curl -s -w "\n%{http_code}" -X POST -H 'Content-Type: application/json' \
      -d "{\"text\":\"$message\"}" "$WEBHOOK_URL")
  fi
  
  status_code=$(echo "$response" | tail -n1)
  response_body=$(echo "$response" | sed '$d')
  
  echo "Status code: $status_code"
  echo "Response: $response_body"
  
  # Check if the result matches the expected status
  if [[ "$expected_status" == "success" && "$status_code" == 2* ]]; then
    echo "✅ TEST PASSED: Successfully sent notification"
    return 0
  elif [[ "$expected_status" == "fail" && "$status_code" != 2* ]]; then
    echo "✅ TEST PASSED: Failed as expected"
    return 0
  else
    echo "❌ TEST FAILED: Unexpected result"
    return 1
  fi
}

# Run various tests
echo "Starting webhook notification tests..."

# Test 1: Valid message
test_notification "🧪 Test notification: This is a test message from backup system" "success"

# Test 2: Empty message (should fail with Discord)
test_notification "" "fail"

# Test 3: Error simulation
test_notification "❌ Error simulation: Backup failed at $(date -u +"%Y-%m-%dT%H%M%SZ")" "success"

echo -e "\n=== Test summary ==="
echo "Make sure you check your webhook destination to verify messages were received"
echo "To use this in your backup system, ensure WEBHOOK_URL is properly set in your environment"
echo "Done testing webhook notifications." 