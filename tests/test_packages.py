import pytest

def test_package_access(api_client):
    """Test that Capsium packages can be accessed."""
    # Test access to the package root
    response = api_client.get("/capsium/mn-samples-iso-0.1.0/")
    assert response.status_code == 200

    # Verify the content is HTML
    assert "text/html" in response.headers.get("Content-Type", "")

    # Verify the content contains expected text from Metanorma package
    assert "ISO sample documents in Metanorma" in response.text

def test_package_css(api_client):
    """Test that HTML files in Capsium packages are served correctly."""
    response = api_client.get("/capsium/mn-samples-iso-0.1.0/documents/technical-report/document.html")
    assert response.status_code == 200

    # Verify the content type is HTML
    assert "text/html" in response.headers.get("Content-Type", "")

    # Verify the content is from the Metanorma package
    assert "ISO" in response.text or "Technical Report" in response.text

def test_package_js(api_client):
    """Test that XML files in Capsium packages are served correctly."""
    response = api_client.get("/capsium/mn-samples-iso-0.1.0/documents.xml")
    assert response.status_code == 200

    # Verify the content type is XML
    assert "xml" in response.headers.get("Content-Type", "").lower()

    # Verify the content is XML
    assert "<?xml" in response.text or "<" in response.text

def test_nonexistent_package(api_client):
    """Test that nonexistent packages return 404."""
    response = api_client.get("/capsium/nonexistent-package/")
    assert response.status_code == 404

def test_nonexistent_file_in_package(api_client):
    """Test that nonexistent files in packages return 404."""
    response = api_client.get("/capsium/mn-samples-iso-0.1.0/nonexistent.html")
    assert response.status_code == 404

def test_package_index_routes(api_client):
    """Test that different index routes work for packages."""
    # Test root path
    response1 = api_client.get("/capsium/mn-samples-iso-0.1.0/")
    assert response1.status_code == 200

    # Test /index path
    response2 = api_client.get("/capsium/mn-samples-iso-0.1.0/index")
    assert response2.status_code == 200

    # Test /index.html path
    response3 = api_client.get("/capsium/mn-samples-iso-0.1.0/index.html")
    assert response3.status_code == 200

    # Verify all responses have the same content
    assert response1.text == response2.text
    assert response2.text == response3.text
