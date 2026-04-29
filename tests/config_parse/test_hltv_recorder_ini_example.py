"""Schema validation for `documents/hltv_recorder.ini.example`.

The plugin loads this format at runtime; missing or mistyped keys break
recording silently. KTPInfrastructure has a parallel test against the
deployed `config/online/hltv_recorder.ini`, but the in-repo template
needs its own guard so a refactor that renames a key (or adds one
without updating the template) is caught at the source.
"""
from __future__ import annotations

from pathlib import Path

import pytest

from .conftest import REPO_ROOT

CONFIG_PATH = REPO_ROOT / "documents" / "hltv_recorder.ini.example"

REQUIRED_KEYS = {"hltv_enabled", "hltv_api_url", "hltv_api_key", "hltv_port"}

# Production HLTV port range — `hltv_port` per server is in [27020, 27044].
# Anything outside this range means the recorder will hit a non-HLTV port.
HLTV_PORT_MIN = 27020
HLTV_PORT_MAX = 27044


def _parse_kv(path: Path) -> dict[str, str]:
    """Flat key=value parser. Comments are `;`. Lowercases keys."""
    out: dict[str, str] = {}
    for lineno, raw in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        line = raw.split(";", 1)[0].strip()
        if not line:
            continue
        if "=" not in line:
            raise ValueError(f"{path.name}:{lineno}: expected key=value, got {line!r}")
        k, _, v = line.partition("=")
        k = k.strip().lower()
        v = v.strip()
        if v.startswith('"') and v.endswith('"'):
            v = v[1:-1]
        if k in out:
            raise ValueError(f"{path.name}:{lineno}: duplicate key {k!r}")
        out[k] = v
    return out


@pytest.fixture(scope="module")
def cfg() -> dict[str, str]:
    if not CONFIG_PATH.exists():
        pytest.skip(f"{CONFIG_PATH} not present")
    return _parse_kv(CONFIG_PATH)


def test_template_parses(cfg):
    assert cfg, f"{CONFIG_PATH.name}: produced no key/value pairs"


def test_required_keys_present(cfg):
    missing = REQUIRED_KEYS - set(cfg.keys())
    assert not missing, (
        f"{CONFIG_PATH.name}: missing required keys: {sorted(missing)}"
    )


def test_hltv_enabled_is_zero_or_one(cfg):
    val = cfg.get("hltv_enabled", "")
    assert val in {"0", "1"}, (
        f"{CONFIG_PATH.name}: hltv_enabled={val!r} should be '0' or '1'"
    )


def test_hltv_port_parses_to_valid_int(cfg):
    raw = cfg.get("hltv_port", "")
    try:
        port = int(raw)
    except ValueError:
        pytest.fail(f"{CONFIG_PATH.name}: hltv_port={raw!r} must be an integer")
    # Template ships with port 27020 — sanity-check it's in production range
    # so a refactor that changes the example to a non-HLTV port (e.g.,
    # accidentally puts the game-server port here) trips immediately.
    assert HLTV_PORT_MIN <= port <= HLTV_PORT_MAX, (
        f"{CONFIG_PATH.name}: hltv_port={port} outside production HLTV range "
        f"[{HLTV_PORT_MIN}, {HLTV_PORT_MAX}]"
    )


def test_hltv_api_url_shape_when_set(cfg):
    """If hltv_api_url has a value, it must look like an HTTP(S) URL.
    Template ships pre-filled with the production data-server URL."""
    url = cfg.get("hltv_api_url", "")
    if url:
        assert url.startswith(("http://", "https://")), (
            f"{CONFIG_PATH.name}: hltv_api_url={url!r} should start http:// or https://"
        )
