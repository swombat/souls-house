#!/bin/bash

# Integrated test runner for Playwright Component Tests with Rails backend
# This script handles the entire test flow automatically

set -e  # Exit on error

echo "🚀 Starting Playwright Component Tests with Real Rails Backend..."

# Colors for output
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Set environment variables
export RAILS_ENV=test
export NODE_ENV=test

# Function to cleanup on exit
cleanup() {
    echo -e "\n${YELLOW}🧹 Cleaning up...${NC}"
    
    # Kill Rails server if it's running
    if [ ! -z "$RAILS_PID" ]; then
        echo "Stopping Rails server (PID: $RAILS_PID)..."
        kill -9 $RAILS_PID 2>/dev/null || true
    fi
    
    # Also kill any orphaned Rails servers on port 3200
    lsof -ti:3200 | xargs kill -9 2>/dev/null || true
    
    # Clean up test database after tests
    echo "🗑️  Cleaning up test database..."
    rails db:drop RAILS_ENV=test 2>/dev/null || true
    rails db:create RAILS_ENV=test
    rails db:migrate RAILS_ENV=test
    
    echo -e "${GREEN}✅ Cleanup complete - test database reset${NC}"
}

# Set trap to cleanup on exit (including Ctrl+C)
trap cleanup EXIT INT TERM

echo "📦 Preparing test database..."

# Drop, create, migrate and seed the test database
rails db:drop RAILS_ENV=test 2>/dev/null || true
rails db:create RAILS_ENV=test
rails db:migrate RAILS_ENV=test

echo "🌱 Loading test fixtures..."
rails db:fixtures:load RAILS_ENV=test

echo "🚀 Starting Rails server on port 3200..."

# Start Rails server in background and capture its PID
rails server -e test -p 3200 &
RAILS_PID=$!

echo "Rails server started with PID: $RAILS_PID"

# Wait for Rails server to be ready
echo "⏳ Waiting for Rails server to be ready..."
MAX_ATTEMPTS=30
ATTEMPT=0

while [ $ATTEMPT -lt $MAX_ATTEMPTS ]; do
    if curl -s -o /dev/null -w "%{http_code}" http://localhost:3200 | grep -q "200\|302"; then
        echo -e "${GREEN}✅ Rails server is ready!${NC}"
        break
    fi
    
    ATTEMPT=$((ATTEMPT + 1))
    if [ $ATTEMPT -eq $MAX_ATTEMPTS ]; then
        echo -e "${RED}❌ Rails server failed to start after 30 seconds${NC}"
        exit 1
    fi
    
    echo -n "."
    sleep 1
done

echo ""
echo "🧪 Running Playwright Component Tests..."
echo "----------------------------------------"

# Check if UI mode was requested
if [[ "$1" == "--ui" ]]; then
    echo "Opening Playwright UI..."
    bun x playwright test -c playwright-ct.config.js --ui
    TEST_EXIT_CODE=$?
else
    # Run the Playwright tests and capture the exit code
    bun x playwright test -c playwright-ct.config.js
    TEST_EXIT_CODE=$?
fi

echo "----------------------------------------"

# Report results
if [ $TEST_EXIT_CODE -eq 0 ]; then
    echo -e "${GREEN}✅ All tests passed successfully!${NC}"
else
    echo -e "${RED}❌ Some tests failed (exit code: $TEST_EXIT_CODE)${NC}"
fi

# Exit with the same code as the tests
exit $TEST_EXIT_CODE
