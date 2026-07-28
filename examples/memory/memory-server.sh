#!/bin/sh
# An MCP memory server, in POSIX shell.
#
# It exists to make one point from para/ai's design concrete: **memory is a server, not a subsystem
# of the agent harness.** para/ai ships no store, no embedder, and no recall heuristic — it ships
# the client that talks to whichever one you point it at. If sixty lines of shell can be the memory
# server, so can a vector database, a git repo, a team wiki, or the memory server you already run
# for another agent. That is the whole argument for putting memory behind MCP: it is swappable,
# inspectable, and shared.
#
# Two tools, one flat file, one fact per line:
#
#   remember(fact)  — append a fact
#   recall(about)   — every fact matching a substring, case-insensitively
#
# Speaks MCP over stdio: one JSON-RPC document per line on stdin, one per line on stdout. Nothing
# but `grep`, `tr`, `awk`, and `printf` — no jq, no node, no python.
#
#   sh memory-server.sh /path/to/memory.db
#
# The JSON parsing is deliberately crude (it splits on commas and takes the last quoted field), which
# is fine for a demonstration server and is *not* how a real one should read its input. A fact
# containing a comma or a double quote will not survive the round trip. A real server parses JSON.

store="$1"
if [ -z "$store" ]; then
    store="./memory.db"
fi
if [ ! -f "$store" ]; then
    : > "$store"
fi

# The JSON-RPC id of a request: the first `"id":` field, digits only.
idof() {
    printf '%s\n' "$1" | tr ',' '\n' | grep '"id":' | head -1 | tr -dc '0-9'
}

# The value of a string field, taken from the last fragment that names it.
argof() {
    printf '%s\n' "$2" | tr ',' '\n' | grep "\"$1\":" | tail -1 | awk -F'"' '{print $(NF-1)}'
}

while IFS= read -r line; do
    id=$(idof "$line")
    case "$line" in
        *'"method":"notifications/'*)
            # A notification has no id and takes no answer. `notifications/initialized` is the
            # client saying the handshake is done.
            ;;
        *'"method":"initialize"'*)
            printf '{"jsonrpc":"2.0","id":%s,"result":{"protocolVersion":"2025-06-18","capabilities":{"tools":{}},"serverInfo":{"name":"memory","version":"0.1.0"}}}\n' "$id"
            ;;
        *'"method":"tools/list"'*)
            printf '{"jsonrpc":"2.0","id":%s,"result":{"tools":[' "$id"
            printf '{"name":"remember","description":"Store a fact for later. Use it whenever the user tells you something worth keeping.","inputSchema":{"type":"object","properties":{"fact":{"type":"string","description":"The fact to store, as one sentence"}},"required":["fact"]}},'
            printf '{"name":"recall","description":"Look up stored facts. Use it before answering anything about the user.","inputSchema":{"type":"object","properties":{"about":{"type":"string","description":"A word or phrase to search the stored facts for"}},"required":["about"]}}'
            printf ']}}\n'
            ;;
        *'"method":"tools/call"'*)
            tool=$(argof name "$line")
            case "$tool" in
                remember)
                    fact=$(argof fact "$line")
                    printf '%s\n' "$fact" >> "$store"
                    printf '{"jsonrpc":"2.0","id":%s,"result":{"content":[{"type":"text","text":"remembered: %s"}]}}\n' "$id" "$fact"
                    ;;
                recall)
                    about=$(argof about "$line")
                    hits=$(grep -i -- "$about" "$store" | tr '\n' ';')
                    if [ -z "$hits" ]; then
                        hits="nothing on file about that"
                    fi
                    printf '{"jsonrpc":"2.0","id":%s,"result":{"content":[{"type":"text","text":"%s"}]}}\n' "$id" "$hits"
                    ;;
                *)
                    # An unknown tool is a JSON-RPC error, which the client turns into a failed tool
                    # turn — the model is told, and gets to try something else.
                    printf '{"jsonrpc":"2.0","id":%s,"error":{"code":-32602,"message":"no tool named %s"}}\n' "$id" "$tool"
                    ;;
            esac
            ;;
        *'"method":"ping"'*)
            printf '{"jsonrpc":"2.0","id":%s,"result":{}}\n' "$id"
            ;;
        *)
            printf '{"jsonrpc":"2.0","id":%s,"error":{"code":-32601,"message":"no such method"}}\n' "$id"
            ;;
    esac
done
