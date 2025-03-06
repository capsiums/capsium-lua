#!/bin/bash

# Test script for Capsium Nginx Reactor

# Colors for output
GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m' # No Color

# Function to check if a URL returns a 200 status code
check_url() {
    local url=$1
    local expected_status=$2
    local description=$3

    echo -n "Testing $description... "

    # Make the request and get the status code
    status=$(curl -s -o /dev/null -w "%{http_code}" $url)

    if [ "$status" -eq "$expected_status" ]; then
        echo -e "${GREEN}PASS${NC} (Status: $status)"
        return 0
    else
        echo -e "${RED}FAIL${NC} (Expected: $expected_status, Got: $status)"
        return 1
    fi
}

# Start the Docker container
echo "Starting Capsium Nginx container..."
docker-compose up -d

# Wait for the container to start
echo "Waiting for container to start..."
sleep 5

# Test the Capsium package
echo "Testing Capsium package access..."
check_url "http://localhost:8080/capsium/mn-samples-iso-0.1.0/index.html" 200 "Access to index.html"
check_url "http://localhost:8080/capsium/mn-samples-iso-0.1.0/" 200 "Access to root path"
check_url "http://localhost:8080/capsium/mn-samples-iso-0.1.0/nonexistent.html" 404 "Access to nonexistent file (should 404)"

# Test the API endpoints
echo "Testing API endpoints..."
check_url "http://localhost:8080/api/v1/introspect/metadata" 200 "Metadata API"
check_url "http://localhost:8080/api/v1/introspect/routes" 200 "Routes API"
check_url "http://localhost:8080/api/v1/introspect/content-hashes" 200 "Content hashes API"
check_url "http://localhost:8080/api/v1/introspect/content-validity" 200 "Content validity API"
check_url "http://localhost:8080/api/v1/introspect/nonexistent" 404 "Nonexistent API endpoint (should 404)"

# Stop the Docker container
echo "Stopping Capsium Nginx container..."
docker-compose down

echo "Tests completed."
