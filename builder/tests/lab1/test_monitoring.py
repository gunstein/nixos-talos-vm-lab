"""Monitoring tests - specific to lab1 profile."""

import pytest

from labctl.client import LabClient

pytestmark = pytest.mark.smoke


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
