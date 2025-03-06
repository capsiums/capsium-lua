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

    # Run the container
    print("Running Capsium Nginx container...")
    container = docker_client.containers.run(
        "capsium-nginx:test",
        detach=True,
        ports={'80/tcp': 8080},
        volumes={
            os.path.abspath(os.path.join(os.path.dirname(__file__), "../test/fixtures")):
            {'bind': '/var/lib/capsium/packages', 'mode': 'ro'}
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

        def get(self, path, **kwargs):
            return requests.get(urljoin(self.base_url, path), **kwargs)

    return ApiClient(base_url)
