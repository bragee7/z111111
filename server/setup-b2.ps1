# ZELDA Backblaze B2 setup helper.
# Run from zelda1\server:
#   powershell -ExecutionPolicy Bypass -File .\setup-b2.ps1
#
# Secrets are prompted with masked input and are never printed.

$ErrorActionPreference = 'Stop'

$configDir = Join-Path $PSScriptRoot 'config'
if (-not (Test-Path $configDir)) {
    New-Item -ItemType Directory -Path $configDir | Out-Null
}
$configPath = Join-Path $configDir 'config.env'

Write-Host 'ZELDA Backblaze B2 setup' -ForegroundColor Cyan
Write-Host 'This creates server\config\config.env.' -ForegroundColor DarkGray
Write-Host 'Use a BUCKET-SCOPED key, never the Master Application Key.' -ForegroundColor Yellow

$bucket = Read-Host 'Bucket name (example: zelda-evidence)'
$region = Read-Host 'Region (example: us-west-004)'
$endpoint = Read-Host 'Endpoint (example: https://s3.us-west-004.backblazeb2.com)'
$keyId = Read-Host 'B2_KEY_ID (bucket-scoped key ID)'

$secureAppKey = Read-Host 'B2_APPLICATION_KEY (bucket-scoped application key)' -AsSecureString
$appKey = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
    [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secureAppKey)
)

$databaseUrl = Read-Host 'DATABASE_URL (Neon pooled connection string)'

$secureJwt = Read-Host 'JWT_SECRET (long random string)' -AsSecureString
$jwtSecret = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
    [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secureJwt)
)

$lines = @(
    "DATABASE_URL=$databaseUrl"
    'DB_SSL=true'
    "JWT_SECRET=$jwtSecret"
    "B2_KEY_ID=$keyId"
    "B2_APPLICATION_KEY=$appKey"
    "B2_BUCKET=$bucket"
    "B2_REGION=$region"
    "B2_ENDPOINT=$endpoint"
    'B2_PUBLIC_BASE_URL='
    'CLIENT_URL=http://localhost:3000'
    'API_URL=http://localhost:5000'
)

$lines | Set-Content -Path $configPath -Encoding utf8

Write-Host ''
Write-Host "Created: $configPath" -ForegroundColor Green
Write-Host 'Next, run:' -ForegroundColor Green
Write-Host '  cd ..'
Write-Host '  npm run dev'
Write-Host ''
Write-Host 'Then open: http://localhost:5000/api/config-status' -ForegroundColor Green
Write-Host 'It should show: "storage": "Configured (b2)"' -ForegroundColor Green
