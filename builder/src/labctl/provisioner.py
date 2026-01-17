"""Provision and manage Talos lab on nixos-host."""

import logging
import time

from labctl.config import LabConfig
from labctl.ssh import SSHClient

logger = logging.getLogger(__name__)


class Provisioner:
    """Provision and manage Talos lab via SSH."""

    def __init__(self, config: LabConfig, ssh_client: SSHClient) -> None:
        self.config = config
        self.ssh_client = ssh_client

    def _run_lab_command(self, command: str, timeout: int | None = None) -> None:
        """Run a lab.sh command."""
        timeout = timeout or self.config.provision_timeout
        full_command = f"cd {self.config.remote_repo_path} && sudo ./scripts/lab {self.config.profile} {command}"

        logger.info(f"Running: lab {self.config.profile} {command}")
        result = self.ssh_client.run(full_command, timeout=timeout)

        if not result.success:
            raise RuntimeError(
                f"Lab command '{command}' failed (exit={result.exit_code}):\n{result.stderr}"
            )

        logger.info(f"Command '{command}' completed successfully")

    def status(self) -> str:
        """Get lab status."""
        result = self.ssh_client.run(
            f"cd {self.config.remote_repo_path} && sudo ./scripts/lab {self.config.profile} status",
            timeout=self.config.command_timeout,
        )
        return result.stdout

    def up(self) -> None:
        """Create network and VMs."""
        self._run_lab_command("up")

    def provision(self) -> None:
        """Provision Talos and bootstrap Kubernetes."""
        self._run_lab_command("provision")

    def verify(self) -> None:
        """Verify cluster health."""
        self._run_lab_command("verify")

    def all(self) -> None:
        """Full lab setup (up + provision + verify + ingress + demo + monitoring)."""
        self._run_lab_command("all")

    def wipe(self) -> None:
        """Destroy the lab completely."""
        self._run_lab_command("wipe")

    def doctor(self) -> str:
        """Run health checks."""
        result = self.ssh_client.run(
            f"cd {self.config.remote_repo_path} && sudo ./scripts/doctor {self.config.profile}",
            timeout=self.config.command_timeout,
        )
        return result.stdout + result.stderr

    def wait_for_pods_ready(
        self,
        namespace: str = "",
        timeout: int = 300,
        interval: int = 10,
    ) -> bool:
        """Wait for all pods in a namespace to be ready."""
        ns_flag = f"-n {namespace}" if namespace else "-A"
        start_time = time.time()

        while time.time() - start_time < timeout:
            result = self.ssh_client.run(
                f"kubectl get pods {ns_flag} --no-headers | grep -v Running | grep -v Completed | wc -l",
                timeout=30,
            )

            if result.success:
                not_ready = int(result.stdout.strip() or "0")
                if not_ready == 0:
                    logger.info(f"All pods ready in {namespace or 'all namespaces'}")
                    return True
                logger.debug(f"{not_ready} pods not ready, waiting...")

            time.sleep(interval)

        logger.warning(f"Timeout waiting for pods in {namespace or 'all namespaces'}")
        return False

    def get_pods(self, namespace: str = "") -> str:
        """Get pod status."""
        ns_flag = f"-n {namespace}" if namespace else "-A"
        result = self.ssh_client.run(
            f"kubectl get pods {ns_flag}",
            timeout=30,
        )
        return result.stdout

    def get_nodes(self) -> str:
        """Get node status."""
        result = self.ssh_client.run("kubectl get nodes -o wide", timeout=30)
        return result.stdout
