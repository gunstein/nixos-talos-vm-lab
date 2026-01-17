"""Deploy repository and assets to nixos-host."""

import logging
import subprocess
import tempfile
from pathlib import Path

from labctl.config import LabConfig, RepoConfig
from labctl.ssh import SSHClient

logger = logging.getLogger(__name__)


class Deployer:
    """Handles cloning repo, downloading assets, and deploying to nixos-host."""

    def __init__(
        self,
        lab_config: LabConfig,
        repo_config: RepoConfig,
        ssh_client: SSHClient,
    ) -> None:
        self.lab_config = lab_config
        self.repo_config = repo_config
        self.ssh_client = ssh_client

    def clone_repo(self, target_dir: Path) -> None:
        """Clone the repository from GitHub."""
        if target_dir.exists():
            logger.info(f"Updating existing repo in {target_dir}")
            subprocess.run(
                ["git", "pull", "--ff-only"],
                cwd=target_dir,
                check=True,
            )
        else:
            logger.info(f"Cloning {self.repo_config.github_clone_url} to {target_dir}")
            subprocess.run(
                [
                    "git",
                    "clone",
                    "--branch",
                    self.repo_config.github_branch,
                    self.repo_config.github_clone_url,
                    str(target_dir),
                ],
                check=True,
            )

    def download_talos_iso(self, target_dir: Path) -> Path:
        """Download Talos ISO if not already present."""
        assets_dir = target_dir / "assets"
        assets_dir.mkdir(exist_ok=True)

        iso_path = assets_dir / self.repo_config.talos_iso_name
        if iso_path.exists():
            logger.info(f"Talos ISO already exists: {iso_path}")
            return iso_path

        logger.info(f"Downloading Talos ISO from {self.repo_config.talos_iso_url}")
        subprocess.run(
            [
                "curl",
                "-L",
                "-o",
                str(iso_path),
                self.repo_config.talos_iso_url,
            ],
            check=True,
        )
        logger.info(f"Downloaded Talos ISO to {iso_path}")
        return iso_path

    def deploy_to_nixos_host(self, local_repo_path: Path) -> None:
        """Deploy the repository to nixos-host via rsync over SSH."""
        remote_path = (
            f"{self.lab_config.nixos_user}@{self.lab_config.nixos_host}:{local_repo_path.name}"
        )

        # Use rsync for efficient transfer
        logger.info(f"Deploying {local_repo_path} to {self.lab_config.nixos_host}")
        subprocess.run(
            [
                "rsync",
                "-az",
                "--delete",
                "--exclude",
                ".git/",
                "-e",
                f"ssh -p {self.lab_config.nixos_port}",
                f"{local_repo_path}/",
                f"{self.lab_config.nixos_user}@{self.lab_config.nixos_host}:~/{local_repo_path.name}/",
            ],
            check=True,
        )
        logger.info("Deploy complete")

    def run_install_script(self) -> None:
        """Run install.sh on nixos-host."""
        logger.info("Running install.sh on nixos-host")
        result = self.ssh_client.run_sudo(
            f"~/nixos-talos-vm-lab/scripts/install.sh",
            timeout=self.lab_config.provision_timeout,
        )
        if not result.success:
            raise RuntimeError(f"install.sh failed: {result.stderr}")
        logger.info("install.sh completed successfully")

    def full_deploy(self, local_repo_path: Path | None = None) -> None:
        """
        Full deployment workflow:
        1. Clone/update repo (if no local path given)
        2. Download Talos ISO
        3. Deploy to nixos-host
        4. Run install.sh
        """
        if local_repo_path is None:
            # Clone to temp directory
            with tempfile.TemporaryDirectory() as tmpdir:
                repo_path = Path(tmpdir) / "nixos-talos-vm-lab"
                self.clone_repo(repo_path)
                self.download_talos_iso(repo_path)
                self.deploy_to_nixos_host(repo_path)
        else:
            # Use existing local repo
            self.download_talos_iso(local_repo_path)
            self.deploy_to_nixos_host(local_repo_path)

        self.run_install_script()
