"""Pytest fixtures for lab testing."""

import os

import pytest

from labctl.client import LabClient
from labctl.config import LabConfig
from labctl.provisioner import Provisioner
from labctl.ssh import SSHClient, ssh_tunnel


@pytest.fixture(scope="session")
def lab_config() -> LabConfig:
    """Lab configuration from environment or defaults."""
    return LabConfig(
        nixos_host=os.environ.get("NIXOS_HOST", "nixos-host"),
        nixos_user=os.environ.get("NIXOS_USER", "gunstein"),
        profile=os.environ.get("LAB_PROFILE", "lab1"),
        tunnel_local_port=int(os.environ.get("TUNNEL_PORT", "8443")),
    )


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
def tunnel(lab_config: LabConfig, ssh_client: SSHClient):
    """SSH tunnel for accessing lab services."""
    with ssh_tunnel(
        ssh_client,
        local_port=lab_config.tunnel_local_port,
        remote_port=lab_config.tunnel_remote_port,
    ) as t:
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
