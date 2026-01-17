"""Demo app tests - specific to lab1 profile."""

import pytest

from labctl.client import LabClient

pytestmark = pytest.mark.smoke


class TestDemoApp:
    """Test the demo application."""

    def test_demo_hello_endpoint(self, lab_client: LabClient, lab_ready: bool) -> None:
        """Demo /api/hello endpoint should respond."""
        result = lab_client.demo_hello()
        assert result["message"] == "Hello from demo-backend"

    def test_demo_items_empty(self, lab_client: LabClient, lab_ready: bool) -> None:
        """Demo /api/items should return a list."""
        items = lab_client.demo_list_items()
        assert isinstance(items, list)

    def test_demo_create_and_list_item(self, lab_client: LabClient, lab_ready: bool) -> None:
        """Should be able to create and retrieve items."""
        # Create item
        created = lab_client.demo_create_item("test-item")
        assert "id" in created
        assert created["name"] == "test-item"

        # List and verify
        items = lab_client.demo_list_items()
        names = [item["name"] for item in items]
        assert "test-item" in names
