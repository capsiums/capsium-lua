#!/bin/bash

# Colors for output
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[0;33m'
NC='\033[0m' # No Color

echo -e "${YELLOW}Running tests for Capsium Nginx Reactor${NC}"

# Check if Python is installed
if ! command -v python3 &> /dev/null; then
    echo -e "${RED}Error: Python 3 is required but not installed.${NC}"
    exit 1
fi

# Check if pip is installed
if ! command -v pip3 &> /dev/null; then
    echo -e "${RED}Error: pip3 is required but not installed.${NC}"
    exit 1
fi

# Check if Docker is installed
if ! command -v docker &> /dev/null; then
    echo -e "${RED}Error: Docker is required but not installed.${NC}"
    exit 1
fi

# Check if Docker is running
if ! docker info &> /dev/null; then
    echo -e "${RED}Error: Docker is not running.${NC}"
    exit 1
fi

# Install test dependencies
echo -e "${YELLOW}Installing test dependencies...${NC}"
pip3 install -r tests/requirements.txt

# Run the tests
echo -e "${YELLOW}Running tests...${NC}"
python3 -m pytest tests/ -v --html=test-report.html

# Check if tests passed
if [ $? -eq 0 ]; then
    echo -e "${GREEN}All tests passed!${NC}"
    echo -e "Test report generated at: test-report.html"
else
    echo -e "${RED}Some tests failed. See the test report for details.${NC}"
    echo -e "Test report generated at: test-report.html"
    exit 1
fi
