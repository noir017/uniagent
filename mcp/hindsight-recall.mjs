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
