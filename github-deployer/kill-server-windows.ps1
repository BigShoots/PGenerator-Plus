$ErrorActionPreference = "Stop"
$AppDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ServerPath = [System.IO.Path]::GetFullPath((Join-Path $AppDir "server.py"))
$PidFile = Join-Path $AppDir ".server.pid"
$Targets = @()

function Get-ProcessInfo([int]$ProcessId) {
    return Get-CimInstance Win32_Process -Filter "ProcessId = $ProcessId" -ErrorAction SilentlyContinue
}

if (Test-Path $PidFile) {
    $RecordedPid = 0
    [void][int]::TryParse((Get-Content $PidFile -First 1), [ref]$RecordedPid)
    if ($RecordedPid -gt 0) {
        $ProcessInfo = Get-ProcessInfo $RecordedPid
        if ($ProcessInfo -and $ProcessInfo.CommandLine -like "*server.py*") {
            $Targets += $ProcessInfo
        }
    }
}

if ($Targets.Count -eq 0) {
    $EscapedServerPath = [Regex]::Escape($ServerPath)
    $Targets = @(
        Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
            Where-Object { $_.CommandLine -and $_.CommandLine -match $EscapedServerPath }
    )
}

if ($Targets.Count -eq 0) {
    Remove-Item $PidFile -Force -ErrorAction SilentlyContinue
    Write-Host "PGenerator GitHub deployer is not running."
    exit 0
}

foreach ($Target in $Targets) {
    Stop-Process -Id $Target.ProcessId -ErrorAction SilentlyContinue
}

$Deadline = (Get-Date).AddSeconds(5)
foreach ($Target in $Targets) {
    while ((Get-Process -Id $Target.ProcessId -ErrorAction SilentlyContinue) -and (Get-Date) -lt $Deadline) {
        Start-Sleep -Milliseconds 100
    }
    if (Get-Process -Id $Target.ProcessId -ErrorAction SilentlyContinue) {
        Stop-Process -Id $Target.ProcessId -Force -ErrorAction SilentlyContinue
    }
}

Remove-Item $PidFile -Force -ErrorAction SilentlyContinue
Write-Host "PGenerator GitHub deployer stopped."
