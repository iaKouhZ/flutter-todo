param(
    [Parameter(Mandatory = $true)][ValidateSet('x64', 'arm64')][string]$TargetArch
)
$ErrorActionPreference = 'Stop'
Set-Location (Join-Path $PSScriptRoot '..')
$release = (Resolve-Path "build/windows/$TargetArch/runner/Release").Path
$programFilesX86 = [Environment]::GetEnvironmentVariable('ProgramFiles(x86)')
$vswhere = Join-Path $programFilesX86 'Microsoft Visual Studio/Installer/vswhere.exe'
$installation = & $vswhere -latest -products '*' -property installationPath
$crt = Get-ChildItem -Path "$installation/VC/Redist/MSVC/*/$TargetArch/Microsoft.VC*.CRT" -Directory |
    Sort-Object FullName | Select-Object -Last 1
if (-not $crt) { throw "Visual C++ $TargetArch application-local runtime was not found." }
Copy-Item -Path "$($crt.FullName)/*.dll" -Destination $release -Force
$setup = Join-Path $programFilesX86 'Inno Setup 6/ISCC.exe'
if (-not (Test-Path $setup)) {
    & choco install innosetup --yes --no-progress
    if ($LASTEXITCODE -ne 0) { throw 'Inno Setup installation failed.' }
}
if (-not (Test-Path $setup)) { throw 'Inno Setup compiler was not found.' }
$output = Join-Path (Get-Location) 'dist'
New-Item -ItemType Directory -Path $output -Force | Out-Null
& $setup "/DTargetArch=$TargetArch" "/DSourceDir=$release" "/DOutputDir=$output" 'platform/windows-installer.iss'
if ($LASTEXITCODE -ne 0) { throw 'Windows installer compilation failed.' }
