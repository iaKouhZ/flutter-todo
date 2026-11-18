param(
    [Parameter(Mandatory = $true)][ValidateSet('x64', 'arm64')][string]$TargetArch
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
foreach ($hive in @('HKCU:', 'HKLM:')) {
    $key = "$hive\Software\Microsoft\Windows\CurrentVersion\Uninstall\TodoEndfield.Desktop_is1"
    if (Test-Path $key) { throw "Unexpected uninstall registry entry: $key." }
}

$running = Start-Process -FilePath "$installDir/todo_endfield.exe" -WorkingDirectory $env:RUNNER_TEMP -PassThru
try {
    Start-Sleep -Seconds 8
    $running.Refresh()
    if ($running.HasExited) { throw 'Installed desktop app exited during the startup smoke test.' }
} finally {
    if (-not $running.HasExited) { Stop-Process -Id $running.Id -Force }
}

$uninstall = Start-Process -FilePath "$installDir/unins000.exe" -ArgumentList @(
    '/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART'
) -PassThru -Wait
if ($uninstall.ExitCode -ne 0) { throw "Uninstaller failed: $($uninstall.ExitCode)." }
Start-Sleep -Seconds 2
if (Test-Path "$installDir/todo_endfield.exe") { throw 'The installed app was not removed.' }
Write-Output "$TargetArch native, installation, launch and uninstall checks passed."
