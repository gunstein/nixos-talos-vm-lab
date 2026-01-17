"""HTTP client for testing lab services."""

import logging
from dataclasses import dataclass
from typing import Any

import requests
from requests.adapters import HTTPAdapter
from urllib3.util.retry import Retry

from labctl.config import LabConfig

logger = logging.getLogger(__name__)


@dataclass
class LabEndpoints:
    """Lab service endpoints."""

    base_url: str

    @property
    def demo(self) -> str:
        return f"{self.base_url}"

    @property
    def demo_api_hello(self) -> str:
        return f"{self.base_url}/api/hello"

    @property
    def demo_api_items(self) -> str:
        return f"{self.base_url}/api/items"

    @property
    def grafana(self) -> str:
        return self.base_url.replace("demo.lab.local", "grafana.lab.local")

    @property
    def prometheus(self) -> str:
        return self.base_url.replace("demo.lab.local", "prometheus.lab.local")


class LabClient:
    """HTTP client for lab services (used via SSH tunnel)."""

    def __init__(self, config: LabConfig) -> None:
        self.config = config
        self.session = self._create_session()
        self.endpoints = LabEndpoints(base_url=f"https://demo.lab.local:{config.tunnel_local_port}")

    def _create_session(self) -> requests.Session:
        """Create a requests session with retries."""
        session = requests.Session()

        # Retry configuration
        retry = Retry(
            total=3,
            backoff_factor=0.5,
            status_forcelist=[502, 503, 504],
        )
        adapter = HTTPAdapter(max_retries=retry)
        session.mount("https://", adapter)
        session.mount("http://", adapter)

        # Disable SSL verification (self-signed certs)
        session.verify = False

        # Suppress SSL warnings
        import urllib3

        urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)

        return session

    def _request(
        self,
        method: str,
        url: str,
        host: str | None = None,
        **kwargs: Any,
    ) -> requests.Response:
        """Make an HTTP request with optional Host header override."""
        headers = kwargs.pop("headers", {})
        if host:
            headers["Host"] = host

        kwargs["headers"] = headers
        kwargs.setdefault("timeout", self.config.http_timeout)

        logger.debug(f"{method} {url}")
        response = self.session.request(method, url, **kwargs)
        logger.debug(f"Response: {response.status_code}")

        return response

    def get(self, url: str, host: str | None = None, **kwargs: Any) -> requests.Response:
        """GET request."""
        return self._request("GET", url, host, **kwargs)

    def post(self, url: str, host: str | None = None, **kwargs: Any) -> requests.Response:
        """POST request."""
        return self._request("POST", url, host, **kwargs)

    def delete(self, url: str, host: str | None = None, **kwargs: Any) -> requests.Response:
        """DELETE request."""
        return self._request("DELETE", url, host, **kwargs)

    # Convenience methods for demo app

    def demo_hello(self) -> dict:
        """Call /api/hello endpoint."""
        url = f"https://127.0.0.1:{self.config.tunnel_local_port}/api/hello"
        response = self.get(url, host="demo.lab.local")
        response.raise_for_status()
        return response.json()

    def demo_list_items(self) -> list:
        """List all items from database."""
        url = f"https://127.0.0.1:{self.config.tunnel_local_port}/api/items"
        response = self.get(url, host="demo.lab.local")
        response.raise_for_status()
        return response.json()

    def demo_create_item(self, name: str) -> dict:
        """Create a new item in database."""
        url = f"https://127.0.0.1:{self.config.tunnel_local_port}/api/items"
        response = self.post(url, host="demo.lab.local", json={"name": name})
        response.raise_for_status()
        return response.json()

    def grafana_health(self) -> bool:
        """Check if Grafana is responding."""
        url = f"https://127.0.0.1:{self.config.tunnel_local_port}/api/health"
        try:
            response = self.get(url, host="grafana.lab.local")
            return response.status_code == 200
        except requests.RequestException:
            return False

    def prometheus_health(self) -> bool:
        """Check if Prometheus is responding."""
        url = f"https://127.0.0.1:{self.config.tunnel_local_port}/-/healthy"
        try:
            response = self.get(url, host="prometheus.lab.local")
            return response.status_code == 200
        except requests.RequestException:
            return False

    def prometheus_query(self, query: str) -> dict:
        """Run a PromQL query."""
        url = f"https://127.0.0.1:{self.config.tunnel_local_port}/api/v1/query"
        response = self.get(url, host="prometheus.lab.local", params={"query": query})
        response.raise_for_status()
        return response.json()
