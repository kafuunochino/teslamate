function Import-NativeEnv {
    param(
        [Parameter(Mandatory = $false)]
        [string]$Path = ".env.native"
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Missing $Path; copy .env.native.example and fill in the secrets."
    }

    foreach ($line in Get-Content -LiteralPath $Path -Encoding utf8) {
        if ([string]::IsNullOrWhiteSpace($line) -or $line.TrimStart().StartsWith("#")) {
            continue
        }

        $parts = $line.Split("=", 2)
        if ($parts.Count -ne 2 -or $parts[0] -notmatch '^[A-Za-z_][A-Za-z0-9_]*$') {
            throw "Invalid environment entry in ${Path}: $line"
        }

        [Environment]::SetEnvironmentVariable($parts[0], $parts[1], "Process")
    }
}
