# PGenerator Resolve Redirect
# Forwards local port 20002 to a PGenerator device so CalMAN can use Resolve protocol
# Press any key or close the window to revert the redirect

#Requires -RunAsAdministrator

$Host.UI.RawUI.WindowTitle = "PGenerator Resolve Redirect"

Write-Host ""
Write-Host "  ====================================" -ForegroundColor Cyan
Write-Host "   PGenerator Resolve Redirect" -ForegroundColor Cyan
Write-Host "  ====================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "  This tool redirects CalMAN's Resolve connection" -ForegroundColor Gray
Write-Host "  (port 20002) to your PGenerator device." -ForegroundColor Gray
Write-Host ""

# Get PGenerator IP from user
$pgenIp = Read-Host "  Enter PGenerator IP address (e.g. 192.168.1.169)"
$pgenIp = $pgenIp.Trim()

if (-not $pgenIp) {
    Write-Host "`n  No IP entered. Exiting." -ForegroundColor Red
    Start-Sleep -Seconds 2
    exit 1
}

# Validate IP format
if ($pgenIp -notmatch '^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}$') {
    Write-Host "`n  Invalid IP address: $pgenIp" -ForegroundColor Red
    Start-Sleep -Seconds 2
    exit 1
}

# Quick connectivity test
Write-Host "`n  Testing connection to ${pgenIp}:20002..." -ForegroundColor Yellow
try {
    $tcp = New-Object System.Net.Sockets.TcpClient
    $result = $tcp.BeginConnect($pgenIp, 20002, $null, $null)
    $success = $result.AsyncWaitHandle.WaitOne(3000)
    $tcp.Close()
    if ($success) {
        Write-Host "  PGenerator responding on port 20002" -ForegroundColor Green
    } else {
        Write-Host "  Warning: Could not reach ${pgenIp}:20002 (continuing anyway)" -ForegroundColor Yellow
    }
} catch {
    Write-Host "  Warning: Could not reach ${pgenIp}:20002 (continuing anyway)" -ForegroundColor Yellow
}

# Find local LAN IP
$localIp = (Get-NetIPAddress -AddressFamily IPv4 |
    Where-Object { $_.InterfaceAlias -notmatch 'Loopback' -and
                   $_.IPAddress -notlike '169.*' -and
                   $_.IPAddress -ne '127.0.0.1' } |
    Select-Object -First 1).IPAddress

if (-not $localIp) {
    Write-Host "`n  Could not detect local IP. Exiting." -ForegroundColor Red
    Start-Sleep -Seconds 2
    exit 1
}

$port = 20002

# Clean up any existing rules on this port first
netsh interface portproxy delete v4tov4 listenport=$port listenaddress=$localIp 2>$null | Out-Null
netsh interface portproxy delete v4tov4 listenport=$port listenaddress=127.0.0.1 2>$null | Out-Null

# Create redirects
netsh interface portproxy add v4tov4 listenport=$port listenaddress=$localIp connectport=$port connectaddress=$pgenIp | Out-Null
netsh interface portproxy add v4tov4 listenport=$port listenaddress=127.0.0.1 connectport=$port connectaddress=$pgenIp | Out-Null

Write-Host ""
Write-Host "  ====================================" -ForegroundColor Green
Write-Host "   Redirect Active" -ForegroundColor Green
Write-Host "  ====================================" -ForegroundColor Green
Write-Host ""
Write-Host "  ${localIp}:${port}  -->  ${pgenIp}:${port}" -ForegroundColor White
Write-Host "  127.0.0.1:${port}   -->  ${pgenIp}:${port}" -ForegroundColor White
Write-Host ""
Write-Host "  CalMAN can now use Resolve protocol." -ForegroundColor Gray
Write-Host "  Press any key to stop and revert..." -ForegroundColor Yellow
Write-Host ""

# Wait — handle both interactive keypress and window close
try {
    [Console]::ReadKey($true) | Out-Null
} catch {
    # If ReadKey fails (non-interactive), wait for Ctrl+C
    try { while ($true) { Start-Sleep -Seconds 1 } } catch { }
}

# Revert
Write-Host "  Removing redirects..." -ForegroundColor Yellow
netsh interface portproxy delete v4tov4 listenport=$port listenaddress=$localIp 2>$null | Out-Null
netsh interface portproxy delete v4tov4 listenport=$port listenaddress=127.0.0.1 2>$null | Out-Null

Write-Host "  Redirects removed. Done." -ForegroundColor Green
Start-Sleep -Seconds 1
