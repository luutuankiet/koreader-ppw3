# koreader-ppw3

KOReader plugin development workspace + MCP device bridge for a fleet of Kindle Paperwhite 3 devices.

## What This Is

An autonomous agent dev loop for KOReader e-reader plugins. Edit Lua code, deploy to real Kindles over WiFi, navigate the UI programmatically, and verify with screenshots — all through MCP tool calls. Zero manual intervention.

## Architecture

### System Overview

```mermaid
flowchart LR
    A[Claude Agent] --> P[MCP Proxy<br/>mcpproxy-go]
    P --> GW[kindle-gateway<br/>Node.js :9999]
    GW -->|JSON-RPC| K1[koreader_mcp<br/>Kindle #1 :8888]
    GW -->|JSON-RPC| K2[koreader_mcp<br/>Kindle #2 :8888]
    K1 -->|phone-home<br/>POST /register| GW
    K2 -->|phone-home<br/>POST /register| GW
```

### Screenshot-in-Response Pipeline

Every L3 tool call returns the action result **plus** a native screenshot of the resulting UI:

```mermaid
sequenceDiagram
    participant A as Agent
    participant GW as kindle-gateway
    participant K as Kindle MCP
    A->>GW: send_event({event: "ShowMenu"})
    GW->>K: JSON-RPC: send_event
    K-->>GW: {sent: "ShowMenu"}
    Note over GW: Wait 1.5s<br/>(e-ink refresh)
    GW->>K: JSON-RPC: capture_screenshot
    K->>K: fbgrab → base64 → cleanup /tmp
    K-->>GW: {image_base64: "...", mime_type: "image/png"}
    GW->>GW: sharp resize<br/>1072×1448 → 536×724<br/>JPEG q50 (~20KB)
    GW-->>A: MCP response<br/>[{type: text, ...}, {type: image, ...}]
```

### Deploy + Restart Flow

```mermaid
sequenceDiagram
    participant A as Agent
    participant GW as kindle-gateway
    participant K as Kindle MCP
    A->>GW: deploy_plugin("kindle-1", "koreader_mcp")
    GW->>GW: Read .lua files<br/>from /workspace volume
    GW->>K: Pre-deploy: cleanup /tmp
    loop Each .lua file
        GW->>K: run_command(base64 decode → write)
    end
    GW->>K: run_command(nohup restart)
    Note over K: KOReader restarts<br/>(~15-20s boot)
    loop Health poll (10 × 5s)
        GW->>K: device_status?
    end
    K-->>GW: {model: "KindlePaperWhite3", ...}
    GW-->>A: {deployed: 5 files, restarted: true}
```

## Tools (13 total)

### Base Tools
| Tool | Description |
|------|-------------|
| `list_devices` | List registered Kindle devices + status |
| `read_files` | Read files from Kindle filesystem |
| `run_command` | Execute shell commands on Kindle |
| `device_status` | Battery, model, screen, WiFi info |

### L3 Semantic UI Tools (all return screenshot)
| Tool | Description |
|------|-------------|
| `get_current_view` | Widget stack introspection |
| `get_menu_items` | List items in visible menu |
| `select_menu_item` | Select by text (substring) or index |
| `go_back` | Navigate back in menu stack |
| `close_top_widget` | Dismiss dialogs/messages |
| `send_event` | Trigger KOReader events (ShowMenu, etc.) |

### Device Management
| Tool | Description |
|------|-------------|
| `screenshot` | Standalone capture (resized JPEG) |
| `restart_koreader` | Kill + restart + health poll |
| `deploy_plugin` | Transfer .lua files + restart |

## koreader_mcp.koplugin

Lua HTTP + JSON-RPC server running inside KOReader on the Kindle.

```mermaid
flowchart TD
    KO[KOReader] -->|loads plugin| MCP[koreader_mcp]
    MCP -->|socket.bind :8888| HTTP[HTTP Server]
    HTTP -->|JSON-RPC dispatch| H[handlers.lua]
    H --> RF[read_files]
    H --> RC[run_command]
    H --> DS[device_status]
    H --> L3[L3 Tools]
    L3 --> GCV[get_current_view<br/>UIManager widget stack]
    L3 --> GMI[get_menu_items<br/>Menu.item_table]
    L3 --> SMI[select_menu_item<br/>onMenuSelect / callback]
    L3 --> SE[send_event<br/>UIManager:broadcastEvent]
    L3 --> CS[capture_screenshot<br/>fbgrab + base64]
    MCP -->|on WiFi connect| PH[Phone-home<br/>POST /register]
```

Key implementation details:
- **FD_CLOEXEC** on listening socket via LuaJIT FFI — prevents child processes from inheriting port 8888
- **Auto /tmp cleanup** after screenshot capture (Kindle has 64MB tmpfs)
- Runs on Lua 5.1 (LuaJIT) with luasocket for HTTP

## Project Structure

Plugins live at workspace root as `<name>.koplugin/` directories. The kindle-gateway mounts the workspace root as `/workspace` (read-only) and reads plugins directly from there — no `dev/` subdir convention.

```
├── koreader_mcp.koplugin/        # MCP server plugin (Lua)
│   ├── handlers.lua             # All tool handlers (L3 + base)
│   ├── server.lua               # HTTP + JSON-RPC server
│   └── main.lua                 # KOReader plugin entry point
├── rssreader.koplugin/           # FreshRSS reader plugin (own git repo — see remotes)
├── kindle-gateway/               # MCP relay gateway (Node.js/TypeScript)
│   ├── src/
│   │   ├── gateway-server.ts     # 13 tools + forwardWithScreenshot
│   │   ├── kindle-client.ts      # JSON-RPC client (configurable timeout)
│   │   └── device-registry.ts    # In-memory device registry
│   ├── Dockerfile                # node:22-slim + sharp
│   └── docker-compose.yml        # network_mode: host, workspace volume
├── scripts/                      # Deploy scripts (shell-side fallbacks for the MCP deploy_plugin tool)
└── kosettings_backup/            # Device settings reference
```

## Quick Start

### Deploy plugin to Kindle

**Plugin discovery:** the gateway treats any `<name>.koplugin/` directory at workspace root as deployable. Pass the bare name (no `.koplugin` suffix) as the `plugin` arg. To add a new plugin, drop the dir at workspace root and it's immediately deployable.

```bash
# Via MCP tool (preferred — handles /tmp cleanup + restart + health poll):
kindle-gateway__deploy_plugin(device: "kindle-1", plugin: "koreader_mcp")
kindle-gateway__deploy_plugin(device: "kindle-1", plugin: "rssreader")

# Manual fallback (matches what deploy_plugin does internally):
scp koreader_mcp.koplugin/*.lua root@<kindle-ip>:/mnt/us/koreader/plugins/koreader_mcp.koplugin/
ssh root@<kindle-ip> 'killall luajit && cd /mnt/us/koreader && ./koreader.sh &'
```

**Known limitation:** the inline base64 transfer in `deploy_plugin` has an ARG_MAX cap on BusyBox shell (~48KB raw / ~64KB base64). Files above that silently truncate while still reporting success. For large files, fall back to a thinkpad-side `python3 -m http.server` + `wget` from kindle, or use the `scripts/deploy-rssreader.sh` tarball path.

### Rebuild gateway
```bash
cd kindle-gateway
npx tsc --noEmit                    # typecheck
PORT=9998 npx tsx src/index.ts      # local dev test first!
# verify tools: curl localhost:9998/health
docker compose build && docker compose up -d

# Reconnect proxy + approve new tools
curl -s -X POST -H 'X-API-Key: <key>' localhost:8888/api/v1/servers/kindle-gateway/restart
curl -s -X POST -H 'X-API-Key: <key>' -H 'Content-Type: application/json' \
  -d '{"approve_all": true}' localhost:8888/api/v1/servers/kindle-gateway/tools/approve
```

### Agent interaction example
```
→ send_event(device: "kindle-1", params: '{"event": "ShowMenu"}')
← {sent: "ShowMenu"} + [screenshot of KOReader menu]

→ select_menu_item(device: "kindle-1", params: '{"text": "FreshRSS"}')
← {selected_text: "FreshRSS", action: "invoked_callback"} + [screenshot]

→ get_menu_items(device: "kindle-1")
← {items: [...], total_items: 7} + [screenshot]
```

## Known Patterns & Anti-Patterns

| Pattern | Why |
|---------|-----|
| Use `send_event` for UI navigation | `evemu-event` (raw touch) froze 2 Kindles |
| Never nest curl through Kindle MCP | Single-threaded Lua deadlocks on self-calls |
| Hot dev loop: PORT=9998 first | Avoids proxy disruption during iteration |
| FD_CLOEXEC on server socket | Prevents port 8888 zombie after restart |
| Pre-deploy /tmp cleanup | 64MB tmpfs fills from fbgrab dumps |
| Approve tools after gateway rebuild | Proxy auto-quarantines new/changed tools |

## Kindle Fleet

2× Kindle Paperwhite 3, jailbroken, USBNet (OpenSSH port 22), KOReader v2025.04.

## License

GNU Affero General Public License v3.0, the same license as KOReader. See [LICENSE](LICENSE).
