$ErrorActionPreference = "Stop"

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$projectDir = (Resolve-Path (Join-Path $scriptDir "..\..")).Path
. (Join-Path $scriptDir "Load-NativeEnv.ps1")

$envFile = if ($args.Count -gt 0) { $args[0] } else { ".env.native" }
Set-Location -LiteralPath $projectDir
Import-NativeEnv -Path $envFile
$env:MIX_ENV = "prod"

foreach ($name in @("ENCRYPTION_KEY", "DATABASE_PASS", "SECRET_KEY_BASE", "SIGNING_SALT")) {
    $value = [Environment]::GetEnvironmentVariable($name, "Process")
    if ([string]::IsNullOrWhiteSpace($value) -or $value.Contains("CHANGE_ME")) {
        throw "Set $name to a real secret in $envFile before continuing."
    }
}

New-Item -ItemType Directory -Force -Path "import", "data\srtm", "data\tzdata" | Out-Null
mix local.hex --force
mix local.rebar --force
mix deps.get --only prod
mix deps.compile
npm ci --prefix assets --no-audit --loglevel=error
mix assets.deploy
mix compile
mix ecto.migrate

Write-Host "Native TeslaMate build completed. Start it with scripts/native/Start-Native.ps1."
