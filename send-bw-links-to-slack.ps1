param(
    [Parameter(Mandatory = $false)]
    [string]$CsvPath = "$PSScriptRoot/bw-send-links.csv",

    [Parameter(Mandatory = $false)]
    [string]$SlackToken = $env:SLACK_TOKEN,

    [Parameter(Mandatory = $false)]
    [string]$FallbackChannelId,

    [Parameter(Mandatory = $false)]
    [switch]$WhatIf
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Token fallback like slack_dm.py (prefers bot token if provided)
if (-not $SlackToken -or [string]::IsNullOrWhiteSpace($SlackToken)) {
    if ($env:SLACK_BOT_TOKEN) { $SlackToken = $env:SLACK_BOT_TOKEN }
}

function Invoke-SlackApi {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('GET', 'POST')]
        [string]$Method,

        [Parameter(Mandatory = $true)]
        [string]$Endpoint,

        [Parameter(Mandatory = $false)]
        [hashtable]$Body,

        [Parameter(Mandatory = $false)]
        [hashtable]$Query
    )

    if (-not $SlackToken) {
        throw 'Slack token not provided. Set -SlackToken parameter or SLACK_TOKEN env var.'
    }

    $baseUri = 'https://slack.com/api/'
    $uri = $baseUri + $Endpoint

    if ($Query) {
        $qs = ($Query.GetEnumerator() | ForEach-Object { "{0}={1}" -f [uri]::EscapeDataString($_.Key), [uri]::EscapeDataString([string]$_.Value) }) -join '&'
        $uri = ("{0}?{1}" -f $uri, $qs)
    }

    $headers = @{ Authorization = "Bearer $SlackToken" }

    $attempt = 0
    while ($true) {
        $attempt++
        try {
            if ($Method -eq 'GET') {
                $response = Invoke-RestMethod -Method Get -Uri $uri -Headers $headers -ErrorAction Stop
            }
            else {
                if ($Body) {
                    $response = Invoke-RestMethod -Method Post -Uri $uri -Headers $headers -ContentType 'application/json; charset=utf-8' -Body ($Body | ConvertTo-Json -Depth 10) -ErrorAction Stop
                }
                else {
                    $response = Invoke-RestMethod -Method Post -Uri $uri -Headers $headers -ErrorAction Stop
                }
            }
        }
        catch {
            throw $_
        }

        # Handle Slack-style errors
        if ($response -and $response.ok -eq $true) {
            return $response
        }

        # Rate limit handling (429) via headers is not surfaced by Invoke-RestMethod easily when ok=false
        # Slack often returns ok=false with an error code; handle common ones
        switch ($response.error) {
            'ratelimited' {
                $retryAfter = 5
                Start-Sleep -Seconds $retryAfter
                if ($attempt -gt 5) { throw 'Slack API rate limit persisted after retries.' }
                continue
            }
            default {
                $msg = if ($response.error) { "Slack API error: $($response.error) on $Endpoint" } else { "Slack API unknown failure on $Endpoint" }
                throw $msg
            }
        }
    }
}

function Get-SlackUserIdByEmail {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Email
    )
    $res = Invoke-SlackApi -Method GET -Endpoint 'users.lookupByEmail' -Query @{ email = $Email }
    if (-not $res.user.id) { throw "No Slack user ID for email $Email" }
    return $res.user.id
}

function Open-SlackImChannel {
    param(
        [Parameter(Mandatory = $true)]
        [string]$UserId
    )
    # Try opening a DM; if missing_scope, attempt to find an existing DM channel instead
    try {
        $res = Invoke-SlackApi -Method POST -Endpoint 'conversations.open' -Body @{ users = $UserId }
        if (-not $res.channel.id) { throw "Failed to open conversation for user $UserId" }
        return $res.channel.id
    }
    catch {
        $msg = $_.Exception.Message
        if ($msg -match 'missing_scope') {
            # Fallback: search for an existing DM channel if the token lacks conversations.open scope
            $existing = Find-ExistingImChannelByUserId -UserId $UserId
            if ($existing) {
                return $existing
            }
            throw "Slack token missing required scope to open DMs (need im:write or conversations:write). Could not find existing DM channel for $UserId."
        }
        throw
    }
}

function Find-ExistingImChannelByUserId {
    param(
        [Parameter(Mandatory = $true)]
        [string]$UserId
    )
    # Requires conversations:read (or im:read on classic)
    $cursor = $null
    while ($true) {
        $query = @{ types = 'im'; limit = 1000 }
        if ($cursor) { $query.cursor = $cursor }
        $res = Invoke-SlackApi -Method GET -Endpoint 'conversations.list' -Query $query
        if ($res.channels) {
            foreach ($c in $res.channels) {
                if ($c.user -eq $UserId) { return $c.id }
            }
        }
        $cursor = $res.response_metadata.next_cursor
        if (-not $cursor) { break }
    }
    return $null
}

function Send-SlackMessage {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ChannelId,

        [Parameter(Mandatory = $true)]
        [string]$Text,

        [Parameter(Mandatory = $false)]
        [string]$UserId
    )
    if ($WhatIf) {
        Write-Host "WhatIf: Would send to $ChannelId (userId: $UserId) -> $Text"
        return
    }
    $null = Invoke-SlackApi -Method POST -Endpoint 'chat.postMessage' -Body @{ channel = $ChannelId; text = $Text }
}

Write-Host "Reading CSV: $CsvPath"
if (-not (Test-Path -LiteralPath $CsvPath)) {
    throw "CSV file not found: $CsvPath"
}

$rows = Import-Csv -LiteralPath $CsvPath
if (-not $rows -or $rows.Count -eq 0) {
    throw 'CSV has no rows.'
}

# Expecting columns: Username, UserPrincipal, Email, vCenterUrl, AccessUrl
$requiredColumns = 'Username', 'UserPrincipal', 'Email', 'vCenterUrl', 'AccessUrl'
foreach ($col in $requiredColumns) {
    if (-not ($rows[0].PSObject.Properties.Name -contains $col)) {
        throw "CSV missing required column: $col"
    }
}

$sent = 0
$fail = 0
foreach ($row in $rows) {
    $email = [string]$row.Email
    $accessUrl = [string]$row.AccessUrl
    $vCenterUrl = [string]$row.vCenterUrl
    $userId = $null

    if (-not $email) { Write-Warning 'Skipping row with empty Email (userId: unknown)'; continue }
    if (-not $accessUrl) {
        $uidForSkip = $null
        try { $uidForSkip = Get-SlackUserIdByEmail -Email $email } catch { $uidForSkip = $null }
        $uidText = if ($uidForSkip) { $uidForSkip } else { 'unknown' }
        Write-Warning "Skipping $email (userId: $uidText) due to empty AccessUrl"
        continue
    }

    try {
        $userId = Get-SlackUserIdByEmail -Email $email
        $message = "Hello! vCenter: $vCenterUrl`nHere is your Bitwarden Send link: $accessUrl"

        # First attempt: send directly to the user ID (like slack_dm.py)
        $directSent = $false
        try {
            Send-SlackMessage -ChannelId $userId -Text $message -UserId $userId
            $directSent = $true
        }
        catch {
            $directError = $_.Exception.Message
        }

        if (-not $directSent) {
            # Second attempt: open a DM and send there (requires conversations:write or im:write)
            $channelId = $null
            $openError = $null
            try { $channelId = Open-SlackImChannel -UserId $userId } catch { $openError = $_.Exception.Message }

            if ($channelId) {
                Send-SlackMessage -ChannelId $channelId -Text $message -UserId $userId
                $sent++
                Write-Host "Sent to $email (userId: $userId) via opened DM"
                continue
            }

            # Final attempt: use fallback channel if provided
            if ($FallbackChannelId) {
                $mention = "<@$userId>"
                $fallbackMsg = "$mention $message"
                Send-SlackMessage -ChannelId $FallbackChannelId -Text $fallbackMsg -UserId $userId
                $sent++
                Write-Host "Sent via fallback to $email (userId: $userId) in channel $FallbackChannelId; directError: $directError; openError: $openError"
                continue
            }

            throw "Unable to DM $email (userId: $userId). directError: $directError; openError: $openError. Provide -FallbackChannelId or add required scopes."
        }
        $sent++
        Write-Host "Sent to $email (userId: $userId)"
    }
    catch {
        $fail++
        $uidText = if ($userId) { $userId } else { 'unknown' }
        Write-Warning "Failed for ${email} (userId: $uidText): $($_.Exception.Message)"
    }
}

Write-Host "Completed. Sent=$sent Failed=$fail"

<#
Slack token note:
- Token starting with xoxp- is a User token (classic user token). It requires scopes:
  - users:read.email (for users.lookupByEmail)
  - users:read (generally required)
  - im:write or conversations:write (for conversations.open)
  - chat:write (to post messages)
Using Web API endpoints:
- users.lookupByEmail: GET https://slack.com/api/users.lookupByEmail?email=...
- conversations.open: POST https://slack.com/api/conversations.open { users }
- chat.postMessage: POST https://slack.com/api/chat.postMessage { channel, text }
Set token via -SlackToken or $env:SLACK_TOKEN.
#>


