param(
    [Parameter(Mandatory = $true)][ValidateSet('x64', 'arm64')][string]$TargetArch,
    [string]$ServerUrl = ''
)
$ErrorActionPreference = 'Stop'
Set-Location (Join-Path $PSScriptRoot '..')
$release = (Resolve-Path "build/windows/$TargetArch/runner/Release").Path
$native = Join-Path $release 'ledger_native_test.exe'
& $native
if ($LASTEXITCODE -ne 0) { throw 'Windows native tests failed.' }

$exe = Join-Path $release 'todo_endfield.exe'
$bytes = [IO.File]::ReadAllBytes($exe)
$header = [BitConverter]::ToInt32($bytes, 0x3c)
$machine = [BitConverter]::ToUInt16($bytes, $header + 4)
$expected = if ($TargetArch -eq 'arm64') { 0xaa64 } else { 0x8664 }
if ($machine -ne $expected) { throw "Unexpected PE architecture: $machine." }

$installer = (Resolve-Path "dist/flutter-todo-windows-$TargetArch-setup.exe").Path
$installDir = Join-Path $env:RUNNER_TEMP "todo-installed-$TargetArch"
$install = Start-Process -FilePath $installer -ArgumentList @(
    '/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', '/CURRENTUSER', "/DIR=$installDir"
) -PassThru -Wait
if ($install.ExitCode -ne 0) { throw "Installer failed: $($install.ExitCode)." }
if (-not (Test-Path "$installDir/todo_endfield.exe") -or -not (Test-Path "$installDir/unins000.exe")) {
    throw 'Installed program or uninstaller is missing.'
}
$uninstallKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\TodoEndfield.Desktop_is1'
if (-not (Test-Path $uninstallKey)) { throw 'Windows uninstall registration was not created.' }
$entry = Get-ItemProperty -LiteralPath $uninstallKey
if ($entry.DisplayName -ne '待办清单' -or $entry.UninstallString -notlike "*$installDir*") {
    throw 'Windows uninstall registration points to an unexpected application.'
}
if (Test-Path 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\TodoEndfield.Desktop_is1') {
    throw 'Unexpected machine-wide uninstall registration.'
}
Add-Type -AssemblyName System.Drawing
function Confirm-LedgerIcon([string]$Path) {
    $icon = [Drawing.Icon]::ExtractAssociatedIcon($Path)
    if (-not $icon) { throw "Missing icon in $Path." }
    $bitmap = $icon.ToBitmap()
    try {
        $corner = $bitmap.GetPixel(0, 0)
        if ($corner.R -lt 240 -or $corner.G -lt 230 -or $corner.B -gt 30) {
            throw "Unexpected app or installer icon in $Path."
        }
    } finally {
        $bitmap.Dispose()
        $icon.Dispose()
    }
}
Confirm-LedgerIcon "$installDir/todo_endfield.exe"
Confirm-LedgerIcon $installer


if (-not (Test-Path "$installDir/ledger_tls.exe")) {
    throw 'Installed Windows certificate verifier is missing.'
}
./platform/test-windows-tls.ps1 -Verifier "$installDir/ledger_tls.exe"
if ($ServerUrl) {
    foreach ($mode in @('--check-server', '--check-server-windows-trust')) {
        $probeResult = Join-Path $env:RUNNER_TEMP "todo-connectivity-$TargetArch-$mode.json"
        $probe = Start-Process -FilePath "$installDir/todo_endfield.exe" -ArgumentList @(
            $mode, $ServerUrl, $probeResult
        ) -WorkingDirectory $env:RUNNER_TEMP -PassThru -Wait
        if (-not (Test-Path $probeResult)) {
            throw "The installed app produced no connection diagnostic (exit $($probe.ExitCode))."
        }
        $diagnostic = Get-Content -Raw -LiteralPath $probeResult | ConvertFrom-Json
        Write-Output "Installed release $mode connection result: $($diagnostic.message)"
        if ($probe.ExitCode -ne 0 -or -not $diagnostic.ok) {
            throw "Installed release $mode connection failed: $($diagnostic.message)"
        }
    }
}

$running = Start-Process -FilePath "$installDir/todo_endfield.exe" -WorkingDirectory $env:RUNNER_TEMP -PassThru
try {
    Start-Sleep -Seconds 8
    $running.Refresh()
    if ($running.HasExited) { throw 'Installed desktop app exited during the startup smoke test.' }
    if ($running.MainWindowTitle -ne '待办清单') {
        throw "Unexpected desktop window title: $($running.MainWindowTitle)"
    }
} finally {
    if (-not $running.HasExited) { Stop-Process -Id $running.Id -Force }
}

$uninstall = Start-Process -FilePath "$installDir/unins000.exe" -ArgumentList @(
    '/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART'
) -PassThru -Wait
if ($uninstall.ExitCode -ne 0) { throw "Uninstaller failed: $($uninstall.ExitCode)." }
Start-Sleep -Seconds 2
if (Test-Path "$installDir/todo_endfield.exe") { throw 'The installed app was not removed.' }
if (Test-Path $uninstallKey) { throw 'Uninstall left its registration data behind.' }
if (Test-Path "$installDir/ledger_tls.exe") { throw 'The certificate verifier was not uninstalled.' }
Write-Output "$TargetArch native, icons, Unicode title, installation and uninstall cleanup checks passed."
