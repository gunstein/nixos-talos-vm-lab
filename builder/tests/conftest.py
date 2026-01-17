"""Pytest fixtures for lab testing."""

import pytest

from labctl.client import LabClient
from labctl.config import LabConfig
from labctl.provisioner import Provisioner
from labctl.ssh import SSHClient, ssh_tunnel


@pytest.fixture(scope="session")
def lab_config() -> LabConfig:
    """Lab configuration from environment variables."""
    return LabConfig.from_env()


@pytest.fixture(scope="session")
def ssh_client(lab_config: LabConfig) -> SSHClient:
    """SSH client connected to nixos-host."""
    client = SSHClient(lab_config)
    client.connect()
    yield client
    client.disconnect()


@pytest.fixture(scope="session")
def provisioner(lab_config: LabConfig, ssh_client: SSHClient) -> Provisioner:
    """Lab provisioner."""
    return Provisioner(lab_config, ssh_client)


@pytest.fixture(scope="session")
def tunnel(lab_config: LabConfig):
    """SSH tunnel for accessing lab services."""
    with ssh_tunnel(lab_config) as t:
        yield t


@pytest.fixture(scope="session")
def lab_client(lab_config: LabConfig, tunnel) -> LabClient:
    """HTTP client for lab services (requires tunnel)."""
    return LabClient(lab_config)


@pytest.fixture(scope="session")
def lab_ready(provisioner: Provisioner) -> bool:
    """Ensure lab is ready before running tests."""
    # Wait for all pods to be ready
    ready = provisioner.wait_for_pods_ready(timeout=300)
    if not ready:
        pytest.skip("Lab not ready - pods not running")
    return ready
