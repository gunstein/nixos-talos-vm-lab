"""Configuration for lab provisioning and testing."""

import os
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

    @classmethod
    def from_env(cls, **overrides) -> "LabConfig":
        """Create config from environment variables with optional overrides.

        Environment variables:
            NIXOS_HOST: nixos-host hostname or IP
            NIXOS_USER: SSH username
            NIXOS_PORT: SSH port
            LAB_PROFILE: Lab profile name (lab1, lab2, ...)
            TUNNEL_PORT: Local port for SSH tunnel
            SSH_KEY_PATH: Path to SSH private key

        Args:
            **overrides: Values that override both defaults and env vars
        """
        config = {
            "profile": os.environ.get("LAB_PROFILE", "lab1"),
            "nixos_host": os.environ.get("NIXOS_HOST", "nixos-host"),
            "nixos_user": os.environ.get("NIXOS_USER", "gunstein"),
            "nixos_port": int(os.environ.get("NIXOS_PORT", "22")),
            "tunnel_local_port": int(os.environ.get("TUNNEL_PORT", "8443")),
        }

        ssh_key = os.environ.get("SSH_KEY_PATH")
        if ssh_key:
            config["ssh_key_path"] = Path(ssh_key)

        # Apply overrides (CLI flags take precedence)
        config.update({k: v for k, v in overrides.items() if v is not None})

        return cls(**config)


@dataclass
class RepoConfig:
    """Configuration for repository management."""

    # GitHub repository
    github_repo: str = "gunstein/nixos-talos-vm-lab"
    github_branch: str = "main"

    # Talos ISO
    talos_version: str = "v1.9.0"
    talos_iso_name: str = "metal-amd64.iso"

    @classmethod
    def from_versions_env(cls, repo_path: Path, **overrides) -> "RepoConfig":
        """Load config from versions.env file in repository.

        Args:
            repo_path: Path to repository root containing versions.env
            **overrides: Values that override versions.env
        """
        versions_file = repo_path / "versions.env"
        config = {}

        if versions_file.exists():
            for line in versions_file.read_text().splitlines():
                line = line.strip()
                if line and not line.startswith("#") and "=" in line:
                    key, value = line.split("=", 1)
                    key = key.strip()
                    value = value.strip()

                    if key == "TALOS_VERSION":
                        config["talos_version"] = value

        config.update({k: v for k, v in overrides.items() if v is not None})

        return cls(**config)

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
