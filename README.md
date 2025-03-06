# Capsium Nginx Reactor

A Lua-based Nginx plugin for serving Capsium packages.

## Overview

The Capsium Nginx Reactor is an Nginx plugin that allows you to serve Capsium packages directly from Nginx. It extracts Capsium packages, resolves routes according to the package's routes.json file, and serves the content.

## Features

- Extracts and serves Capsium packages
- Resolves routes based on routes.json
- Automatically generates routes if routes.json is missing
- Provides HTTP API for introspection
- Supports caching for improved performance
- Docker-ready for easy deployment

## Requirements

- Nginx with Lua support (OpenResty recommended)
- Lua 5.1 or later
- LuaRocks for dependency management
- Docker (optional, for containerized deployment)

## Installation

### Using Docker (Recommended)

1. Clone the repository:
   ```bash
   git clone https://github.com/yourusername/capsium-nginx.git
   cd capsium-nginx
   ```

2. Place your Capsium packages in the `test/fixtures` directory.

3. Build and run the Docker container:
   ```bash
   docker-compose up -d
   ```

4. Access your Capsium packages at `http://localhost:8080/capsium/your-package-name/`.

### Manual Installation

1. Install OpenResty or Nginx with Lua support.

2. Install Lua dependencies:
   ```bash
   luarocks install lua-cjson
   luarocks install luafilesystem
   luarocks install brimworks-zip
   ```

3. Copy the Lua modules to your Nginx Lua path:
   ```bash
   mkdir -p /etc/nginx/lua/capsium
   cp lua/capsium/* /etc/nginx/lua/capsium/
   ```

4. Copy the Nginx configuration files:
   ```bash
   cp nginx/conf.d/capsium.conf /etc/nginx/conf.d/
   ```

5. Update your main Nginx configuration to include Lua settings:
   ```nginx
   # Lua settings
   lua_package_path "/etc/nginx/lua/?.lua;;";
   lua_shared_dict capsium_cache 10m;
   ```

6. Create directories for Capsium packages:
   ```bash
   mkdir -p /var/lib/capsium/packages
   mkdir -p /var/lib/capsium/extracted
   mkdir -p /var/lib/capsium/static
   ```

7. Restart Nginx:
   ```bash
   nginx -s reload
   ```

## Usage

### Serving Capsium Packages

1. Place your Capsium packages (*.cap files) in the `/var/lib/capsium/packages` directory.

2. Access your packages at `http://your-server/capsium/your-package-name/`.

### API Endpoints

The Capsium Nginx Reactor provides several API endpoints for introspection:

- `/api/v1/introspect/metadata` - Returns metadata for all packages
- `/api/v1/introspect/routes` - Returns routes for all packages
- `/api/v1/introspect/content-hashes` - Returns content hashes for all packages
- `/api/v1/introspect/content-validity` - Returns content validity for all packages

## Configuration

The Capsium Nginx Reactor supports a flexible configuration system that allows you to customize how packages are mounted and served.

### Configuration File

The configuration file is a JSON file that can be placed in one of the following locations (in order of precedence):

1. Path specified by the `CAPSIUM_CONFIG_PATH` environment variable
2. `/etc/capsium/config.json`
3. `/etc/capsium/nginx/config.json`
4. `/var/lib/capsium/config.json`
5. `./config.json`

### Basic Configuration

A basic configuration file looks like this:

```json
{
  "package_dir": "/var/lib/capsium/packages",
  "extract_dir": "/var/lib/capsium/extracted",
  "cache_enabled": true,
  "cache_ttl": 3600,
  "log_level": "info",
  "packages_config_dir": "/etc/capsium/packages"
}
```

### Package Mount Configuration

You can configure how packages are mounted using the `mounts` array in the configuration file:

```json
{
  "mounts": [
    {
      "package": "package-name-1.0.0.cap",
      "path": "/custom/path",
      "domain": "example.com",
      "port": 80,
      "options": {
        "cache_ttl": 7200,
        "headers": {
          "X-Frame-Options": "SAMEORIGIN",
          "X-Content-Type-Options": "nosniff"
        }
      }
    }
  ]
}
```

### Per-Package Configuration

You can also configure packages individually by placing a JSON file in the `packages_config_dir` directory:

```
/etc/capsium/packages/
  ├── package-name-1.0.0.json
  ├── another-package-2.0.0.json
  └── ...
```

Each file should contain the configuration for that package:

```json
{
  "path": "/custom/path",
  "domain": "custom.example.com",
  "port": 8443,
  "https": true,
  "options": {
    "cache_ttl": 7200,
    "headers": {
      "X-Frame-Options": "SAMEORIGIN"
    },
    "cors": {
      "allowed_origins": ["https://example.com"],
      "allowed_methods": ["GET", "POST"]
    }
  }
}
```

### Configuration Options

The following options are available:

- `package_dir`: Directory where Capsium packages are stored
- `extract_dir`: Directory where packages are extracted
- `cache_enabled`: Whether to enable caching
- `cache_ttl`: Cache time-to-live in seconds
- `log_level`: Logging level (debug, info, warn, error)
- `packages_config_dir`: Directory for per-package configuration files
- `mounts`: Array of package mount configurations

Each mount configuration can include:

- `package`: Name of the Capsium package
- `path`: Path where the package should be mounted
- `domain`: Domain name for the package (for virtual hosting)
- `port`: Port number for the package
- `https`: Whether to use HTTPS
- `options`: Additional options for the package
  - `cache_ttl`: Cache time-to-live for this package
  - `headers`: Custom HTTP headers to add to responses
  - `cors`: Cross-Origin Resource Sharing configuration

## Testing

The Capsium Nginx Reactor includes a comprehensive testing framework using pytest. The tests verify the functionality of the reactor, including package extraction, route resolution, content serving, and API endpoints.

### Running Tests

To run the tests, simply execute the `run_tests.sh` script:

```bash
./run_tests.sh
```

This script will:
1. Check for required dependencies (Python, pip, Docker)
2. Install the necessary Python packages
3. Build the Docker image
4. Run the container with the test Capsium packages
5. Execute the tests
6. Generate an HTML report of the test results
7. Clean up by stopping and removing the container

### Test Coverage

The tests cover:

1. **Basic Functionality**:
   - Server is running and responding to requests
   - Static content is served correctly
   - Nginx headers are set properly

2. **API Endpoints**:
   - `/api/v1/introspect/metadata` returns package metadata
   - `/api/v1/introspect/routes` returns package routes
   - `/api/v1/introspect/content-hashes` returns content hashes
   - `/api/v1/introspect/content-validity` returns validity info

3. **Package Handling**:
   - Capsium packages can be accessed
   - CSS and JavaScript files are served with correct MIME types
   - Different index routes work as expected
   - Nonexistent packages and files return 404

### Manual Testing

You can also test the Capsium Nginx Reactor manually:

1. Place a Capsium package in the `test/fixtures` directory.

2. Start the Docker container:
   ```bash
   docker-compose up -d
   ```

3. Access the package at `http://localhost:8080/capsium/your-package-name/`.

## License

This project is licensed under the MIT License - see the LICENSE file for details.
