import pytest
import json

def test_config_api_metadata(api_client):
    """Test that the metadata API returns configuration-aware data."""
    response = api_client.get("/api/v1/introspect/metadata")
    assert response.status_code == 200

    # Verify response is valid JSON
    data = response.json()
    assert "packages" in data

    # Verify packages is a list
    assert isinstance(data["packages"], list)

    # If there are packages, verify they have the expected structure
    if data["packages"]:
        package = data["packages"][0]
        assert "name" in package
        assert "version" in package

def test_config_api_routes(api_client):
    """Test that the routes API returns configuration-aware routes."""
    response = api_client.get("/api/v1/introspect/routes")
    assert response.status_code == 200

    # Verify response is valid JSON
    data = response.json()
    assert "routes" in data

    # Verify routes is a list
    assert isinstance(data["routes"], list)

    # If there are routes, verify they have the expected structure
    if data["routes"]:
        route_entry = data["routes"][0]
        assert "package" in route_entry
        assert "routes" in route_entry
        assert isinstance(route_entry["routes"], list)

def test_custom_mount_path(api_client):
    """Test accessing package at custom mount path."""
    # Test access to the package at custom path (/app)
    response = api_client.get("/app/")
    assert response.status_code == 200

    # Verify the content is HTML
    assert "text/html" in response.headers.get("Content-Type", "")

    # Verify the content contains expected text from Metanorma package
    assert "ISO sample documents in Metanorma" in response.text

    # Test accessing a resource with the custom path
    response = api_client.get("/app/documents.xml")
    assert response.status_code == 200
    assert "xml" in response.headers.get("Content-Type", "").lower()

def test_custom_headers(api_client):
    """Test that custom headers are applied from configuration."""
    # Test custom headers from global mount configuration
    response = api_client.get("/app/")
    assert response.status_code == 200
    # The config.json has X-Frame-Options and X-Content-Type-Options
    assert response.headers.get("X-Frame-Options") == "SAMEORIGIN"
    assert response.headers.get("X-Content-Type-Options") == "nosniff"

def test_nested_routes_with_custom_path(api_client):
    """Test that nested routes work with custom mount paths."""
    # Test nested route with custom path
    response = api_client.get("/app/index.html")
    assert response.status_code == 200
    assert "text/html" in response.headers.get("Content-Type", "")
    assert "ISO sample documents in Metanorma" in response.text

def test_default_path_still_works(api_client):
    """Test that the default path still works alongside custom paths."""
    # Test default path
    response = api_client.get("/capsium/mn-samples-iso-0.1.0/")
    assert response.status_code == 200
    assert "text/html" in response.headers.get("Content-Type", "")
    assert "ISO sample documents in Metanorma" in response.text

def test_nonexistent_custom_path(api_client):
    """Test that nonexistent custom paths return 404."""
    # Test nonexistent custom path
    response = api_client.get("/nonexistent-path/")
    assert response.status_code == 404

def test_domain_based_routing(api_client):
    """Test that domain-based routing works."""
    # Test with example.com domain (from config)
    response = api_client.get_with_host("/app/", "example.com")
    assert response.status_code == 200
    assert "text/html" in response.headers.get("Content-Type", "")
    assert "ISO sample documents in Metanorma" in response.text

    # Verify custom headers for this domain
    assert response.headers.get("X-Frame-Options") == "SAMEORIGIN"

def test_domain_and_path_combination(api_client):
    """Test that domain and path combinations work."""
    # Test with example.com domain and /app path
    response = api_client.get_with_host("/app/documents.xml", "example.com")
    assert response.status_code == 200
    assert "xml" in response.headers.get("Content-Type", "").lower()

    # Test with example.com domain and incorrect path
    response = api_client.get_with_host("/wrong-path/", "example.com")
    assert response.status_code == 404

def test_multiple_domains(api_client):
    """Test that multiple domains can be configured."""
    # Test with example.com domain
    response1 = api_client.get_with_host("/app/", "example.com")
    assert response1.status_code == 200
    assert response1.headers.get("X-Frame-Options") == "SAMEORIGIN"

    # Test with default domain
    response2 = api_client.get("/app/")
    assert response2.status_code == 200

    # Content should be the same
    assert "ISO sample documents in Metanorma" in response1.text
    assert "ISO sample documents in Metanorma" in response2.text
