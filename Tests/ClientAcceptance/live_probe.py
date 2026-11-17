"""Use the configured model with a temporary MCP server holding synthetic records."""

from datetime import date
import json
import os
from pathlib import Path
import re
import subprocess
import sys


root, url, client, *expected_ids = sys.argv[1:]
today = date.today().isoformat()
env = os.environ.copy()
env["NO_PROXY"] = ",".join(filter(None, [env.get("NO_PROXY"), "127.0.0.1", "localhost"]))
env["no_proxy"] = env["NO_PROXY"]
env.pop("CLAUDECODE", None)

if client in ("codex", "codex-vision"):
    skill = Path(__file__).resolve().parents[2] / "Skills" / "shake-life-log"
    prompt = (
        f"只用 shake MCP 查询 {today} 的合成验收记录。用 search_records 分别查饮食和知识，"
        "用 search_records 查体重，从记录字段中排除沿用值。"
        "用中文简短回顾午餐、已确认体重和知识正文，每项写出日期和完整记录 ID。"
        "说明 data_as_of 为空代表同步时间未知。"
    ) if client == "codex" else (
        f"{(skill / 'SKILL.md').read_text()}\n\n"
        f"{(skill / 'references/food.md').read_text()}\n\n"
        f"当前本地日期为 {today}。\n用户请求：分析一下我今天的饮食，聊聊吃了些什么，有依据的话帮我看看热量。"
    )
    command = [
        "codex", "-c", 'approval_policy="never"', "-c", f'mcp_servers.shake.url="{url}"',
        "--disable", "shell_tool", "--disable", "unified_exec", "exec", "--ignore-user-config",
        "--ignore-rules", "--ephemeral", "--skip-git-repo-check", "--sandbox", "read-only",
        "--json", "--", prompt,
    ]
else:
    config = {"mcpServers": {"shake": {"type": "http", "url": url}}}
    config_path = Path(root) / "claude-mcp.json"
    with os.fdopen(os.open(config_path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600), "w") as file:
        json.dump(config, file)
    command = [
        "claude", "--print", "--output-format", "stream-json", "--verbose", "--no-session-persistence",
        "--strict-mcp-config", "--mcp-config", str(config_path), "--tools", "",
        "--settings", '{"disableAllHooks":true,"autoMemoryEnabled":false}',
        "--allowedTools", "mcp__shake__search_records", "--permission-mode", "dontAsk", "--",
        f"只调用一次 shake 的 search_records 查询 {today} 的 food 合成记录，返回记录中的午餐备注。",
    ]
    env["DISABLE_TELEMETRY"] = "1"

run = subprocess.run(command, cwd=root, env=env, capture_output=True, text=True, timeout=105)
events = []
for line in run.stdout.splitlines():
    try:
        events.append(json.loads(line))
    except json.JSONDecodeError:
        continue

if run.returncode:
    diagnostic = (run.stderr + run.stdout).lower()
    if any(marker in diagnostic for marker in ("usage limit", "rate limit", "usage_limit_reached", "quota")):
        raise SystemExit(f"{client}: configured model is rate limited")
    if any(marker in diagnostic for marker in ("unauthorized", "not logged in", "authentication", "invalid api key")):
        raise SystemExit(f"{client}: configured model requires authentication")
    raise SystemExit(f"{client}: live session failed (exit {run.returncode})")

if client in ("codex", "codex-vision"):
    items = [event["item"] for event in events if event.get("type") == "item.completed"]
    calls = {item["tool"] for item in items if item.get("type") == "mcp_tool_call"
             and item.get("server") == "shake" and item.get("status") == "completed"}
    answer = [item["text"] for item in items if item.get("type") == "agent_message"][-1]
if client == "codex":
    assert "search_records" in calls, "Codex did not query the records"
    for text in ("测试午餐", "62.5", "合成知识记录", today):
        assert text in answer, f"Codex answer omitted {text}"
    citations = re.findall(r"\b[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}\b", answer)
    assert set(map(str.lower, citations)) == set(map(str.lower, expected_ids)), "Codex citations did not match the records"
    assert "data_as_of" in answer and "同步" in answer, "Codex answer omitted data freshness"
    print("Codex model used Shake MCP and cited meal, confirmed weight, and knowledge records")
elif client == "codex-vision":
    photos_read = set()
    for item in items:
        if (item.get("type") != "mcp_tool_call" or item.get("server") != "shake"
                or item.get("status") != "completed" or item.get("tool") not in {"search_records", "get_records"}):
            continue
        result = item.get("result") or {}
        blocks = result.get("content") or []
        structured = result.get("structuredContent") or result.get("structured_content")
        if structured is None and blocks and blocks[0].get("type") == "text":
            try:
                structured = json.loads(blocks[0]["text"])
            except (KeyError, json.JSONDecodeError):
                continue
        for record in (structured or {}).get("records", []):
            index = record.get("photo", {}).get("content_index")
            if isinstance(index, int) and 0 <= index < len(blocks) and blocks[index].get("type") == "image":
                photos_read.add(record["id"])
    assert set(expected_ids) <= photos_read, "Codex did not receive both meal JPEGs with the records"
    assert "红" in answer and any(color in answer for color in ("白", "浅粉", "浅色")), (
        "Codex did not mention visible details of the non-food image"
    )
    calories = re.findall(r"(?<![\d.])(\d+(?:\.\d+)?)(?:\*\*)?\s*(?:千卡|大卡|kcal)", answer, re.IGNORECASE)
    assert calories and all(float(value) == 230 for value in calories), (
        f"Codex failed to read the label or invented another calorie number: {calories}"
    )
    print("Codex read both meal photos, reported the label's calories, and did not invent calories for the non-food photo")
else:
    uses = [block for event in events if event.get("type") == "assistant"
            for block in event["message"]["content"] if block.get("type") == "tool_use"]
    assert [block["name"] for block in uses] == ["mcp__shake__search_records"], "Claude Code did not call Shake exactly once"
    replies = [block for event in events if event.get("type") == "user"
               for block in event["message"]["content"]
               if block.get("type") == "tool_result" and block.get("tool_use_id") == uses[0]["id"]]
    assert len(replies) == 1 and not replies[0].get("is_error"), "Claude Code did not receive a successful MCP result"
    result = json.dumps(replies[0]["content"], ensure_ascii=False)
    assert expected_ids[0] in result and "测试午餐" in result, "The MCP result did not contain the synthetic meal"
    print("Claude Code invoked Shake search_records and returned the synthetic meal")
