#!/bin/bash

# Script to package the test Capsium package

# Colors for output
GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m' # No Color

echo "Packaging test Capsium package..."

# Set paths
TEST_PACKAGE_DIR="$(dirname "$0")/fixtures/test-package"
OUTPUT_DIR="$(dirname "$0")/fixtures"
OUTPUT_FILE="$OUTPUT_DIR/test-package-0.1.0.cap"

# Ensure output directory exists
mkdir -p "$OUTPUT_DIR"

# Check if the test package directory exists
if [ ! -d "$TEST_PACKAGE_DIR" ]; then
    echo -e "${RED}Error: Test package directory not found: $TEST_PACKAGE_DIR${NC}"
    exit 1
fi

# Create a temporary directory
TMP_DIR=$(mktemp -d)
echo "Created temporary directory: $TMP_DIR"

# Copy all files to the temporary directory
cp -r "$TEST_PACKAGE_DIR"/* "$TMP_DIR"
echo "Copied files to temporary directory"

# Create the zip file
cd "$TMP_DIR"
zip -r "$OUTPUT_FILE" ./*
if [ $? -eq 0 ]; then
    echo "Created zip file: $OUTPUT_FILE"
else
    echo -e "${RED}Failed to create zip file${NC}"
    rm -rf "$TMP_DIR"
    exit 1
fi

# Clean up
rm -rf "$TMP_DIR"
echo "Cleaned up temporary directory"

# Rename the zip file to .cap if needed
if [[ "$OUTPUT_FILE" != *.cap ]]; then
    mv "$OUTPUT_FILE" "$OUTPUT_FILE.cap"
    OUTPUT_FILE="$OUTPUT_FILE.cap"
fi

# Check if the package was created successfully
if [ -f "$OUTPUT_FILE" ]; then
    echo -e "${GREEN}Package created successfully: $OUTPUT_FILE${NC}"
else
    echo -e "${RED}Failed to create package${NC}"
    exit 1
fi

echo "Done!"
