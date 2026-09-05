#requires -Version 5.1
<#
.SYNOPSIS
  Installs the "recall" MCP tool (fast Hindsight memory lookup) for Claude Code
  and opencode on Windows.

.DESCRIPTION
  Adds one MCP server exposing a single tool, `recall`, which queries Hindsight's
  /memories/recall endpoint. That endpoint answers in 1-3 seconds, where the
  plugin's built-in hindsight_reflect synthesizes the whole bank and takes
  minutes (or times out).

  Safe to re-run: every config file is backed up before it is touched, and the
  entry is simply refreshed.

  NOTE the memory server lives on the home LAN (192.168.0.10). This only works
  when the laptop is on that network or on a VPN back to it.

.PARAMETER ApiUrl
  Hindsight API base URL.

.PARAMETER Bank
  Memory bank id.

.PARAMETER SkipTest
  Skip the connectivity and end-to-end checks.

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File .\install-hindsight-recall.ps1
#>
[CmdletBinding()]
param(
  [string]$ApiUrl = 'https://hindsight-api.lan.noharanas.eu.org',
  [string]$Bank   = 'agent',
  [switch]$SkipTest
)

$ErrorActionPreference = 'Stop'

function Say  ($m) { Write-Host "     $m" }
function Good ($m) { Write-Host "OK   $m" -ForegroundColor Green }
function Warn ($m) { Write-Host "WARN $m" -ForegroundColor Yellow }
function Bad  ($m) { Write-Host "FAIL $m" -ForegroundColor Red }
function Step ($m) { Write-Host ""; Write-Host "== $m" -ForegroundColor Cyan }

# Write without a BOM: a BOM is fine for node but shows up in diffs and in any
# tool that reads these files as plain text.
function Write-Utf8NoBom([string]$Path, [string]$Text) {
  $dir = Split-Path -Parent $Path
  if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
  [System.IO.File]::WriteAllText($Path, $Text, (New-Object System.Text.UTF8Encoding($false)))
}

$Home_ = $env:USERPROFILE
if (-not $Home_) { $Home_ = $HOME }

Write-Host ""
Write-Host "Hindsight recall - MCP installer for Claude Code and opencode" -ForegroundColor White
Say "user profile : $Home_"
Say "api          : $ApiUrl"
Say "bank         : $Bank"

# ---------------------------------------------------------------- 1. node
Step "Checking node"
$nodeCmd = Get-Command node -ErrorAction SilentlyContinue
if (-not $nodeCmd) {
  Bad "node is not on PATH. Install Node.js 18+ (https://nodejs.org) and re-run."
  exit 1
}
$nodeVer = (& node --version) 2>$null
$major = 0
if ($nodeVer -match '^v(\d+)\.') { $major = [int]$Matches[1] }
if ($major -lt 18) {
  Bad "node $nodeVer is too old - this server uses built-in fetch, which needs node 18+."
  exit 1
}
Good "node $nodeVer  ($($nodeCmd.Source))"

# ------------------------------------------------------- 2. reachability
if (-not $SkipTest) {
  Step "Checking the memory server is reachable"
  try {
    $sw = [Diagnostics.Stopwatch]::StartNew()
    Invoke-WebRequest -Uri "$ApiUrl/health" -TimeoutSec 15 -UseBasicParsing | Out-Null
    $sw.Stop()
    Good "reachable ($([int]$sw.ElapsedMilliseconds) ms)"
  } catch {
    Warn "cannot reach $ApiUrl"
    Say  "That server is on the home LAN (192.168.0.10). Off the home network"
    Say  "you need a VPN back to it, or the API exposed on a public hostname."
    Say  "Install will continue - the tool simply returns an error until you can reach it."
  }
}

# ------------------------------------------------------- 3. server file
Step "Installing the MCP server"
$serverPath = Join-Path $Home_ '.claude\mcp-servers\hindsight-recall.mjs'
$serverJs = @'
#!/usr/bin/env node
/**
 * Minimal MCP stdio server exposing Hindsight's fast /memories/recall endpoint.
 *
 * Why this exists: the hindsight-coding-agents plugin exposes only knowledge-page
 * search (empty on banks whose pages were never seeded) and reflect (full-memory
 * synthesis — 112s on this bank at "low", 504 at "high"). Raw recall answers the
 * same questions in 1-3s. Hermes has always used it directly; this makes it a
 * first-class tool here too.
 *
 * No dependencies: node >= 18 has fetch, and MCP over stdio is line-delimited
 * JSON-RPC 2.0.
 */
import { readFileSync } from 'fs';
import { homedir } from 'os';
import { join } from 'path';

const CONFIG_PATH = process.env.HINDSIGHT_CONFIG || join(homedir(), '.hindsight', 'coding-agent.json');
const DEFAULT_API = 'https://api.hindsight.vectorize.io';
/** Request ceiling. Override with HINDSIGHT_RECALL_TIMEOUT_MS when a bank is habitually slow. */
const TIMEOUT_MS = Number(process.env.HINDSIGHT_RECALL_TIMEOUT_MS) || 120_000;

/** Read apiUrl/bankId/apiToken from the plugin's own config so this tracks it rather than drifting. */
function loadConfig() {
  let raw = {};
  try {
    raw = JSON.parse(readFileSync(CONFIG_PATH, 'utf8'));
  } catch {
    // No config, or unreadable: fall back to env entirely.
  }
  return {
    apiUrl: (process.env.HINDSIGHT_API_URL || raw.apiUrl || DEFAULT_API).replace(/\/+$/, ''),
    bank: process.env.HINDSIGHT_BANK_ID || raw.bankId || 'agent',
    token: process.env.HINDSIGHT_API_TOKEN || raw.apiToken || '',
  };
}

const TOOL = {
  name: 'recall',
  description:
    "Fast keyword+semantic lookup over this machine's Hindsight memory (bank from ~/.hindsight/coding-agent.json). " +
    'Returns the handful of stored facts most relevant to the query, typically in 1-3 seconds. ' +
    'Use this as the DEFAULT way to ask what memory knows — past decisions, config values, deployment details, ' +
    'conventions, prior debugging. Prefer it over hindsight_reflect, which synthesizes the entire bank and takes ' +
    'minutes or times out. Reach for reflect only when recall returns too little and you need reasoning across many memories.',
  inputSchema: {
    type: 'object',
    properties: {
      query: {
        type: 'string',
        description: 'What to look for. Natural language; keywords and proper nouns help. Chinese or English.',
      },
      max_tokens: {
        type: 'integer',
        description: 'Token budget for returned facts (default 800). Raise for broader context.',
        minimum: 100,
        maximum: 8000,
      },
      budget: {
        type: 'string',
        enum: ['low', 'mid', 'high'],
        description: 'Retrieval effort (default low). low is ~1-3s and is almost always enough.',
      },
    },
    required: ['query'],
  },
};

async function recall(args) {
  const { apiUrl, bank, token } = loadConfig();
  const url = `${apiUrl}/v1/default/banks/${encodeURIComponent(bank)}/memories/recall`;
  const body = {
    query: String(args.query ?? ''),
    budget: args.budget || 'low',
    max_tokens: Number(args.max_tokens) || 800,
  };

  const ctrl = new AbortController();
  // A warm server answers in 1-3s, but recall queues behind consolidation and knowledge-page
  // synthesis on a busy bank — a 60s ceiling timed one out that curl then served in 3s.
  const timer = setTimeout(() => ctrl.abort(), TIMEOUT_MS);
  let resp;
  try {
    resp = await fetch(url, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        ...(token ? { Authorization: `Bearer ${token}` } : {}),
      },
      body: JSON.stringify(body),
      signal: ctrl.signal,
    });
  } catch (e) {
    const why = e.name === 'AbortError' ? `timed out after ${Math.round(TIMEOUT_MS / 1000)}s` : e.message;
    return `recall failed: ${why} (${url})`;
  } finally {
    clearTimeout(timer);
  }

  if (!resp.ok) {
    const detail = await resp.text().catch(() => '');
    return `recall failed: HTTP ${resp.status} ${detail.slice(0, 400)}`;
  }

  const data = await resp.json().catch(() => null);
  const results = data?.results ?? [];
  if (!results.length) return `No memories matched "${body.query}" in bank "${bank}".`;

  const lines = results.map((r, i) => {
    const score = r.scores?.final;
    const when = (r.mentioned_at || '').slice(0, 10);
    const meta = [r.type, when, score != null ? `score ${score.toFixed(2)}` : null].filter(Boolean).join(' · ');
    return `[${i + 1}] ${meta}\n${(r.text || '').trim()}`;
  });
  return `${results.length} memory result(s) from bank "${bank}":\n\n${lines.join('\n\n')}`;
}

// ---- MCP stdio plumbing: line-delimited JSON-RPC 2.0 ----

function send(msg) {
  process.stdout.write(JSON.stringify(msg) + '\n');
}

function reply(id, result) {
  send({ jsonrpc: '2.0', id, result });
}

function replyError(id, code, message) {
  send({ jsonrpc: '2.0', id, error: { code, message } });
}

async function handle(msg) {
  const { id, method, params } = msg;
  // Notifications carry no id and expect no response.
  if (id === undefined || id === null) return;

  switch (method) {
    case 'initialize':
      return reply(id, {
        // Echo the client's version when it names one, so we don't force a downgrade.
        protocolVersion: params?.protocolVersion || '2024-11-05',
        capabilities: { tools: {} },
        serverInfo: { name: 'hindsight-recall', version: '1.0.0' },
      });
    case 'tools/list':
      return reply(id, { tools: [TOOL] });
    case 'tools/call': {
      if (params?.name !== TOOL.name) {
        return replyError(id, -32602, `Unknown tool: ${params?.name}`);
      }
      try {
        const text = await recall(params.arguments || {});
        return reply(id, { content: [{ type: 'text', text }] });
      } catch (e) {
        return reply(id, { content: [{ type: 'text', text: `recall failed: ${e.message}` }], isError: true });
      }
    }
    case 'ping':
      return reply(id, {});
    default:
      return replyError(id, -32601, `Method not found: ${method}`);
  }
}

// A recall can still be in flight when stdin closes; exiting then would drop its
// response. Track outstanding work and leave only once it has drained.
let pending = 0;
let stdinEnded = false;
function maybeExit() {
  if (stdinEnded && pending === 0) process.exit(0);
}

let buf = '';
process.stdin.setEncoding('utf8');
process.stdin.on('data', (chunk) => {
  buf += chunk;
  // A single chunk may hold several messages, or half of one.
  let nl;
  while ((nl = buf.indexOf('\n')) >= 0) {
    const line = buf.slice(0, nl).trim();
    buf = buf.slice(nl + 1);
    if (!line) continue;
    let msg;
    try {
      msg = JSON.parse(line);
    } catch {
      continue; // Ignore malformed lines rather than killing the server.
    }
    pending++;
    handle(msg)
      .catch((e) => {
        if (msg?.id != null) replyError(msg.id, -32603, e.message);
      })
      .finally(() => {
        pending--;
        maybeExit();
      });
  }
});
process.stdin.on('end', () => {
  stdinEnded = true;
  maybeExit();
});
'@
Write-Utf8NoBom -Path $serverPath -Text $serverJs
Good "wrote $serverPath"

# ------------------------------------------------------- 4. register
Step "Registering with Claude Code and opencode"
# $env:TEMP is normally set on Windows, but fall back rather than fail on a
# stripped environment (and so this script can be exercised on Linux pwsh).
$tempDir = if ($env:TEMP) { $env:TEMP } else { [System.IO.Path]::GetTempPath() }
$patchPath = Join-Path $tempDir 'hindsight-recall-patch.mjs'
$patchJs = @'
#!/usr/bin/env node
/**
 * Registers the hindsight-recall MCP server with Claude Code and/or opencode.
 *
 * Deliberately node rather than the host shell: Windows PowerShell 5.1's
 * ConvertTo-Json defaults to -Depth 2, which silently truncates a nested
 * .claude.json instead of failing. Node's JSON round-trip has no depth limit,
 * and this is the same code path already proven on Linux.
 *
 * Every target is backed up before it is touched, and re-running is a no-op
 * beyond refreshing the entry.
 *
 *   node patch-config.mjs --server <abs path to hindsight-recall.mjs> \
 *                         [--claude <path>] [--opencode <path>]
 *                         [--api <url>] [--bank <id>]
 */
import { readFileSync, writeFileSync, copyFileSync, existsSync, mkdirSync } from 'fs';
import { dirname } from 'path';

const NAME = 'hindsight-recall';

function arg(flag, fallback = undefined) {
  const i = process.argv.indexOf(flag);
  return i >= 0 && process.argv[i + 1] ? process.argv[i + 1] : fallback;
}

const serverPath = arg('--server');
if (!serverPath) {
  console.error('patch-config: --server <path> is required');
  process.exit(2);
}

const apiUrl = arg('--api');
const bank = arg('--bank');
/** Passed to the server process so it works even where no coding-agent.json exists. */
const env = {};
if (apiUrl) env.HINDSIGHT_API_URL = apiUrl;
if (bank) env.HINDSIGHT_BANK_ID = bank;

function backupThenWrite(path, obj) {
  if (existsSync(path)) {
    const stamp = new Date().toISOString().replace(/[-:T]/g, '').slice(0, 14);
    copyFileSync(path, `${path}.bak-recall-${stamp}`);
  } else {
    mkdirSync(dirname(path), { recursive: true });
  }
  writeFileSync(path, JSON.stringify(obj, null, 2));
}

function load(path) {
  if (!existsSync(path)) return null;
  try {
    return JSON.parse(readFileSync(path, 'utf8'));
  } catch (e) {
    // A malformed target is the user's file, not ours to rewrite.
    throw new Error(`${path} is not valid JSON (${e.message}) — leaving it alone`);
  }
}

let touched = 0;

// --- Claude Code: ~/.claude.json  →  mcpServers.<name> = {type,command,args,env}
const claudePath = arg('--claude');
if (claudePath) {
  const j = load(claudePath) ?? {};
  const before = Object.keys(j).length;
  j.mcpServers = j.mcpServers || {};
  j.mcpServers[NAME] = {
    type: 'stdio',
    command: 'node',
    args: [serverPath],
    ...(Object.keys(env).length ? { env } : {}),
  };
  backupThenWrite(claudePath, j);
  console.log(`claude    ok  ${claudePath} (top-level keys preserved: ${before} -> ${Object.keys(j).length})`);
  touched++;
}

// --- opencode: ~/.config/opencode/opencode.json  →  mcp.<name> = {type:'local',command:[...]}
const opencodePath = arg('--opencode');
if (opencodePath) {
  const j = load(opencodePath) ?? { $schema: 'https://opencode.ai/config.json' };
  const before = Object.keys(j).length;
  j.mcp = j.mcp || {};
  j.mcp[NAME] = {
    type: 'local',
    command: ['node', serverPath],
    enabled: true,
    ...(Object.keys(env).length ? { environment: env } : {}),
  };
  backupThenWrite(opencodePath, j);
  console.log(`opencode  ok  ${opencodePath} (top-level keys preserved: ${before} -> ${Object.keys(j).length})`);
  touched++;
}

if (!touched) {
  console.error('patch-config: nothing to do — pass --claude and/or --opencode');
  process.exit(2);
}
'@
Write-Utf8NoBom -Path $patchPath -Text $patchJs

# Node accepts forward slashes on Windows, and they need no escaping in JSON.
$serverArg   = $serverPath.Replace('\', '/')
$claudeCfg   = (Join-Path $Home_ '.claude.json')
$opencodeCfg = (Join-Path $Home_ '.config\opencode\opencode.json')

& node $patchPath --server $serverArg `
  --claude $claudeCfg --opencode $opencodeCfg `
  --api $ApiUrl --bank $Bank
if ($LASTEXITCODE -ne 0) { Bad "registration failed"; exit 1 }
Remove-Item $patchPath -Force -ErrorAction SilentlyContinue

# ------------------------------------------------------- 5. verify
if (-not $SkipTest) {
  Step "Verifying the server answers"
  $probe = @'
{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"probe","version":"1"}}}
{"jsonrpc":"2.0","id":2,"method":"tools/list"}
'@
  $env:HINDSIGHT_API_URL = $ApiUrl
  $env:HINDSIGHT_BANK_ID = $Bank
  $out = $probe | & node $serverPath 2>&1 | Out-String
  if ($out -match '"name":"recall"') { Good "server responds and advertises the 'recall' tool" }
  else { Bad "server did not advertise the tool. Raw output:"; Say $out }

  Step "Asking each host what it sees"
  foreach ($exe in @('claude', 'opencode')) {
    if (Get-Command $exe -ErrorAction SilentlyContinue) {
      Say "$exe mcp list"
      # These CLIs write banners and colour codes to stderr, which under
      # ErrorActionPreference=Stop is raised as a terminating NativeCommandError
      # before we ever get to inspect the output. Relax it for the call.
      $prev = $ErrorActionPreference
      $ErrorActionPreference = 'Continue'
      try {
        # Separate literal arguments: splitting a string reached opencode as ONE
        # argument, which it read as a directory to change into.
        $r = & $exe 'mcp' 'list' 2>&1 | Out-String
        if ($r -match 'hindsight-recall') { Good "$exe sees hindsight-recall" } else { Warn "$exe did not list it:"; Say $r.Trim() }
      } catch { Warn "$exe check failed: $_" } finally { $ErrorActionPreference = $prev }
    } else {
      Warn "$exe is not on PATH - skipped"
    }
  }
}

Write-Host ""
Good "Done."
Say  "Restart Claude Code / opencode - MCP servers are started when a session starts."
Say  "Then the tool is available as: recall"
Write-Host ""
