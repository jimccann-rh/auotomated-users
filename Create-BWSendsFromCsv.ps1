Param(
    [Parameter(Mandatory = $false)]
    [string]$CsvPath = (Join-Path -Path (Split-Path -Parent $MyInvocation.MyCommand.Path) -ChildPath 'new-users-passwords.csv'),

    [Parameter(Mandatory = $false)]
    [string]$OutputCsv = (Join-Path -Path (Split-Path -Parent $MyInvocation.MyCommand.Path) -ChildPath 'bw-send-links.csv')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Assert-ExecutableAvailable {
    param(
        [Parameter(Mandatory = $true)][string]$Name
    )
    if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
        throw "Required executable '$Name' was not found in PATH. Please install it and try again."
    }
}

Assert-ExecutableAvailable -Name 'bw'

if (-not (Test-Path -Path $CsvPath -PathType Leaf)) {
    throw "CSV file not found: $CsvPath"
}

Write-Host "Reading input CSV: $CsvPath" -ForegroundColor Cyan
$rows = Import-Csv -Path $CsvPath
if (-not $rows -or $rows.Count -eq 0) {
    throw "No rows found in CSV: $CsvPath"
}

# Optionally verify bw status for a helpful hint (does not fail the run)
try {
    $bwStatus = (& bw status | ConvertFrom-Json)
    if ($bwStatus.status -ne 'unlocked') {
        Write-Warning "Bitwarden CLI appears to be '$($bwStatus.status)'. Ensure you are logged in and the session is unlocked (export BW_SESSION) before running."
    }
}
catch {
    Write-Verbose "Could not parse 'bw status' output. Continuing."
}

$results = New-Object System.Collections.Generic.List[object]

foreach ($row in $rows) {
    # Expecting headers: Username,UserPrincipal,Password,vCenterUrl,Email
    $username = $row.Username
    $userPrincipal = $row.UserPrincipal
    $password = $row.Password
    $vCenterUrl = $row.vCenterUrl
    $email = $row.Email

    if ([string]::IsNullOrWhiteSpace($userPrincipal) -or [string]::IsNullOrWhiteSpace($password) -or [string]::IsNullOrWhiteSpace($vCenterUrl)) {
        Write-Warning "Skipping row due to missing fields (UserPrincipal/Password/vCenterUrl). Username='$username'"
        continue
    }

    Write-Host "Creating Bitwarden Send for $userPrincipal ($vCenterUrl) ..." -ForegroundColor Green

    # Get the text template from bw and modify in PowerShell (avoids jq dependency)
    $templateJson = & bw send template send.text
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($templateJson)) {
        throw "Failed to retrieve Bitwarden Send template."
    }

    $template = $templateJson | ConvertFrom-Json
    $template.name = $vCenterUrl
    $template.text.text = "$userPrincipal $password"
    $template.text.hidden = $true
    $template.maxAccessCount = 1

    # Serialize with enough depth to include nested 'text'
    $payloadJson = $template | ConvertTo-Json -Depth 6

    # Create the send, capture access URL
    $createOutput = $payloadJson | & bw encode | & bw send create
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($createOutput)) {
        throw "Bitwarden Send creation failed for $userPrincipal."
    }

    try {
        $created = $createOutput | ConvertFrom-Json
        $accessUrl = $created.accessUrl
    }
    catch {
        # Fallback: try to parse via regex if non-JSON (older bw versions)
        $accessUrl = ($createOutput | Select-String -Pattern 'https?://\S+' -AllMatches).Matches.Value | Select-Object -First 1
    }

    if ([string]::IsNullOrWhiteSpace($accessUrl)) {
        throw "Could not determine accessUrl for $userPrincipal. Raw output: $createOutput"
    }

    $results.Add([PSCustomObject]@{
            Username      = $username
            UserPrincipal = $userPrincipal
            Email         = $email
            vCenterUrl    = $vCenterUrl
            AccessUrl     = $accessUrl
        }) | Out-Null

    Write-Host "  -> $accessUrl" -ForegroundColor Yellow
}

if ($results.Count -gt 0) {
    $results | Export-Csv -Path $OutputCsv -NoTypeInformation
    Write-Host "Saved results to: $OutputCsv" -ForegroundColor Cyan
}
else {
    Write-Warning "No sends were created."
}


