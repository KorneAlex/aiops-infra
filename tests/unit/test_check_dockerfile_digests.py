"""Tests for scripts/check_dockerfile_digests.py."""

from __future__ import annotations

import importlib.util
from pathlib import Path
from urllib.request import HTTPRedirectHandler, Request

import pytest

REPO_ROOT = Path(__file__).resolve().parent.parent.parent
SCRIPT_PATH = REPO_ROOT / "scripts" / "check_dockerfile_digests.py"
SPEC = importlib.util.spec_from_file_location("check_dockerfile_digests", SCRIPT_PATH)
assert SPEC and SPEC.loader
CHECKER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(CHECKER)


class _Response:
    def __enter__(self):
        return self

    def __exit__(self, *_args):
        return None

    def read(self) -> bytes:
        return b"FROM example.com/image@sha256:abc\n"


def _capture_request(monkeypatch: pytest.MonkeyPatch) -> list[Request]:
    requests = []

    def urlopen(request: Request) -> _Response:
        requests.append(request)
        return _Response()

    monkeypatch.setattr(CHECKER.urllib.request, "urlopen", urlopen)
    return requests


def test_fetch_authenticates_raw_github_url(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("GITHUB_TOKEN", "secret-token")
    requests = _capture_request(monkeypatch)

    content = CHECKER.fetch("https://raw.githubusercontent.com/example/repo/main/Dockerfile")

    assert content.startswith("FROM ")
    assert requests[0].get_header("Authorization") == "Bearer secret-token"


def test_fetch_raw_github_url_without_token(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.delenv("GITHUB_TOKEN", raising=False)
    requests = _capture_request(monkeypatch)

    CHECKER.fetch("https://raw.githubusercontent.com/example/repo/main/Dockerfile")

    assert requests[0].get_header("Authorization") is None


def test_fetch_does_not_send_token_to_other_hosts(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("GITHUB_TOKEN", "secret-token")
    requests = _capture_request(monkeypatch)

    CHECKER.fetch("https://example.com/Dockerfile")

    assert requests[0].get_header("Authorization") is None


def test_fetch_does_not_send_token_over_http(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("GITHUB_TOKEN", "secret-token")
    requests = _capture_request(monkeypatch)

    CHECKER.fetch("http://raw.githubusercontent.com/example/repo/main/Dockerfile")

    assert requests[0].get_header("Authorization") is None


def test_fetch_does_not_forward_token_on_redirect(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("GITHUB_TOKEN", "secret-token")
    requests = _capture_request(monkeypatch)
    CHECKER.fetch("https://raw.githubusercontent.com/example/repo/main/Dockerfile")

    redirected = HTTPRedirectHandler().redirect_request(
        requests[0],
        None,
        302,
        "Found",
        {},
        "https://example.com/Dockerfile",
    )

    assert redirected is not None
    assert redirected.get_header("Authorization") is None
