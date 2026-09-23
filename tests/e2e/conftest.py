"""Fixtures for the end-to-end inference tests; run them with `make e2e`.

The nodes come from the Terraform-generated Ansible inventory, and the API key from
$LLAMA_API_KEY (the Makefile reads it from the vault).
"""

import json
import os
import subprocess
from pathlib import Path

import pytest
import requests

ANSIBLE_DIR = Path(__file__).resolve().parents[2] / "ansible"
PORT = 8080


def inventory_nodes():
    """{name: base_url} for every host in the `nodes` group."""
    out = subprocess.run(
        ["ansible-inventory", "--list"],
        cwd=ANSIBLE_DIR,
        stdin=subprocess.DEVNULL,
        capture_output=True,
        text=True,
        check=True,
    ).stdout
    inventory = json.loads(out)
    hostvars = inventory["_meta"]["hostvars"]
    return {
        name: f"http://{hostvars[name]['ansible_host']}:{PORT}"
        for name in inventory["nodes"]["hosts"]
    }


NODES = inventory_nodes()


class Client:
    """A node's llama-server, with the API key on every request."""

    def __init__(self, name, base_url, api_key):
        self.name = name
        self.base_url = base_url
        self.session = requests.Session()
        self.session.headers["Authorization"] = f"Bearer {api_key}"

    def get(self, path, **kwargs):
        return self.session.get(self.base_url + path, timeout=30, **kwargs)

    def post(self, path, body, **kwargs):
        return self.session.post(self.base_url + path, json=body, timeout=120, **kwargs)

    def chat(self, prompt, **params):
        """A greedy chat completion; returns the parsed response."""
        body = {"messages": [{"role": "user", "content": prompt}], "temperature": 0, **params}
        response = self.post("/v1/chat/completions", body)
        assert response.status_code == 200, f"{self.name}: {response.status_code} {response.text}"
        return response.json()


@pytest.fixture(scope="session")
def api_key():
    key = os.environ.get("LLAMA_API_KEY")
    if not key:
        pytest.exit("LLAMA_API_KEY is not set; run the tests with `make e2e`", returncode=2)
    return key


@pytest.fixture(scope="session", params=sorted(NODES), ids=str)
def node(request, api_key):
    """Each node in turn."""
    return Client(request.param, NODES[request.param], api_key)


@pytest.fixture(scope="session")
def fleet(api_key):
    """Every node at once, for checks that compare them."""
    return [Client(name, NODES[name], api_key) for name in sorted(NODES)]
