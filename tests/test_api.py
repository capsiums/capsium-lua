import pytest
import json

def test_metadata_api(api_client):
    """Test the metadata API endpoint."""
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

def test_routes_api(api_client):
    """Test the routes API endpoint."""
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

def test_content_hashes_api(api_client):
    """Test the content hashes API endpoint."""
    response = api_client.get("/api/v1/introspect/content-hashes")
    assert response.status_code == 200

    # Verify response is valid JSON
    data = response.json()
    assert "contentHashes" in data

    # Verify contentHashes is a list
    assert isinstance(data["contentHashes"], list)

    # If there are content hashes, verify they have the expected structure
    if data["contentHashes"]:
        hash_entry = data["contentHashes"][0]
        assert "package" in hash_entry
        assert "hash" in hash_entry

def test_content_validity_api(api_client):
    """Test the content validity API endpoint."""
    response = api_client.get("/api/v1/introspect/content-validity")
    assert response.status_code == 200

    # Verify response is valid JSON
    data = response.json()
    assert "contentValidity" in data

    # Verify contentValidity is a list
    assert isinstance(data["contentValidity"], list)

    # If there are validity entries, verify they have the expected structure
    if data["contentValidity"]:
        validity_entry = data["contentValidity"][0]
        assert "package" in validity_entry
        assert "valid" in validity_entry
        assert isinstance(validity_entry["valid"], bool)

def test_invalid_api_endpoint(api_client):
    """Test that invalid API endpoints return 404."""
    response = api_client.get("/api/v1/introspect/nonexistent")
    assert response.status_code == 404

    # Verify response is valid JSON
    data = response.json()
    assert "error" in data
