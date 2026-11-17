import json, os, subprocess, sys
from pathlib import Path
from datetime import datetime

home = Path(sys.argv[1])
url = sys.argv[2]
env = os.environ.copy()
env["CODEX_HOME"] = str(home)
env["CODEX_SQLITE_HOME"] = str(home)
env["NO_PROXY"] = "127.0.0.1,localhost"
env["no_proxy"] = env["NO_PROXY"]
p = subprocess.Popen(
    ["codex", "-c", f'mcp_servers.shake.url="{url}"', "app-server"],
    stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True, env=env
)
def call(i, method, params):
    p.stdin.write(json.dumps(dict(id=i, method=method, params=params)) + "\n")
    p.stdin.flush()
    for line in p.stdout:
        result = json.loads(line)
        if result.get("id") == i:
            if "error" in result:
                raise RuntimeError(result["error"].get("message"))
            return result["result"]
    raise RuntimeError(f"app-server closed while processing {method}")

try:
    call(1,"initialize",dict(clientInfo=dict(name="shake_acceptance",version="1.0"),capabilities=dict(experimentalApi=True)))
    p.stdin.write('{"method":"initialized"}\n')
    p.stdin.flush()
    status = call(2, "mcpServerStatus/list", dict(serverName="shake", detail="toolsAndAuthOnly"))
    expected = {"list_categories", "search_records", "get_records"}
    data = status["data"][0]
    assert set(data["tools"]) == expected, sorted(data["tools"])
    thread = call(3, "thread/start", dict(ephemeral=True, cwd=str(home), approvalPolicy="never", sandbox="read-only"))
    tid = thread["thread"]["id"]

    def tool(i, name, arguments):
        result = call(i, "mcpServer/tool/call", dict(threadId=tid, server="shake", tool=name, arguments=arguments))
        assert not result.get("isError"), f"{name} failed"
        return result

    def check_photo(result, record):
        assert record["photo"]["status"] == "available"
        index = record["photo"]["content_index"]
        block = result["content"][index]
        assert block["type"] == "image" and block["mimeType"] == "image/jpeg" and block.get("data")

    imported_ids = sys.argv[3:]
    if imported_ids:
        photo_id, meal_id, weight_id, knowledge_id = imported_ids
        detail = tool(10, "get_records", dict(ids=[photo_id, knowledge_id]))
        record = detail["structuredContent"]["records"][0]
        assert record["id"] == photo_id and record["fields"]["activity"] == "LAN QA walk"
        check_photo(detail, record)
        assert detail["structuredContent"]["records"][1]["id"] == knowledge_id
        photos = tool(11, "search_records", dict(category="sport", keyword="LAN QA walk"))
        check_photo(photos, photos["structuredContent"]["records"][0])

    assert len(tool(4, "list_categories", {})["structuredContent"]["categories"]) == 6
    today = datetime.now().date().isoformat()
    bounds = {"from": today, "to": today}

    def search(i, category, **kwargs):
        return tool(i, "search_records", dict(bounds, category=category, **kwargs))["structuredContent"]

    meal_page = search(5, "food", keyword="测试午餐")
    meal = meal_page["records"][0]
    assert meal["date"] == today and meal["fields"]["note"] == "测试午餐"
    assert "data_as_of" in meal_page

    weights = [record for record in search(7, "weight")["records"]
               if record["fields"].get("weight") is not None and not record["fields"].get("weightInherited")]
    assert len(weights) == 1 and weights[0]["fields"]["weight"] == 62.5
    knowledge = search(8, "knowledge")["records"][0]
    assert knowledge["fields"]["content"] == "合成知识记录"
    if imported_ids:
        assert (meal["id"], weights[0]["id"], knowledge["id"]) == (meal_id, weight_id, knowledge_id)
        print("Codex app-server verified both LAN-imported record reads include the JPEG")
    else:
        print("Codex app-server discovered three tools and verified full record queries")

finally:
    p.terminate()
    p.wait(timeout=5)
