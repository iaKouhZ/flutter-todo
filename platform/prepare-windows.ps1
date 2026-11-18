$ErrorActionPreference = 'Stop'
Set-Location (Join-Path $PSScriptRoot '..')
if (-not (Test-Path 'windows/CMakeLists.txt')) {
    $scaffold = Join-Path $env:RUNNER_TEMP ('todo-scaffold-' + [guid]::NewGuid().ToString('N'))
    & flutter create --platforms=windows --org io.github.iakouhz --project-name todo_endfield --no-pub $scaffold
    if ($LASTEXITCODE -ne 0) { throw 'Flutter Windows scaffold failed.' }
    New-Item -ItemType Directory -Path windows -Force | Out-Null
    Copy-Item -Path "$scaffold/windows/*" -Destination windows -Recurse -Force
    Remove-Item -LiteralPath $scaffold -Recurse -Force
}
Copy-Item -Path 'platform/windows/*' -Destination windows -Recurse -Force
