"""Source-contract tests for the ktp_match_aborted window close.

KTPMatchHandler fires ktp_match_aborted on a second-half .cancel and on
.forcereset, which fire no ktp_match_end. The handler must emit the same
MATCH_WINDOW_CLOSE line shape the renamer and the true-start backfill parse,
and must build against ktp_matchhandler.inc so a signature drift fails the
compile instead of silently never firing.
"""
from __future__ import annotations

import os
import re
from pathlib import Path

import pytest

from .conftest import REPO_ROOT

SOURCE = (REPO_ROOT / "KTPHLTVRecorder.sma").read_text(encoding="utf-8")
VENDORED = REPO_ROOT / "include" / "ktp_matchhandler.inc"

# KTPInfrastructure scripts/backfills/truestart.py, which needs this field order.
TRUESTART_RE = re.compile(
    r"MATCH_WINDOW_(OPEN|CLOSE) match_id=(\S+)(?: half=(\S+))? match_type=(\S+).*?wall_time=(\d+)")
# KTPInfrastructure scripts/hltv-demo-renamer.py
RENAMER_CLOSE_RE = re.compile(r"\[KTP HLTV\] MATCH_WINDOW_CLOSE\s+(?P<kv>.+?)$")


def _handler(name: str) -> str:
    start = SOURCE.index(f"public {name}(")
    end = SOURCE.index("\n}\n", start)
    return SOURCE[start:end]


def _close_format(body: str) -> str:
    m = re.search(r'"(\[KTP HLTV\] MATCH_WINDOW_CLOSE [^"]*)"', body)
    assert m, "no MATCH_WINDOW_CLOSE format string"
    return m.group(1)


def test_handler_signature_matches_the_forward() -> None:
    assert ("public ktp_match_aborted(const matchId[], const map[], "
            "MatchType:matchType, const reason[])") in SOURCE


def test_aborted_close_parses_like_a_match_end_close() -> None:
    fmt = _close_format(_handler("ktp_match_aborted"))
    line = (fmt.replace("%s", "X", 1).replace("%s", "ktp", 1).replace("%s", "dod_anzio", 1)
               .replace("%d", "27020", 1).replace("%d", "1790000000", 1).replace("%s", "forcereset", 1))
    line = line.replace("match_id=X", "match_id=1790000000-ATL1")
    m = TRUESTART_RE.search(line)
    assert m and m.group(1) == "CLOSE" and m.group(2) == "1790000000-ATL1"
    assert m.group(4) == "ktp" and m.group(5) == "1790000000"
    kv = dict(re.findall(r"(\w+)=(\S+)", RENAMER_CLOSE_RE.search(line).group("kv")))
    assert kv["hltv_port"] == "27020" and kv["reason"] == "forcereset"
    assert "score" not in kv


def test_aborted_close_keeps_match_end_field_prefix() -> None:
    end_fmt = _close_format(_handler("ktp_match_end"))
    ab_fmt = _close_format(_handler("ktp_match_aborted"))
    prefix = end_fmt.split(" score=")[0]
    assert ab_fmt.startswith(prefix + " reason=")


def test_include_comes_after_the_matchtype_enum() -> None:
    assert SOURCE.index("enum MatchType {") < SOURCE.index("#include <ktp_matchhandler>")


def test_vendored_include_declares_the_forward() -> None:
    text = VENDORED.read_text(encoding="utf-8")
    assert re.search(
        r"forward ktp_match_aborted\(const matchId\[\], const map\[\], "
        r"MatchType:matchType, const reason\[\]\);", text)


def _matchhandler_include() -> Path | None:
    root = os.environ.get("KTPMATCHHANDLER_ROOT")
    cand = Path(root) if root else REPO_ROOT.parent / "KTPMatchHandler"
    inc = cand / "ktp_matchhandler.inc"
    return inc if inc.is_file() else None


def test_vendored_include_matches_matchhandler_checkout() -> None:
    upstream = _matchhandler_include()
    if upstream is None:
        pytest.skip("no KTPMatchHandler checkout beside this repo")
    norm = lambda p: p.read_bytes().replace(b"\r\n", b"\n")
    assert norm(VENDORED) == norm(upstream)
