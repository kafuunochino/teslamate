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

mix phx.server
