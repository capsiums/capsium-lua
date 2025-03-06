import pytest

def test_server_running(api_client):
    """Test that the server is running and responding to requests."""
    response = api_client.get("/")
    assert response.status_code == 200

def test_static_content(api_client):
    """Test that the static content is being served correctly."""
    response = api_client.get("/")
    assert "Capsium Nginx Reactor" in response.text

def test_static_files(api_client):
    """Test that static files are being served with the correct content type."""
    # Test HTML file
    response = api_client.get("/")
    assert response.status_code == 200
    assert "text/html" in response.headers.get("Content-Type", "")

    # Test non-existent file
    response = api_client.get("/nonexistent.html")
    assert response.status_code == 404

def test_nginx_headers(api_client):
    """Test that nginx is setting the expected headers."""
    response = api_client.get("/")
    assert "nginx" in response.headers.get("Server", "").lower()
