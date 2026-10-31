#!/usr/bin/env python3
"""Stand-in for cua_repl in tests: a line-delimited JSON-RPC MCP server that logs what it gets.

Its start, every line it receives and its exit are appended as JSON to $FAKE_LOG (when set).
The `js` tool understands two `code` values: "crash" exits without answering, and "elicit" (or
"elicit:<app>") asks the client to approve Calculator (or <app>) and returns the answer. Any other
call returns its `_meta`.
The first `js` result of each process starts with a long documentation block, like cua_repl's.
"""
import json
import os
import sys

LOG = os.environ.get("FAKE_LOG")
DOCS = "# cua_repl documentation\n" + "Use cua.getApp(name) to get an app.\n" * 200
TOOLS = [{"name": name, "inputSchema": {"type": "object"}} for name in ("js", "js_reset")]


def log(event, **fields):
    if LOG:
        with open(LOG, "a") as handle:
            handle.write(json.dumps({"event": event, "pid": os.getpid(), **fields}) + "\n")


def send(message):
    sys.stdout.write(json.dumps({"jsonrpc": "2.0", **message}) + "\n")
    sys.stdout.flush()


def texts(request_id, *items):
    send({"id": request_id, "result": {"content": [{"type": "text", "text": item} for item in items]}})


def main():
    log("start", surfaces=os.environ.get("CUA_REPL_ENABLED_SURFACES"))
    docs_sent = False
    for line in sys.stdin:
        message = json.loads(line)
        log("recv", message=message)
        method, request_id = message.get("method"), message.get("id")
        if method == "initialize":
            send({"id": request_id, "result": {"protocolVersion": message["params"]["protocolVersion"],
                                               "capabilities": {"tools": {}},
                                               "instructions": "Fake cua_repl.",
                                               "serverInfo": {"name": "fake-cua-repl", "version": "1"}}})
        elif method == "tools/list":
            send({"id": request_id, "result": {"tools": TOOLS}})
        elif method == "tools/call":
            params = message["params"]
            name, code = params["name"], (params.get("arguments") or {}).get("code")
            if name == "js" and code == "crash":
                log("exit", code=1)
                sys.exit(1)
            if name == "js" and code.startswith("elicit"):
                app = code.partition(":")[2] or "Calculator"
                send({"id": "elicit-1", "method": "elicitation/create", "params": {
                    "message": f'Allow Computer Use to use "{app}"?',
                    "requestedSchema": {"type": "object", "properties": {}}}})
                answer = json.loads(sys.stdin.readline())
                log("recv", message=answer)
                texts(request_id, json.dumps(answer.get("result")))
                continue
            meta = json.dumps(params.get("_meta"))
            if name == "js" and not docs_sent:
                docs_sent = True
                texts(request_id, DOCS, meta)
            else:
                texts(request_id, meta)
        elif method is not None and request_id is not None:
            send({"id": request_id, "error": {"code": -32601, "message": f"Method not found: {method}"}})
    log("exit", code=0)


if __name__ == "__main__":
    main()
