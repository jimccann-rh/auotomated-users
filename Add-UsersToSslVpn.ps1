param(
    [string]$CsvPath = "./usernames-cee.csv",
    [string]$SubnetsYamlPath = "./vpn-subnets-cee.yml"
)

$ErrorActionPreference = 'Stop'

## No GNU-style flags in this script; see Pending-IbmAccountUsers.ps1 for pending/removal flow

function Get-SubnetIdsFromYaml {
    param(
        [Parameter(Mandatory = $true)][string]$Path
    )

    if (-not (Test-Path -Path $Path -PathType Leaf)) {
        throw "Subnet YAML file not found: $Path"
    }

    $raw = Get-Content -Path $Path -Raw

    $convertFromYamlCmd = Get-Command -Name ConvertFrom-Yaml -ErrorAction SilentlyContinue
    if ($convertFromYamlCmd) {
        $parsed = $raw | ConvertFrom-Yaml
        if ($null -eq $parsed -or $null -eq $parsed.subnetid) {
            throw "YAML doesn't contain 'subnetid' list: $Path"
        }
        return @($parsed.subnetid | ForEach-Object { [int]$_ })
    }

    # Fallback: simple regex parse for list under key 'subnetid:'
    $lines = $raw -split "`n"
    $inSubnetSection = $false
    $ids = New-Object System.Collections.Generic.List[int]
    foreach ($line in $lines) {
        if ($line -match '^\s*subnetid\s*:\s*$') {
            $inSubnetSection = $true
            continue
        }
        if ($inSubnetSection) {
            if ($line -match '^\s*-\s*(\d+)\s*$') {
                [void]$ids.Add([int]$Matches[1])
            }
            elseif ($line -match '^\S') {
                break
            }
        }
    }
    if ($ids.Count -eq 0) {
        throw "Failed to parse subnet IDs from YAML: $Path"
    }
    return @($ids)
}

function Get-IbmCloudUsersJson {
    $cmd = 'ibmcloud sl user list --output json'
    try {
        $output = & bash -lc $cmd
    }
    catch {
        throw "Failed to run '$cmd'. Ensure IBM Cloud CLI is installed and you are logged in. Error: $($_.Exception.Message)"
    }
    if ([string]::IsNullOrWhiteSpace($output)) {
        throw "No output from '$cmd'"
    }
    try {
        return $output | ConvertFrom-Json
    }
    catch {
        throw "Failed to parse JSON from 'ibmcloud sl user list'. Raw output: $output"
    }
}

function Get-IbmAccountUserStatus {
    param(
        [Parameter(Mandatory = $true)][string]$Email
    )

    $cmd = "ibmcloud account user-status $Email"
    $output = $null
    $exit = 1
    try {
        $output = & bash -lc $cmd
        $exit = $LASTEXITCODE
    }
    catch {
        $output = $_.Exception.Message
        $exit = 1
    }

    if ($exit -ne 0) {
        return [pscustomobject]@{ Exists = $false; Raw = $output; Success = $false }
    }
    # If command succeeds, consider the user present in account (status may be Active/Pending/Invited)
    return [pscustomobject]@{ Exists = $true; Raw = $output; Success = $true }
}

function Ensure-IbmAccountUser {
    param(
        [Parameter(Mandatory = $true)][string]$Email
    )

    $status = Get-IbmAccountUserStatus -Email $Email
    if (-not $status.Exists) {
        Write-Host "IBM account not found for $Email. Sending invite..." -ForegroundColor Magenta
        $cmd = "ibmcloud account user-invite $Email"
        try {
            & bash -lc $cmd | Write-Output
            return [pscustomobject]@{ Exists = $false; Invited = $true; Status = $status }
        }
        catch {
            Write-Warning "Failed to invite ${Email}: $($_.Exception.Message)"
            return [pscustomobject]@{ Exists = $false; Invited = $false; Status = $status }
        }
    }
    return [pscustomobject]@{ Exists = $true; Invited = $false; Status = $status }
}

## Pending/removal helpers moved to Pending-IbmAccountUsers.ps1

function Resolve-UserIdFromDirectory {
    param(
        [Parameter(Mandatory = $true)]$UsersJson,
        [string]$Email,
        [string]$Username
    )

    if ($Email) {
        $match = $UsersJson | Where-Object { $_.email -and ($_.email.ToString().ToLower() -eq $Email.ToLower()) } | Select-Object -First 1
        if ($match) { return [int]$match.id }
    }
    if ($Username) {
        $match = $UsersJson | Where-Object { $_.username -and ($_.username.ToString().ToLower() -eq $Username.ToLower()) } | Select-Object -First 1
        if ($match) { return [int]$match.id }
    }
    return $null
}

function Enable-UserVpn {
    param([Parameter(Mandatory = $true)][int]$UserId)
    # Enable VPN service for the user account
    $cmdEnable = "ibmcloud sl user vpn-enable $UserId"
    try {
        Write-Host "Enabling VPN service for user ID $UserId ..." -ForegroundColor Cyan
        & bash -lc $cmdEnable | Write-Output
    }
    catch {
        Write-Warning "Failed to run vpn-enable for user ID ${UserId}: $($_.Exception.Message)"
    }

    # Enable manual VPN configuration so we can assign subnets
    $cmdManual = "ibmcloud sl user vpn-manual $UserId --enable"
    try {
        Write-Host "Enabling manual VPN configuration for user ID $UserId ..." -ForegroundColor Cyan
        & bash -lc $cmdManual | Write-Output
    }
    catch {
        Write-Warning "Failed to enable manual VPN for user ID ${UserId}: $($_.Exception.Message)"
    }
}

function Add-UserSubnetAccess {
    param(
        [Parameter(Mandatory = $true)][int]$UserId,
        [Parameter(Mandatory = $true)][int]$SubnetId
    )
    $cmd = "ibmcloud sl user vpn-subnet $UserId --add $SubnetId"
    try {
        Write-Host "  Adding subnet $SubnetId to user ID $UserId ..." -ForegroundColor DarkCyan
        & bash -lc $cmd | Write-Output
    }
    catch {
        Write-Warning "  Failed to add subnet $SubnetId for user ID ${UserId}: $($_.Exception.Message)"
    }
}

# Preflight checks
if (-not (Get-Command -Name ibmcloud -ErrorAction SilentlyContinue)) {
    throw "'ibmcloud' CLI not found in PATH. Install IBM Cloud CLI and login before running."
}

if (-not (Test-Path -Path $CsvPath -PathType Leaf)) {
    throw "CSV file not found: $CsvPath"
}

## Pending users flow removed from this script; use Pending-IbmAccountUsers.ps1 instead

$subnetIds = Get-SubnetIdsFromYaml -Path $SubnetsYamlPath
Write-Host "Loaded subnet IDs: $($subnetIds -join ', ')" -ForegroundColor Green

# Load the directory once to avoid repeated CLI calls
$usersJson = Get-IbmCloudUsersJson

# Our CSV appears to be headerless. Define columns explicitly.
$csvRows = Import-Csv -Path $CsvPath -Header 'Username', 'Email', 'Group', 'FirstName', 'LastName', 'AccountName', 'Ticket'

foreach ($row in $csvRows) {
    if (-not ($row.Username) -and -not ($row.Email)) { continue }

    $email = ($row.Email | ForEach-Object { $_.ToString().Trim() })
    $username = ($row.Username | ForEach-Object { $_.ToString().Trim() })

    if ([string]::IsNullOrWhiteSpace($email) -and [string]::IsNullOrWhiteSpace($username)) { continue }

    Write-Host "Processing user: Username='$username' Email='$email'" -ForegroundColor Yellow

    # Ensure IBM account membership (by email). If newly invited, skip VPN steps for now.
    if (-not [string]::IsNullOrWhiteSpace($email)) {
        $acct = Ensure-IbmAccountUser -Email $email
        if ($acct.Invited) {
            Write-Host "Invited $email to IBM Cloud; skipping VPN setup until they accept the invite." -ForegroundColor Magenta
            continue
        }
    }
    else {
        Write-Warning "No email provided for username '$username'; cannot verify IBM account."
    }

    $userId = Resolve-UserIdFromDirectory -UsersJson $usersJson -Email $email -Username $username
    if ($null -eq $userId) {
        # Refresh directory once in case user just accepted invite
        $usersJson = Get-IbmCloudUsersJson
        $userId = Resolve-UserIdFromDirectory -UsersJson $usersJson -Email $email -Username $username
        if ($null -eq $userId) {
            Write-Warning "No IBM Classic Infrastructure user found matching Username='$username' or Email='$email'. Skipping."
            continue
        }
    }

    Enable-UserVpn -UserId $userId

    foreach ($sid in $subnetIds) {
        Add-UserSubnetAccess -UserId $userId -SubnetId $sid
    }
}

Write-Host "Completed processing users from CSV: $CsvPath" -ForegroundColor Green
