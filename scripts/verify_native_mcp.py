"""Verify an extracted native candidate with the official MCP client SDK.

Development dependency: mcp==2.3.0. This is not desktop-host acceptance.
All mutable files are confined to a fresh temporary directory.
"""
import argparse
import asyncio
from contextlib import asynccontextmanager
from datetime import datetime, timezone
import hashlib
import importlib.metadata
import json
from pathlib import Path
import shutil
import tempfile
import uuid

from mcp import ClientSession, StdioServerParameters
from mcp.client.stdio import stdio_client


async def verify(plugin, output):
    report = {"observed_at": datetime.now(timezone.utc).isoformat(),
              "client": "official Python MCP SDK", "sdk_version": importlib.metadata.version("mcp"),
              "desktop_host_acceptance": "NOT VERIFIED", "checks": []}
    report["binary_sha256"] = hashlib.sha256((plugin / "bin/orbit-mcp").read_bytes()).hexdigest()
    with tempfile.TemporaryDirectory(prefix="orbit-sdk-acceptance-") as temporary:
        base = Path(temporary).resolve()
        relocated = base / "plugin with spaces"
        shutil.copytree(plugin, relocated)
        manifests = [json.loads((relocated / name).read_text())["mcpServers"]
                     for name in (".codex.mcp.json", ".mcp.json")]
        servers = [next(iter(value.values())) for value in manifests]
        servers.append(json.loads((relocated / "manifest.json").read_text())["server"]["mcp_config"])

        @asynccontextmanager
        async def connect(index):
            server = servers[index]
            command = server["command"].replace("${CLAUDE_PLUGIN_ROOT}", str(relocated)).replace("${__dirname}", str(relocated))
            # Replace only test configuration paths; retain each packaged launcher.
            args = list(server["args"])
            for flag, value in (("--config", base / "config.json"), ("--cache", base / "cache"), ("--state", base / "state")):
                if flag in args:
                    args[args.index(flag) + 1] = str(value)
                else:
                    args.extend([flag, str(value)])
            params = StdioServerParameters(command=command, args=args, cwd=relocated,
                                           env={"PATH": "/usr/bin:/bin"})
            async with stdio_client(params) as (read, write):
                async with ClientSession(read, write) as session:
                    initialized = await session.initialize()
                    tools = await session.list_tools()
                    assert len(tools.tools) == 19, len(tools.tools)
                    await session.send_ping()
                    report["checks"].append({"check": "initialize/discover/ping", "manifest": index,
                                              "protocol": initialized.protocol_version, "tools": len(tools.tools)})
                    yield session

        async def call(session, action, arguments, error=False):
            result = await session.call_tool("orbit_" + action, arguments)
            assert bool(result.is_error) == error, result
            if error:
                return result
            return json.loads(result.content[0].text)

        folder = base / "disposable folder"
        path = "Knowledge/Native.md"
        content = "---\nid: sdk-native\ntitle: Native\ntype: concept\nsummary: Native SDK persistence\ncustom: Preserve this user metadata\n---\n# Native\nExact approved café content.\n"
        plan = {"request_id": str(uuid.uuid4()), "changes": [{"path": path, "content": content,
                "reason": "disposable SDK acceptance", "expected_sha256": None}]}
        scoped = {"orbit": "SDKAcceptance"}
        async with connect(0) as session:
            setup = await call(session, "setup", {"name": "SDKAcceptance", "path": str(folder), "create": True})
            assert setup["target"]["path"] == str(folder)
            saved = await call(session, "apply", {**scoped, "plan": plan})
            assert saved["verified"]
            await call(session, "apply", {**scoped, "plan": plan})
            assert (folder / path).read_bytes() == content.encode()
            assert (await call(session, "search", {**scoped, "query": "persistence"}))["results"]
            read = await call(session, "read", {**scoped, "path": path})
            assert read["sha256"] == hashlib.sha256(content.encode()).hexdigest()
            history = await call(session, "sync", {**scoped, "action": "history", "path": path})
            assert len(history["revisions"]) == 1, history
            stale = {"request_id": str(uuid.uuid4()), "changes": [{**plan["changes"][0], "content": content + "Rejected\n", "expected_sha256": "0" * 64}]}
            await call(session, "apply", {**scoped, "plan": stale}, error=True)
            await call(session, "read", {**scoped, "path": "../escape.md"}, error=True)
            assert (folder / path).read_bytes() == content.encode()
            report["checks"].append({"check": "setup/save/search/read/hash/idempotent-retry/history/stale-and-path-refusal", "passed": True})
        for index in (1, 2):
            async with connect(index) as session:
                restored = await call(session, "read", {**scoped, "path": path})
                assert restored["sha256"] == read["sha256"]
                assert restored["target"] == read["target"]
                assert (await call(session, "search", {**scoped, "query": "persistence"}))["results"]
                report["checks"].append({"check": "fresh-process-cross-manifest-persistence", "manifest": index, "passed": True})
                if index == 1:
                    updated = content + "\nApproved update survives cache loss.\n"
                    update = {"request_id": str(uuid.uuid4()), "changes": [{
                        **plan["changes"][0], "content": updated, "expected_sha256": read["sha256"]}]}
                    assert (await call(session, "apply", {**scoped, "plan": update}))["verified"]
                    content = updated
                    read = await call(session, "read", {**scoped, "path": path})
                    assert read["sha256"] == hashlib.sha256(content.encode()).hexdigest()
                else:
                    history = await call(session, "sync", {**scoped, "action": "history", "path": path})
                    assert len(history["revisions"]) == 2, history
                    assert any("Approved update survives cache loss." in revision["content"] for revision in history["revisions"])
                    assert (folder / path).read_bytes() == content.encode()
                    report["checks"].append({"check": "approved-update-and-history-survive-cache-loss", "passed": True})
            if index == 1:
                shutil.rmtree(base / "cache")
        assert not any(p.suffix == ".py" for p in relocated.rglob("*"))
        report["checks"].append({"check": "native-package-has-no-python-runtime", "passed": True})
    report["status"] = "passed"
    output.write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps({"status": report["status"], "checks": len(report["checks"]), "sdk": report["sdk_version"]}))


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--plugin", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    options = parser.parse_args()
    asyncio.run(verify(options.plugin.resolve(), options.output.resolve()))
