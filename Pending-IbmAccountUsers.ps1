param(
    [switch]$RemoveUsers
)

$ErrorActionPreference = 'Stop'

## Support GNU-style flags for convenience (e.g., --RemoveUsers)
foreach ($a in $args) {
    if ($a -eq '--RemoveUsers' -or $a -eq '--removeusers') { $RemoveUsers = $true }
}

if (-not (Get-Command -Name ibmcloud -ErrorAction SilentlyContinue)) {
    throw "'ibmcloud' CLI not found in PATH. Install IBM Cloud CLI and login before running."
}

function Get-IbmAccountUsersJson {
    # Prefer JSON; fallback to table parsing if JSON not supported
    $cmd = 'ibmcloud account users --output json'
    $output = $null
    $exit = 1
    try {
        $output = & bash -lc $cmd
        $exit = $LASTEXITCODE
    }
    catch {
        $exit = 1
    }

    if ($exit -eq 0 -and -not [string]::IsNullOrWhiteSpace($output)) {
        try { return $output | ConvertFrom-Json } catch {}
    }

    # Fallback: parse table output
    $cmd = 'ibmcloud account users'
    try {
        $table = & bash -lc $cmd
    }
    catch {
        throw "Failed to list account users via 'ibmcloud account users'"
    }

    $lines = ($table -split "`n").Where({ -not [string]::IsNullOrWhiteSpace($_) })
    if ($lines.Count -lt 2) { return @() }

    # Attempt to detect column positions from header
    $header = $lines[0]
    $idxEmail = $header.IndexOf('Email')
    $idxState = $header.IndexOf('State')
    $idxAdded = $header.IndexOf('Added')

    $result = New-Object System.Collections.Generic.List[object]
    foreach ($ln in $lines | Select-Object -Skip 1) {
        $email = $null; $state = $null; $added = $null
        if ($idxEmail -ge 0) {
            $email = ($ln + ' ').Substring($idxEmail).Trim()
            if ($idxState -gt $idxEmail) { $email = $email.Substring(0, [Math]::Max(0, $idxState - $idxEmail)).Trim() }
        }
        if ($idxState -ge 0) {
            $state = ($ln + ' ').Substring($idxState).Trim()
            if ($idxAdded -gt $idxState) { $state = $state.Substring(0, [Math]::Max(0, $idxAdded - $idxState)).Trim() }
        }
        if ($idxAdded -ge 0) {
            $added = ($ln + ' ').Substring($idxAdded).Trim()
        }
        if (-not [string]::IsNullOrWhiteSpace($email)) {
            $obj = [pscustomobject]@{ email = $email; state = $state; addedOn = $added }
            [void]$result.Add($obj)
        }
    }
    return @($result)
}

function Get-PendingAccountUsersSummary {
    $users = Get-IbmAccountUsersJson
    $now = Get-Date
    $pending = @()
    foreach ($u in $users) {
        $state = $u.state
        if ($null -eq $state -and $u.Status) { $state = $u.Status }
        $stateLower = if ($state) { $state.ToString().ToLower() } else { '' }
        $isPending = $false
        if ($stateLower -in @('pending', 'invited', 'pending_accept', 'invite pending', 'invitation sent')) { $isPending = $true }
        if ($isPending) {
            $addedStr = $u.addedOn
            if ($null -eq $addedStr -and $u.added_on) { $addedStr = $u.added_on }
            if ($null -eq $addedStr -and $u.created_at) { $addedStr = $u.created_at }
            $addedDate = $null
            if ($addedStr) {
                try { $addedDate = Get-Date -Date $addedStr -ErrorAction Stop } catch { $addedDate = $null }
            }
            $days = $null
            if ($addedDate) { $days = [int]([TimeSpan]($now - $addedDate)).TotalDays }
            $uid = $null
            if ($u.user_id) { $uid = $u.user_id }
            elseif ($u.userId) { $uid = $u.userId }
            elseif ($u.id) { $uid = $u.id }
            $pending += [pscustomobject]@{
                UserId          = $uid
                Email           = $u.email
                Status          = if ($state) { $state } else { 'PENDING' }
                AddedOn         = if ($addedDate) { $addedDate } else { $addedStr }
                DaysPending     = $days
                RemoveCandidate = ($days -ne $null -and $days -gt 60)
            }
        }
    }
    return , $pending
}

function Remove-IbmAccountUser {
    param(
        [Parameter(Mandatory = $false)][string]$UserId,
        [Parameter(Mandatory = $false)][string]$Email
    )

    $resolvedUserId = $null

    if (-not [string]::IsNullOrWhiteSpace($UserId)) {
        $resolvedUserId = $UserId
    }
    elseif (-not [string]::IsNullOrWhiteSpace($Email)) {
        try {
            $accountUsers = Get-IbmAccountUsersJson
        }
        catch {
            Write-Warning "Failed to fetch account users to resolve user_id for ${Email}: $($_.Exception.Message)"
            return $false
        }

        if ($accountUsers) {
            $match = $accountUsers | Where-Object { $_.email -and ($_.email.ToString().ToLower() -eq $Email.ToLower()) } | Select-Object -First 1
            if ($match) {
                if ($match.user_id) { $resolvedUserId = $match.user_id }
                elseif ($match.userId) { $resolvedUserId = $match.userId }
                elseif ($match.id) { $resolvedUserId = $match.id }
            }
        }

        if (-not $resolvedUserId) {
            Write-Warning "Could not resolve user_id for ${Email}; cannot remove."
            return $false
        }
    }
    else {
        Write-Warning "Either -UserId or -Email must be provided."
        return $false
    }

    $cmd = "ibmcloud account user-remove $resolvedUserId"
    Write-Host "Attempting removal with: $cmd Press y then enter to remove user" -ForegroundColor DarkYellow

    $output = $null
    $exit = 1
    try {
        $output = & bash -lc $cmd
        $exit = $LASTEXITCODE
    }
    catch {
        $exit = 1
        $output = $_.Exception.Message
    }

    if ($exit -eq 0) {
        Write-Host "Removed user ID ${resolvedUserId} using: $cmd" -ForegroundColor Green
        if ($output) { $output | Write-Output }
        return $true
    }

    Write-Warning "Removal failed (exit $exit) for user ID ${resolvedUserId}: $cmd"
    if ($output) { $output | Write-Output }
    return $false
}

$pending = Get-PendingAccountUsersSummary
if (-not $pending -or $pending.Count -eq 0) {
    Write-Host "No pending users found in the account." -ForegroundColor Green
    return
}

Write-Host "Pending users:" -ForegroundColor Yellow
$pending | Sort-Object -Property DaysPending -Descending |
Select-Object UserId, Email, Status, AddedOn, DaysPending, RemoveCandidate |
Format-Table -AutoSize | Out-String | Write-Host

$candidates = $pending | Where-Object { $_.RemoveCandidate }
if (-not $candidates -or $candidates.Count -eq 0) {
    Write-Host "No pending users older than 60 days. Nothing to remove." -ForegroundColor Green
    return
}

Write-Host "Users eligible for removal (>60 days pending):" -ForegroundColor Magenta
$candidates | Select-Object UserId, Email, AddedOn, DaysPending |
Format-Table -AutoSize | Out-String | Write-Host

if ($RemoveUsers) {
    Write-Host "Removing users ..." -ForegroundColor Red
    foreach ($u in $candidates) {
        Write-Host "Removing ${($u.Email)} (pending ${($u.DaysPending)} days)" -ForegroundColor Red
        [void](Remove-IbmAccountUser -UserId $u.UserId -Email $u.Email)
    }
    Write-Host "Removal pass complete." -ForegroundColor Green
}
else {
    Write-Host "Dry run only. Use -RemoveUsers (or --RemoveUsers) to remove listed users." -ForegroundColor Cyan
}


