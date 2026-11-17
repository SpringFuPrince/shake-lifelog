"""Check Claude Code's MCP connection using synthetic data and temporary configuration."""

import json
import os
from pathlib import Path
import subprocess
import sys

root = Path(sys.argv[1])
url = sys.argv[2]
env = os.environ.copy()
env.update(CLAUDE_CONFIG_DIR=str(root / "claude"), NO_PROXY="127.0.0.1,localhost",
           no_proxy="127.0.0.1,localhost", DISABLE_TELEMETRY="1",
           DISABLE_NON_ESSENTIAL_MODEL_CALLS="1")
configuration = {"type": "http", "url": url}

added = subprocess.run(
    ["claude", "mcp", "add-json", "--scope", "local", "shake", json.dumps(configuration)],
    cwd=root, env=env, capture_output=True, text=True, timeout=15,
)
if added.returncode:
    raise SystemExit("Claude Code could not write the isolated MCP configuration")

listed = subprocess.run(
    ["claude", "mcp", "list"], cwd=root, env=env, capture_output=True, text=True, timeout=15,
)
if listed.returncode or not any(line.startswith("shake:") and "Connected" in line for line in listed.stdout.splitlines()):
    raise SystemExit("Claude Code did not report a connected MCP server")
print("Claude Code connected to the local Shake MCP server")
