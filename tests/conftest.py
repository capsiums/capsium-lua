import pytest
import requests
from urllib.parse import urljoin

@pytest.fixture(scope="session")
def base_url():
    """Base URL for the Capsium nginx server (assumes docker-compose is running)."""
    return "http://localhost:8080"

@pytest.fixture(scope="session")
def api_client(base_url):
    """API client for making requests to the Capsium nginx server."""
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
