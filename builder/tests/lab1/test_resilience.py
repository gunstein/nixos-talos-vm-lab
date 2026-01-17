"""Resilience tests - verify recovery from failures (lab1 specific)."""

import time

import pytest

from labctl.client import LabClient
from labctl.provisioner import Provisioner

pytestmark = pytest.mark.resilience


class TestPodResilience:
    """Test that pods recover from failures."""

    def test_demo_backend_recovers_after_delete(
        self,
        provisioner: Provisioner,
        lab_client: LabClient,
        lab_ready: bool,
    ) -> None:
        """Demo backend should recover after pod deletion."""
        # Verify backend is working
        result = lab_client.demo_hello()
        assert result["message"] == "Hello from demo-backend"

        # Delete the backend pod
        provisioner.ssh_client.run("kubectl -n demo delete pod -l app=demo-backend --wait=false")

        # Wait for pod to be recreated
        time.sleep(5)
        provisioner.wait_for_pods_ready("demo", timeout=60)

        # Verify backend is working again
        result = lab_client.demo_hello()
        assert result["message"] == "Hello from demo-backend"

    def test_demo_frontend_recovers_after_delete(
        self,
        provisioner: Provisioner,
        lab_client: LabClient,
        lab_ready: bool,
    ) -> None:
        """Demo frontend should recover after pod deletion."""
        # Delete the frontend pod
        provisioner.ssh_client.run("kubectl -n demo delete pod -l app=demo-frontend --wait=false")

        # Wait for pod to be recreated
        time.sleep(5)
        provisioner.wait_for_pods_ready("demo", timeout=60)

        # Verify frontend is serving
        result = lab_client.demo_hello()
        assert result["message"] == "Hello from demo-backend"


class TestDatabaseResilience:
    """Test database resilience."""

    def test_data_persists_after_pod_restart(
        self,
        provisioner: Provisioner,
        lab_client: LabClient,
        lab_ready: bool,
    ) -> None:
        """Data should persist after database pod restart."""
        # Create a unique item
        unique_name = f"persist-test-{int(time.time())}"
        lab_client.demo_create_item(unique_name)

        # Verify item exists
        items = lab_client.demo_list_items()
        names = [item["name"] for item in items]
        assert unique_name in names

        # Restart the database pod
        provisioner.ssh_client.run(
            "kubectl -n demo delete pod -l cnpg.io/cluster=demo-db --wait=false"
        )

        # Wait for database to recover
        time.sleep(10)
        provisioner.wait_for_pods_ready("demo", timeout=120)

        # Wait a bit more for database to be fully ready
        time.sleep(5)

        # Verify item still exists
        items = lab_client.demo_list_items()
        names = [item["name"] for item in items]
        assert unique_name in names, f"Item {unique_name} not found after restart"
