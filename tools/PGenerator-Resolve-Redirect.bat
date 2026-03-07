@echo off
setlocal enabledelayedexpansion
title PGenerator Resolve Redirect
color 0B

:: Check for admin
net session >nul 2>&1
if %errorlevel% neq 0 (
    echo.
    echo   This tool requires Administrator privileges.
    echo   Right-click and select "Run as administrator".
    echo.
    pause
    exit /b 1
)

echo.
echo   ====================================
echo    PGenerator Resolve Redirect
echo   ====================================
echo.
echo   This tool redirects CalMAN's Resolve
echo   connection (port 20002) to your
echo   PGenerator device.
echo.

:: Get PGenerator IP
set /p PGEN_IP="  Enter PGenerator IP address (e.g. 192.168.1.169): "
if "!PGEN_IP!"=="" (
    echo.
    echo   No IP entered. Exiting.
    pause
    exit /b 1
)

set PORT=20002

:: Ensure IP Helper service is running (required for portproxy)
sc query iphlpsvc | find "RUNNING" >nul 2>&1
if errorlevel 1 (
    echo   Starting IP Helper service...
    net start iphlpsvc >nul 2>&1
)

:: Add firewall rule for port 20002
netsh advfirewall firewall delete rule name="PGenerator Resolve Redirect" >nul 2>&1
netsh advfirewall firewall add rule name="PGenerator Resolve Redirect" dir=in action=allow protocol=tcp localport=!PORT! >nul

:: Clean up any existing portproxy rules
netsh interface portproxy delete v4tov4 listenport=!PORT! listenaddress=0.0.0.0 >nul 2>&1

:: Test connectivity
echo.
echo   Testing connection to !PGEN_IP!:!PORT!...
powershell -NoProfile -Command "try { $t = New-Object Net.Sockets.TcpClient; $r = $t.BeginConnect('!PGEN_IP!', !PORT!, $null, $null); if ($r.AsyncWaitHandle.WaitOne(3000)) { Write-Host '  PGenerator responding on port !PORT!' -F Green } else { Write-Host '  Warning: Could not reach !PGEN_IP!:!PORT! (continuing anyway)' -F Yellow }; $t.Close() } catch { Write-Host '  Warning: Could not reach !PGEN_IP!:!PORT! (continuing anyway)' -F Yellow }"

:: Create redirect on ALL interfaces
netsh interface portproxy add v4tov4 listenport=!PORT! listenaddress=0.0.0.0 connectport=!PORT! connectaddress=!PGEN_IP! >nul

:: ---- Diagnostics ----
echo.
echo   ---- Diagnostics ----
echo.
echo   [1] Port proxy rules:
netsh interface portproxy show all
echo.
echo   [2] Firewall rule:
netsh advfirewall firewall show rule name="PGenerator Resolve Redirect" | findstr /i "Rule Enabled Action LocalPort"
echo.
echo   [3] Checking if port !PORT! is listening locally...
powershell -NoProfile -Command "try { $t = New-Object Net.Sockets.TcpClient; $t.Connect('127.0.0.1', !PORT!); Write-Host '  OK: 127.0.0.1:!PORT! is accepting connections' -F Green; $t.Close() } catch { Write-Host '  FAIL: 127.0.0.1:!PORT! refused connection' -F Red; Write-Host '  Error: ' $_.Exception.Message -F Red }"
echo.
echo   [4] Local IP addresses:
powershell -NoProfile -Command "Get-NetIPAddress -AddressFamily IPv4 | Where-Object { $_.IPAddress -ne '127.0.0.1' } | ForEach-Object { Write-Host ('  ' + $_.IPAddress + ' (' + $_.InterfaceAlias + ')') }"
echo.
echo   [5] Listening sockets on port !PORT!:
netstat -an | findstr ":!PORT! "
echo   ---- End Diagnostics ----

color 0A
echo.
echo   ====================================
echo    Redirect Active
echo   ====================================
echo.
echo   *:!PORT!  --^>  !PGEN_IP!:!PORT!  (all interfaces)
echo.
echo   CalMAN can now use Resolve protocol.
echo.
echo   Press any key to stop and revert...
echo.
pause >nul

:: Revert
color 0E
echo   Removing redirects...
netsh interface portproxy delete v4tov4 listenport=!PORT! listenaddress=0.0.0.0 >nul 2>&1
netsh advfirewall firewall delete rule name="PGenerator Resolve Redirect" >nul 2>&1

color 0A
echo   Redirects removed. Done.
timeout /t 2 >nul
