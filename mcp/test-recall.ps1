#requires -Version 5.1
<#
  End-to-end check: drives the installed MCP server exactly as a host would
  (initialize -> initialized -> tools/call recall) and prints what came back.
  Sets the env vars explicitly because a standalone run has none of the values
  the MCP registration passes in.
#>
param(
  [string]$Query  = 'agent-anywhere 发布流程',
  [string]$ApiUrl = 'https://hindsight-api.lan.noharanas.eu.org',
  [string]$Bank   = 'agent'
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.Encoding]::UTF8

$server = Join-Path $env:USERPROFILE '.claude\mcp-servers\hindsight-recall.mjs'
if (-not (Test-Path $server)) { Write-Host "FAIL server not found: $server" -ForegroundColor Red; exit 1 }

$env:HINDSIGHT_API_URL = $ApiUrl
$env:HINDSIGHT_BANK_ID = $Bank

# JSON built by the serializer rather than by hand, so the query can contain
# quotes or non-ASCII without breaking the payload.
$call = @{
  jsonrpc = '2.0'; id = 3; method = 'tools/call'
  params  = @{ name = 'recall'; arguments = @{ query = $Query; max_tokens = 500 } }
} | ConvertTo-Json -Compress -Depth 10

$lines = @(
  '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"probe","version":"1"}}}'
  '{"jsonrpc":"2.0","method":"notifications/initialized"}'
  $call
)

Write-Host "query : $Query"
Write-Host "server: $server"
Write-Host ""

$sw = [Diagnostics.Stopwatch]::StartNew()
# node may write warnings to stderr (e.g. NODE_TLS_REJECT_UNAUTHORIZED). Under
# ErrorActionPreference=Stop those surface as a terminating NativeCommandError,
# so relax it just for this call and keep the merged output.
$prev = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
$out = $lines | & node $server 2>&1 | Out-String
$ErrorActionPreference = $prev
$sw.Stop()

$hit = $out -split "`n" | Where-Object { $_ -match '"id":3' } | Select-Object -First 1
if (-not $hit) {
  Write-Host "FAIL no response to tools/call. Raw:" -ForegroundColor Red
  Write-Host $out
  exit 1
}

$text = ($hit | ConvertFrom-Json).result.content[0].text
Write-Host "OK  round trip in $([int]$sw.ElapsedMilliseconds) ms" -ForegroundColor Green
Write-Host ""
Write-Host ($text.Substring(0, [Math]::Min(900, $text.Length)))
