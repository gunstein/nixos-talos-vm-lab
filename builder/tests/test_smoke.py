"""Smoke tests - basic checks that the lab is functioning."""

import pytest

from labctl.client import LabClient
from labctl.provisioner import Provisioner

pytestmark = pytest.mark.smoke


class TestClusterHealth:
    """Test basic cluster health."""

    def test_nodes_ready(self, provisioner: Provisioner) -> None:
        """All nodes should be in Ready state."""
        output = provisioner.get_nodes()
        assert "Ready" in output
        assert "NotReady" not in output

    def test_system_pods_running(self, provisioner: Provisioner) -> None:
        """Core system pods should be running."""
        output = provisioner.get_pods("kube-system")
        assert "coredns" in output
        assert "Running" in output

    def test_traefik_running(self, provisioner: Provisioner) -> None:
        """Traefik ingress controller should be running."""
        output = provisioner.get_pods("traefik-system")
        assert "traefik" in output
        assert "Running" in output


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


class TestMonitoring:
    """Test the monitoring stack."""

    def test_grafana_responding(self, lab_client: LabClient, lab_ready: bool) -> None:
        """Grafana should be responding."""
        assert lab_client.grafana_health() is True

    def test_prometheus_responding(self, lab_client: LabClient, lab_ready: bool) -> None:
        """Prometheus should be responding."""
        assert lab_client.prometheus_health() is True

    def test_prometheus_has_targets(self, lab_client: LabClient, lab_ready: bool) -> None:
        """Prometheus should have scrape targets."""
        result = lab_client.prometheus_query("up")
        assert result["status"] == "success"
        assert len(result["data"]["result"]) > 0
