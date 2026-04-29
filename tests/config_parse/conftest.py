"""Path constants for KTPHLTVRecorder config-parse tests.

Mirrors KTPInfrastructure/tests/config_parse/conftest.py. The central
KTPInfra tests guard `config/online/hltv_recorder.ini` (the deployed file);
this in-repo test guards `documents/hltv_recorder.ini.example` (the
template operators copy onto the server) so schema drift is caught at
the source.
"""
from __future__ import annotations

from pathlib import Path

# tests/config_parse/conftest.py → repo root
REPO_ROOT = Path(__file__).resolve().parents[2]
