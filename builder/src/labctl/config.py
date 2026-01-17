"""Configuration for lab provisioning and testing."""

from dataclasses import dataclass, field
from pathlib import Path


@dataclass
class LabConfig:
    """Configuration for a lab environment."""

    # Lab profile name (e.g., "lab1", "lab2")
    profile: str = "lab1"

    # nixos-host connection
    nixos_host: str = "nixos-host"
    nixos_user: str = "gunstein"
    nixos_port: int = 22

    # SSH key for authentication (None = use ssh-agent)
    ssh_key_path: Path | None = None

    # Remote paths on nixos-host
    remote_repo_path: Path = field(default_factory=lambda: Path("/etc/nixos/talos-host"))

    # Local tunnel port for accessing lab services
    tunnel_local_port: int = 8443
    tunnel_remote_port: int = 443

    # Lab hostnames (accessed via tunnel)
    lab_hosts: list[str] = field(
        default_factory=lambda: [
            "demo.lab.local",
            "grafana.lab.local",
            "prometheus.lab.local",
        ]
    )

    # Timeouts (seconds)
    provision_timeout: int = 600  # 10 minutes for full lab setup
    command_timeout: int = 60
    http_timeout: int = 10


@dataclass
class RepoConfig:
    """Configuration for repository management."""

    # GitHub repository
    github_repo: str = "gunstein/nixos-talos-vm-lab"
    github_branch: str = "main"

    # Talos ISO
    talos_version: str = "v1.9.0"
    talos_iso_name: str = "metal-amd64.iso"

    @property
    def talos_iso_url(self) -> str:
        """URL to download Talos ISO."""
        return (
            f"https://github.com/siderolabs/talos/releases/download/"
            f"{self.talos_version}/{self.talos_iso_name}"
        )

    @property
    def github_clone_url(self) -> str:
        """URL to clone the repository."""
        return f"https://github.com/{self.github_repo}.git"
