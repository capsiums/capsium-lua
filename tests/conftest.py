import os
import pytest
import docker
import time
import requests
from urllib.parse import urljoin

@pytest.fixture(scope="session")
def docker_client():
    return docker.from_env()

@pytest.fixture(scope="session")
def capsium_container(docker_client):
    # Build the image
    print("Building Capsium Nginx Docker image...")
    image, _ = docker_client.images.build(
        path=os.path.abspath(os.path.join(os.path.dirname(__file__), "..")),
        tag="capsium-nginx:test"
    )

    # Create test config directory
    test_config_dir = os.path.abspath(os.path.join(os.path.dirname(__file__), "test_config"))
    os.makedirs(test_config_dir, exist_ok=True)

    # Create test config file
    test_config_file = os.path.join(test_config_dir, "config.json")
    with open(test_config_file, "w") as f:
        f.write('''{
  "package_dir": "/var/lib/capsium/packages",
  "extract_dir": "/var/lib/capsium/extracted",
  "cache_enabled": true,
  "cache_ttl": 3600,
  "log_level": "info",
  "packages_config_dir": "/etc/capsium/packages",
  "mounts": [
    {
      "package": "test-package-0.1.0.cap",
      "path": "/app",
      "domain": "example.com",
      "port": 80,
      "options": {
        "cache_ttl": 7200,
        "headers": {
          "X-Test-Header": "test-value",
          "X-Content-Type-Options": "nosniff"
        }
      }
    }
  ]
}''')

    # Create test package config directory
    test_pkg_config_dir = os.path.join(test_config_dir, "packages")
    os.makedirs(test_pkg_config_dir, exist_ok=True)

    # Create test package config file
    test_pkg_config_file = os.path.join(test_pkg_config_dir, "test-package-0.1.0.json")
    with open(test_pkg_config_file, "w") as f:
        f.write('''{
  "path": "/custom/path",
  "domain": "custom.example.com",
  "port": 8443,
  "https": true,
  "options": {
    "cache_ttl": 7200,
    "headers": {
      "X-Custom-Header": "custom-value"
    }
  }
}''')

    # Run the container
    print("Running Capsium Nginx container...")
    container = docker_client.containers.run(
        "capsium-nginx:test",
        detach=True,
        ports={'80/tcp': 8080},
        volumes={
            os.path.abspath(os.path.join(os.path.dirname(__file__), "../test/fixtures")):
            {'bind': '/var/lib/capsium/packages', 'mode': 'ro'},
            test_config_dir:
            {'bind': '/etc/capsium', 'mode': 'ro'}
        },
        environment={
            'CAPSIUM_CONFIG_PATH': '/etc/capsium/config.json'
        },
        name="capsium-nginx-test"
    )

    # Wait for container to be ready
    print("Waiting for container to start...")
    time.sleep(5)

    # Check if container is running
    container.reload()
    assert container.status == "running"

    # Check if nginx is responding
    max_retries = 10
    retry_delay = 1
    for i in range(max_retries):
        try:
            response = requests.get("http://localhost:8080/")
            if response.status_code == 200:
                break
        except requests.exceptions.ConnectionError:
            pass

        print(f"Waiting for nginx to respond (attempt {i+1}/{max_retries})...")
        time.sleep(retry_delay)

    yield container

    # Cleanup
    print("Stopping and removing Capsium Nginx container...")
    container.stop()
    container.remove()

@pytest.fixture(scope="session")
def base_url():
    return "http://localhost:8080"

@pytest.fixture(scope="session")
def api_client(base_url):
    class ApiClient:
        def __init__(self, base_url):
            self.base_url = base_url

        def get(self, path, headers=None, **kwargs):
            if headers is None:
                headers = {}
            return requests.get(urljoin(self.base_url, path), headers=headers, **kwargs)

        def get_with_host(self, path, host, **kwargs):
            """Make a request with a specific Host header."""
            headers = kwargs.pop('headers', {})
            headers['Host'] = host
            return self.get(path, headers=headers, **kwargs)

    return ApiClient(base_url)
