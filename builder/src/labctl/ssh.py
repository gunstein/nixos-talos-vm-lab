"""SSH utilities for connecting to nixos-host."""

import logging
import subprocess
import time
from contextlib import contextmanager
from dataclasses import dataclass
from pathlib import Path
from typing import Iterator

import paramiko

from labctl.config import LabConfig

logger = logging.getLogger(__name__)


@dataclass
class CommandResult:
    """Result of a remote command execution."""

    exit_code: int
    stdout: str
    stderr: str

    @property
    def success(self) -> bool:
        return self.exit_code == 0


class SSHClient:
    """SSH client for connecting to nixos-host."""

    def __init__(self, config: LabConfig) -> None:
        self.config = config
        self._client: paramiko.SSHClient | None = None

    def connect(self) -> None:
        """Establish SSH connection."""
        if self._client is not None:
            return

        self._client = paramiko.SSHClient()
        self._client.set_missing_host_key_policy(paramiko.AutoAddPolicy())

        connect_kwargs: dict = {
            "hostname": self.config.nixos_host,
            "port": self.config.nixos_port,
            "username": self.config.nixos_user,
        }

        if self.config.ssh_key_path:
            connect_kwargs["key_filename"] = str(self.config.ssh_key_path)
        else:
            # Use SSH agent
            connect_kwargs["allow_agent"] = True

        logger.info(f"Connecting to {self.config.nixos_user}@{self.config.nixos_host}")
        self._client.connect(**connect_kwargs)
        logger.info("Connected")

    def disconnect(self) -> None:
        """Close SSH connection."""
        if self._client:
            self._client.close()
            self._client = None
            logger.info("Disconnected")

    def run(self, command: str, timeout: int | None = None) -> CommandResult:
        """Execute a command on nixos-host.

        Note: Reads stdout/stderr before getting exit status to avoid
        potential deadlock when command produces large output.
        """
        if self._client is None:
            raise RuntimeError("Not connected")

        timeout = timeout or self.config.command_timeout
        logger.debug(f"Running: {command}")

        stdin, stdout, stderr = self._client.exec_command(command, timeout=timeout)

        # Read all output first to avoid deadlock
        stdout_data = stdout.read().decode()
        stderr_data = stderr.read().decode()

        # Now get exit status (safe after reading all output)
        exit_code = stdout.channel.recv_exit_status()

        result = CommandResult(
            exit_code=exit_code,
            stdout=stdout_data,
            stderr=stderr_data,
        )

        if result.success:
            logger.debug(f"Command succeeded (exit={exit_code})")
        else:
            logger.warning(f"Command failed (exit={exit_code}): {result.stderr}")

        return result

    def run_sudo(self, command: str, timeout: int | None = None) -> CommandResult:
        """Execute a command with sudo on nixos-host.

        Uses sudo -n to fail fast if password is required.
        """
        return self.run(f"sudo -n {command}", timeout=timeout)

    def upload_file(self, local_path: Path, remote_path: Path) -> None:
        """Upload a file via SFTP."""
        if self._client is None:
            raise RuntimeError("Not connected")

        sftp = self._client.open_sftp()
        try:
            logger.info(f"Uploading {local_path} -> {remote_path}")
            sftp.put(str(local_path), str(remote_path))
        finally:
            sftp.close()

    def upload_directory(self, local_path: Path, remote_path: Path) -> None:
        """Upload a directory recursively via SFTP."""
        if self._client is None:
            raise RuntimeError("Not connected")

        sftp = self._client.open_sftp()
        try:
            self._upload_dir_recursive(sftp, local_path, remote_path)
        finally:
            sftp.close()

    def _upload_dir_recursive(
        self, sftp: paramiko.SFTPClient, local_path: Path, remote_path: Path
    ) -> None:
        """Recursively upload directory contents."""
        # Create remote directory if it doesn't exist
        try:
            sftp.stat(str(remote_path))
        except FileNotFoundError:
            logger.debug(f"Creating remote directory: {remote_path}")
            sftp.mkdir(str(remote_path))

        for item in local_path.iterdir():
            remote_item = remote_path / item.name

            if item.is_dir():
                if item.name == ".git":
                    continue  # Skip .git directory
                self._upload_dir_recursive(sftp, item, remote_item)
            else:
                logger.debug(f"Uploading {item} -> {remote_item}")
                sftp.put(str(item), str(remote_item))

    def __enter__(self) -> "SSHClient":
        self.connect()
        return self

    def __exit__(self, *args: object) -> None:
        self.disconnect()


class SSHTunnel:
    """SSH tunnel using system ssh command (more robust than paramiko tunneling)."""

    def __init__(
        self,
        config: LabConfig,
        local_port: int,
        remote_port: int,
        remote_host: str = "127.0.0.1",
    ) -> None:
        self.config = config
        self.local_port = local_port
        self.remote_port = remote_port
        self.remote_host = remote_host
        self._process: subprocess.Popen | None = None

    def start(self) -> None:
        """Start the SSH tunnel."""
        ssh_args = [
            "ssh",
            "-N",  # No command, just tunnel
            "-L",
            f"{self.local_port}:{self.remote_host}:{self.remote_port}",
            "-o",
            "ExitOnForwardFailure=yes",
            "-o",
            "ServerAliveInterval=30",
            "-o",
            "ServerAliveCountMax=3",
            "-p",
            str(self.config.nixos_port),
        ]

        if self.config.ssh_key_path:
            ssh_args.extend(["-i", str(self.config.ssh_key_path)])

        ssh_args.append(f"{self.config.nixos_user}@{self.config.nixos_host}")

        logger.info(
            f"Starting SSH tunnel: localhost:{self.local_port} -> "
            f"{self.remote_host}:{self.remote_port}"
        )
        self._process = subprocess.Popen(
            ssh_args,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.PIPE,
        )

        # Wait a moment for tunnel to establish
        time.sleep(1)

        # Check if process is still running
        if self._process.poll() is not None:
            stderr = self._process.stderr.read().decode() if self._process.stderr else ""
            raise RuntimeError(f"SSH tunnel failed to start: {stderr}")

        logger.info("SSH tunnel started")

    def stop(self) -> None:
        """Stop the SSH tunnel."""
        if self._process:
            self._process.terminate()
            try:
                self._process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                self._process.kill()
                self._process.wait()
            self._process = None
            logger.info("SSH tunnel stopped")

    def __enter__(self) -> "SSHTunnel":
        self.start()
        return self

    def __exit__(self, *args: object) -> None:
        self.stop()


@contextmanager
def ssh_connection(config: LabConfig) -> Iterator[SSHClient]:
    """Context manager for SSH connection."""
    client = SSHClient(config)
    try:
        client.connect()
        yield client
    finally:
        client.disconnect()


@contextmanager
def ssh_tunnel(
    config: LabConfig,
    local_port: int | None = None,
    remote_port: int | None = None,
) -> Iterator[SSHTunnel]:
    """Context manager for SSH tunnel."""
    tunnel = SSHTunnel(
        config,
        local_port=local_port or config.tunnel_local_port,
        remote_port=remote_port or config.tunnel_remote_port,
    )
    try:
        tunnel.start()
        yield tunnel
    finally:
        tunnel.stop()
