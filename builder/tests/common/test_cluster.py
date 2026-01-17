"""Common cluster tests - run for all lab profiles."""

import pytest

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
