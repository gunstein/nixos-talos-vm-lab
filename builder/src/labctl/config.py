"""Configuration for lab provisioning and testing."""

import os
from dataclasses import dataclass, field
from pathlib import Path

try:
    import tomllib
except ImportError:
    import tomli as tomllib  # Python < 3.11 fallback


CONFIG_FILE_PATHS = [
    Path("~/.config/labctl/config.toml").expanduser(),
    Path("~/.labctlrc").expanduser(),
]


def _find_config_file() -> Path | None:
    """Find the first existing config file."""
    for path in CONFIG_FILE_PATHS:
        if path.exists():
            return path
    return None


def _load_config_file() -> dict:
    """Load configuration from TOML file."""
    config_path = _find_config_file()
    if config_path is None:
        return {}

    with open(config_path, "rb") as f:
        return tomllib.load(f)


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

    # Local repo path (for labctl deploy)
    local_repo: Path = field(default_factory=lambda: Path("~/nixos-talos-vm-lab").expanduser())

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
    def load(cls, **overrides) -> "LabConfig":
        """Load config from file, environment variables, and overrides.

        Priority (highest to lowest):
            1. Explicit overrides (CLI flags)
            2. Environment variables
            3. Config file (~/.config/labctl/config.toml)
            4. Defaults

        Config file format:
            [lab]
            profile = "lab1"
            local_repo = "~/nixos-talos-vm-lab"

            [nixos-host]
            host = "192.168.0.106"
            user = "gunstein"
            port = 22

            [tunnel]
            local_port = 8443
            remote_port = 443
        """
        # Start with defaults
        config = {}

        # Load from config file
        file_config = _load_config_file()

        if "lab" in file_config:
            lab = file_config["lab"]
            if "profile" in lab:
                config["profile"] = lab["profile"]
            if "local_repo" in lab:
                config["local_repo"] = Path(lab["local_repo"]).expanduser()

        if "nixos-host" in file_config:
            host_cfg = file_config["nixos-host"]
            if "host" in host_cfg:
                config["nixos_host"] = host_cfg["host"]
            if "user" in host_cfg:
                config["nixos_user"] = host_cfg["user"]
            if "port" in host_cfg:
                config["nixos_port"] = host_cfg["port"]
            if "ssh_key" in host_cfg:
                config["ssh_key_path"] = Path(host_cfg["ssh_key"]).expanduser()

        if "tunnel" in file_config:
            tunnel = file_config["tunnel"]
            if "local_port" in tunnel:
                config["tunnel_local_port"] = tunnel["local_port"]
            if "remote_port" in tunnel:
                config["tunnel_remote_port"] = tunnel["remote_port"]

        # Override with environment variables
        if os.environ.get("LAB_PROFILE"):
            config["profile"] = os.environ["LAB_PROFILE"]
        if os.environ.get("NIXOS_HOST"):
            config["nixos_host"] = os.environ["NIXOS_HOST"]
        if os.environ.get("NIXOS_USER"):
            config["nixos_user"] = os.environ["NIXOS_USER"]
        if os.environ.get("NIXOS_PORT"):
            config["nixos_port"] = int(os.environ["NIXOS_PORT"])
        if os.environ.get("TUNNEL_PORT"):
            config["tunnel_local_port"] = int(os.environ["TUNNEL_PORT"])
        if os.environ.get("SSH_KEY_PATH"):
            config["ssh_key_path"] = Path(os.environ["SSH_KEY_PATH"])
        if os.environ.get("LOCAL_REPO"):
            config["local_repo"] = Path(os.environ["LOCAL_REPO"]).expanduser()

        # Apply explicit overrides (CLI flags take precedence)
        config.update({k: v for k, v in overrides.items() if v is not None})

        return cls(**config)

    # Keep old method for backwards compatibility
    @classmethod
    def from_env(cls, **overrides) -> "LabConfig":
        """Deprecated: Use load() instead."""
        return cls.load(**overrides)


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
    def load(cls, repo_path: Path | None = None, **overrides) -> "RepoConfig":
        """Load config from file and versions.env.

        Args:
            repo_path: Path to repository root containing versions.env
            **overrides: Values that override other sources
        """
        config = {}

        # Load from config file
        file_config = _load_config_file()
        if "github" in file_config:
            gh = file_config["github"]
            if "repo" in gh:
                config["github_repo"] = gh["repo"]
            if "branch" in gh:
                config["github_branch"] = gh["branch"]

        # Load from versions.env if repo_path provided
        if repo_path:
            versions_file = repo_path / "versions.env"
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

    # Keep old method for backwards compatibility
    @classmethod
    def from_versions_env(cls, repo_path: Path, **overrides) -> "RepoConfig":
        """Deprecated: Use load() instead."""
        return cls.load(repo_path, **overrides)

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
