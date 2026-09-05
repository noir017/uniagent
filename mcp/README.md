# `recall` — fast Hindsight memory lookup as an MCP tool

One MCP server exposing one tool, `recall`. It answers "what does memory know about X"
in **1–3 seconds**, and every agent in this image can call it as a native tool.

## Why it exists

The `hindsight-coding-agents` plugin gives an agent two ways to read memory, and on
this deployment both were unusable:

| | what it does | here |
|---|---|---|
| `search_knowledge_pages` | searches synthesized summary pages | returned `[]` — the bank had no pages for weeks |
| `hindsight_reflect` | synthesizes the **whole** bank | 112 s at `budget: low`, **HTTP 504** at the default `high` |

The pages were empty for a structural reason: they are only ever created by
`deepen.js`, which the session-start hook spawns behind two conditions —
`autoSeed !== false` **and** the session directory being a git repo. This deployment
satisfies neither (`autoSeed: false`, and `/home/user/workspace` is not a repo), so
`configureBank()` → `seedPages()` never ran and the fast path never existed. Every
lookup therefore fell through to `reflect`, which on a bank this size (219k tokens,
shared by every agent) exceeded the server's wall timeout.

Meanwhile Hermes — the chat agent on the same bank — had never hit any of this,
because it does not use the plugin. It calls `POST /memories/recall` directly. Its
own log:

```
[RECALL agent-30000-fa274b] Complete: 4 facts (491 tok), 36 entities | 1.643s
```

Same memory, ~70x faster, because it retrieves a handful of relevant facts instead of
reasoning over everything. The plugin simply does not expose that endpoint as a tool.
This does.

`reflect` still has its place — genuine "why did we decide X" questions that need
reasoning across many memories. It is just the wrong default.

## What is here

| file | |
|---|---|
| `hindsight-recall.mjs` | the MCP server. stdio, JSON-RPC 2.0, **no dependencies** (node ≥ 18 has `fetch`) |
| `install-hindsight-recall.ps1` | Windows installer for Claude Code + opencode |
| `patch-config.mjs` | registers the server in a host's JSON config (used by the installer) |
| `test-recall.ps1` | end-to-end check on Windows |

Configuration is read from `~/.hindsight/coding-agent.json` (`apiUrl`, `bankId`,
`apiToken`), so it tracks the plugin's own settings rather than drifting from them.
`HINDSIGHT_API_URL`, `HINDSIGHT_BANK_ID`, `HINDSIGHT_API_TOKEN` and
`HINDSIGHT_RECALL_TIMEOUT_MS` override it — the installer passes the first two
explicitly so the tool works on a machine with no plugin installed.

## Registering it

The server is one file; each host just needs a pointer to it. Registration lives in
each agent's own config under `/home/user`, which is a persistent volume — so it
survives image updates and is **not** baked into the image.

**Claude Code** — `~/.claude.json`:

```json
{ "mcpServers": { "hindsight-recall": {
  "type": "stdio", "command": "node", "args": ["/usr/local/lib/hindsight-recall/hindsight-recall.mjs"] } } }
```

**opencode** — `~/.config/opencode/opencode.json`:

```json
{ "mcp": { "hindsight-recall": {
  "type": "local", "enabled": true,
  "command": ["node", "/usr/local/lib/hindsight-recall/hindsight-recall.mjs"] } } }
```

**Antigravity CLI** — `~/.gemini/config/mcp_config.json`, same shape as Claude Code's.

Verify with `claude mcp list`, `opencode mcp list`, `agy mcp list` — each should report
`hindsight-recall`. MCP servers start when a session starts, so restart the agent first.

## Windows

`install-hindsight-recall.ps1` does all of the above on a laptop, backing up every
config before touching it:

```powershell
powershell -ExecutionPolicy Bypass -File .\install-hindsight-recall.ps1
```

Three things that cost a debugging round each, kept here so they are not re-learned:

- **The `.ps1` files must keep their UTF-8 BOM.** Windows PowerShell 5.1 decodes a
  BOM-less file as the system ANSI codepage — GBK on a Chinese install — which turned
  the em dashes in the embedded server into `鈥?` and a Chinese test query into
  `鍙戝竷娴佺▼`.
- **JSON is edited by node, never by PowerShell.** `ConvertTo-Json` defaults to
  `-Depth 2` on 5.1 and would silently truncate a nested `.claude.json` (44 top-level
  keys, 16 project entries) instead of failing.
- **`claude` / `opencode` / `node` write banners to stderr**, which under
  `$ErrorActionPreference = 'Stop'` is raised as a terminating `NativeCommandError`.
  The verification step relaxes it, or a working install reports as a failure.

The memory server resolves to `192.168.0.10` — a LAN address, even from public DNS —
so a laptop reaches it only from the home network or a VPN back to it. The installer
checks and says so rather than leaving you to wonder.
