# Compila BeyondClone per Windows e crea due eseguibili autonomi (non serve installare .NET per usarli).
#   .\build.ps1            -> dist\win-x64\BeyondClone.exe e dist\win-arm64\BeyondClone.exe
#   .\build.ps1 -Test      -> prima esegue gli autotest del motore
param([switch]$Test)
$ErrorActionPreference = "Stop"
Set-Location $PSScriptRoot

if ($Test) {
    dotnet run -c Release --project src\BeyondClone.SelfTest
    if ($LASTEXITCODE -ne 0) { throw "Autotest falliti" }
}

foreach ($rid in "win-x64", "win-arm64") {
    Write-Host "Pubblicazione $rid..."
    dotnet publish src\BeyondClone -c Release -r $rid --self-contained true `
        -p:PublishSingleFile=true -p:IncludeNativeLibrariesForSelfExtract=true -p:EnableCompressionInSingleFile=true `
        -p:DebugType=none -o "dist\$rid"
    if ($LASTEXITCODE -ne 0) { throw "Pubblicazione $rid non riuscita" }
}
Get-ChildItem dist -Recurse -Filter BeyondClone.exe | ForEach-Object { "{0}  {1:N1} MB" -f $_.FullName, ($_.Length / 1MB) }
