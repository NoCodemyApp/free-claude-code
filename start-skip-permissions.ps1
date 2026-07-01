# ============================================================
#  Free Claude Code — Start (Skip Permissions Mode)
#  Launches the proxy server + Claude Code with
#  --dangerously-skip-permissions (no tool approval prompts)
# ============================================================

$ErrorActionPreference = "Stop"
$root = $PSScriptRoot

Write-Host ""
Write-Host "  ⚡  Free Claude Code — Skip Permissions Mode" -ForegroundColor Magenta
Write-Host "  ─────────────────────────────────────────────────" -ForegroundColor DarkGray
Write-Host "  ⚠  All tool use will run WITHOUT approval prompts!" -ForegroundColor Yellow
Write-Host ""

# Start the proxy server in a new window
Start-Process powershell -ArgumentList @(
    "-NoExit",
    "-Command",
    "cd '$root'; Write-Host '🚀 FCC Proxy Server' -ForegroundColor Green; uv run fcc-server"
) -WindowStyle Normal

# Give the server a moment to start
Write-Host "  ⏳ Waiting for proxy to start..." -ForegroundColor Yellow
Start-Sleep -Seconds 4

# Launch Claude Code with --dangerously-skip-permissions
Write-Host "  ✅ Starting Claude Code (skip-permissions mode)..." -ForegroundColor Magenta
Write-Host ""
Set-Location $root
uv run fcc-claude --dangerously-skip-permissions
