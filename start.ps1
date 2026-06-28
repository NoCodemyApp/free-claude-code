# ============================================================
#  Free Claude Code — Start (Normal Mode)
#  Launches the proxy server + Claude Code with full prompts
# ============================================================

$ErrorActionPreference = "Stop"
$root = $PSScriptRoot

Write-Host ""
Write-Host "  🤖  Free Claude Code — Normal Mode" -ForegroundColor Cyan
Write-Host "  ─────────────────────────────────────────" -ForegroundColor DarkGray
Write-Host ""

# Start the proxy server in a new window
Start-Process powershell -ArgumentList @(
    "-NoExit",
    "-Command",
    "cd '$root'; Write-Host '🚀 FCC Proxy Server' -ForegroundColor Green; python -m uv run fcc-server"
) -WindowStyle Normal

# Give the server a moment to start
Write-Host "  ⏳ Waiting for proxy to start..." -ForegroundColor Yellow
Start-Sleep -Seconds 4

# Launch Claude Code (normal mode)
Write-Host "  ✅ Starting Claude Code (normal mode)..." -ForegroundColor Green
Write-Host ""
Set-Location $root
python -m uv run fcc-claude
