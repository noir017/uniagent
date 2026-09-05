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
