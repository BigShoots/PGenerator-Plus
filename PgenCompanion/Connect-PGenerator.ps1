<#
.SYNOPSIS
    PGenerator+ Companion - Connects to PGenerator via Bluetooth PAN,
    WiFi AP, or existing network and opens the web interface.

.DESCRIPTION
    This script:
    1. Checks if PGenerator is already reachable (LAN, WiFi, BT PAN, WiFi AP)
    2. If not, attempts Bluetooth PAN connection
    3. Opens the PGenerator web UI in your default browser
    4. Optionally sends a CEC wake command to power on your TV

.NOTES
    Run as Administrator for Bluetooth pairing operations.
    The PGenerator Bluetooth address is auto-discovered via device name.
#>

param(
    [switch]$WakeTV,
    [string]$PiAddress = ""
)

$ErrorActionPreference = "Continue"
$script:PG_BT_NAME = "PGenerator"
$script:PG_URLS = @(
    "http://pgenerator.local",
    "http://10.10.11.1",     # Bluetooth PAN
    "http://10.10.10.1",     # WiFi AP
    "http://10.10.12.1"      # USB Ethernet gadget
)
$script:PG_IP = ""
$script:PG_URL = ""

function Write-Status($msg) {
    Write-Host "  [*] $msg" -ForegroundColor Cyan
}
function Write-OK($msg) {
    Write-Host "  [+] $msg" -ForegroundColor Green
}
function Write-Err($msg) {
    Write-Host "  [-] $msg" -ForegroundColor Red
}
function Write-Info($msg) {
    Write-Host "  [i] $msg" -ForegroundColor Yellow
}

function Test-PGenerator($url) {
    try {
        $r = Invoke-WebRequest -Uri "$url/api/info" -TimeoutSec 3 -UseBasicParsing -ErrorAction Stop
        if ($r.StatusCode -eq 200) { return $true }
    } catch {}
    return $false
}

# --- Banner ---
Write-Host ""
Write-Host "  +=====================================+" -ForegroundColor Blue
Write-Host "  |       PGenerator+ Companion         |" -ForegroundColor Blue
Write-Host "  +=====================================+" -ForegroundColor Blue
Write-Host ""

# --- Step 1: Check all known addresses ---
Write-Status "Searching for PGenerator..."

# If user supplied an address, try it first
if ($PiAddress -ne "") {
    $tryUrl = "http://$PiAddress"
    if (Test-PGenerator $tryUrl) {
        Write-OK "PGenerator found at $tryUrl"
        $script:PG_URL = $tryUrl
        $script:PG_IP = $PiAddress
    }
}

# Try all known addresses
if ($script:PG_URL -eq "") {
    foreach ($candidate in $script:PG_URLS) {
        Write-Host "    Trying $candidate ..." -NoNewline
        if (Test-PGenerator $candidate) {
            Write-Host " found!" -ForegroundColor Green
            $script:PG_URL = $candidate
            # Extract IP from URL
            if ($candidate -match "http://(.+)") { $script:PG_IP = $Matches[1] }
            break
        } else {
            Write-Host " no" -ForegroundColor DarkGray
        }
    }
}

$reachable = ($script:PG_URL -ne "")

# --- Step 2: Bluetooth PAN connection ---
if (-not $reachable) {
    Write-Info "PGenerator not found on any known address."
    Write-Host ""
    Write-Status "Attempting Bluetooth PAN connection..."

    # Find PGenerator Bluetooth device
    $btDevice = $null
    try {
        $btDevices = Get-PnpDevice -FriendlyName "*$($script:PG_BT_NAME)*" -ErrorAction SilentlyContinue
        if ($btDevices) {
            $btDevice = $btDevices | Select-Object -First 1
            Write-OK "Found paired device: $($btDevice.FriendlyName)"
        }
    } catch {}

    if (-not $btDevice) {
        Write-Info "PGenerator Bluetooth device not found in paired devices."
        Write-Info 'Please pair your PC with PGenerator via Windows Bluetooth settings first.'
        Write-Info ""
        Write-Info "Steps:"
        Write-Info '  1. Open Windows Settings -> Bluetooth and devices'
        Write-Info '  2. Click Add device -> Bluetooth'
        Write-Info '  3. Select PGenerator and pair'
        Write-Info "  4. Run this script again"
        Write-Info ""

        # Open Bluetooth settings
        Start-Process "ms-settings:bluetooth"
        Write-Host ""
        Write-Host "  Press Enter after pairing to continue, or Ctrl+C to exit..." -ForegroundColor Yellow
        Read-Host

        # Re-check
        $btDevices = Get-PnpDevice -FriendlyName "*$($script:PG_BT_NAME)*" -ErrorAction SilentlyContinue
        if ($btDevices) {
            $btDevice = $btDevices | Select-Object -First 1
            Write-OK "Found paired device: $($btDevice.FriendlyName)"
        } else {
            Write-Err "Still no PGenerator device found. Exiting."
            exit 1
        }
    }

    # Connect to Bluetooth PAN
    Write-Status "Connecting to Bluetooth PAN..."

    try {
        $btNetAdapter = Get-NetAdapter | Where-Object {
            $_.InterfaceDescription -match "Bluetooth" -and $_.InterfaceDescription -match "Network|PAN|BNEP"
        } | Select-Object -First 1

        if (-not $btNetAdapter) {
            $btNetAdapter = Get-NetAdapter | Where-Object {
                $_.InterfaceDescription -match "Bluetooth"
            } | Select-Object -First 1
        }

        if ($btNetAdapter) {
            if ($btNetAdapter.Status -ne "Up") {
                Write-Status "Enabling Bluetooth network adapter..."
                Enable-NetAdapter -Name $btNetAdapter.Name -Confirm:$false -ErrorAction SilentlyContinue
                Start-Sleep -Seconds 2
            }
            Write-OK "Bluetooth adapter: $($btNetAdapter.Name) ($($btNetAdapter.Status))"
        } else {
            Write-Info "No Bluetooth network adapter found."
        }
    } catch {
        Write-Info "Could not manage Bluetooth adapter: $_"
    }

    # Wait for connectivity
    Write-Status "Waiting for PAN connection (up to 15 seconds)..."
    $btUrl = "http://10.10.11.1"
    for ($i = 0; $i -lt 15; $i++) {
        if (Test-PGenerator $btUrl) {
            $reachable = $true
            $script:PG_URL = $btUrl
            $script:PG_IP = "10.10.11.1"
            Write-OK "Connected via Bluetooth PAN!"
            break
        }
        Start-Sleep -Seconds 1
        Write-Host "." -NoNewline
    }
    Write-Host ""

    if (-not $reachable) {
        Write-Err "Could not reach PGenerator."
        Write-Host ""
        Write-Info "Connection options:"
        Write-Info ""
        Write-Info "  Bluetooth PAN:"
        Write-Info "    1. Right-click Bluetooth icon in system tray"
        Write-Info '    2. Select "Join a Personal Area Network"'
        Write-Info '    3. Right-click PGenerator -> Connect using -> Access point'
        Write-Info ""
        Write-Info "  WiFi AP:"
        Write-Info '    1. Connect to the "PGenerator" WiFi network'
        Write-Info "    2. Open http://10.10.10.1 in your browser"
        Write-Info ""
        Write-Info "  Direct IP:"
        Write-Info '    Run: .\Connect-PGenerator.ps1 -PiAddress 192.168.1.x'
        Write-Host ""
        Read-Host "Press Enter to exit"
        exit 1
    }
}

# --- Step 3: Wake TV via CEC (optional) ---
if ($WakeTV) {
    Write-Status "Sending CEC wake command to TV..."
    try {
        $response = Invoke-WebRequest -Uri "$($script:PG_URL)/api/cec/wake" -TimeoutSec 10 -UseBasicParsing -ErrorAction Stop
        $json = $response.Content | ConvertFrom-Json
        if ($json.status -eq "ok") {
            Write-OK "TV wake command sent"
        } else {
            Write-Err "CEC error: $($json.output)"
        }
    } catch {
        Write-Err "Could not send CEC command: $_"
    }
    Start-Sleep -Seconds 2
}

# --- Step 4: Open Web UI ---
Write-Status "Opening PGenerator+ Web UI..."

# Prefer pgenerator.local if reachable
if ($script:PG_URL -ne "http://pgenerator.local") {
    if (Test-PGenerator "http://pgenerator.local") {
        $script:PG_URL = "http://pgenerator.local"
    }
}

Start-Process $script:PG_URL
Write-OK "Web UI opened in your default browser"
Write-Host ""

# --- Done ---
$pad = $script:PG_URL.PadRight(30)
Write-Host "  +-------------------------------------+" -ForegroundColor Green
Write-Host "  |  PGenerator+ is ready!              |" -ForegroundColor Green
Write-Host "  |  Web UI: $pad|" -ForegroundColor Green
Write-Host "  +-------------------------------------+" -ForegroundColor Green
Write-Host ""
