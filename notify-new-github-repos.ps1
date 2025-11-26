param(
    [Parameter(Mandatory = $false)]
    [string]$GithubToken = $env:GITHUB_TOKEN,

    [Parameter(Mandatory = $true)]
    [string]$GithubUserOrOrg,

    [Parameter(Mandatory = $false)]
    [ValidateSet('auto', 'user', 'org')]
    [string]$GithubEntityType = 'auto',

    [Parameter(Mandatory = $false)]
    [string]$SlackToken = $env:SLACK_TOKEN,

    [Parameter(Mandatory = $false)]
    [string]$SlackChannelId,

    [Parameter(Mandatory = $false)]
    [string]$SlackUserEmail,

    [Parameter(Mandatory = $false)]
    [string]$FallbackChannelId,

    [Parameter(Mandatory = $false)]
    [string]$StatePath = "$PSScriptRoot/.known-github-repos.json",

    [Parameter(Mandatory = $false)]
    [switch]$WhatIf
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Slack token fallback like send-bw-links-to-slack.ps1 (prefers bot token if provided)
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
        throw 'Slack token not provided. Set -SlackToken parameter or SLACK_TOKEN/SLACK_BOT_TOKEN env var.'
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

        if ($response -and $response.ok -eq $true) {
            return $response
        }

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
    param([Parameter(Mandatory = $true)][string]$Email)
    $res = Invoke-SlackApi -Method GET -Endpoint 'users.lookupByEmail' -Query @{ email = $Email }
    if (-not $res.user.id) { throw "No Slack user ID for email $Email" }
    return $res.user.id
}

function Open-SlackImChannel {
    param([Parameter(Mandatory = $true)][string]$UserId)
    try {
        $res = Invoke-SlackApi -Method POST -Endpoint 'conversations.open' -Body @{ users = $UserId }
        if (-not $res.channel.id) { throw "Failed to open conversation for user $UserId" }
        return $res.channel.id
    }
    catch {
        $msg = $_.Exception.Message
        if ($msg -match 'missing_scope') {
            $existing = Find-ExistingImChannelByUserId -UserId $UserId
            if ($existing) { return $existing }
            throw "Slack token missing required scope to open DMs (need im:write or conversations:write). Could not find existing DM channel for $UserId."
        }
        throw
    }
}

function Find-ExistingImChannelByUserId {
    param([Parameter(Mandatory = $true)][string]$UserId)
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
        [Parameter(Mandatory = $true)][string]$ChannelId,
        [Parameter(Mandatory = $true)][string]$Text
    )
    if ($WhatIf) {
        Write-Host "WhatIf: Would send to $ChannelId -> $Text"
        return
    }
    $null = Invoke-SlackApi -Method POST -Endpoint 'chat.postMessage' -Body @{ channel = $ChannelId; text = $Text }
}

function Get-GitHubRepositories {
    param(
        [Parameter(Mandatory = $true)][string]$UserOrOrg,
        [Parameter(Mandatory = $true)][ValidateSet('auto', 'user', 'org')][string]$EntityType
    )
    # Build headers allowing unauthenticated requests (public repos) while
    # using the token if provided (higher rate limits, private repos).
    $headers = @{
        'User-Agent' = 'repo-watcher-script'
        Accept       = 'application/vnd.github+json'
    }
    if ($GithubToken) {
        $headers.Authorization = "token $GithubToken"
    }

    function Get-PagedRepos {
        param([string]$BaseUri)
        $page = 1
        $all = @()
        while ($true) {
            $uri = if ($BaseUri -match '\?') { "$BaseUri&per_page=100&page=$page" } else { "$BaseUri?per_page=100&page=$page" }
            $batch = @()
            try {
                $batch = Invoke-RestMethod -Method Get -Uri $uri -Headers $headers -ErrorAction Stop
            }
            catch {
                throw $_
            }
            if (-not $batch -or $batch.Count -eq 0) { break }
            $all += $batch
            if ($batch.Count -lt 100) { break }
            $page++
        }
        return $all
    }

    $repos = @()
    if ($EntityType -eq 'user' -or $EntityType -eq 'auto') {
        try {
            $repos = Get-PagedRepos -BaseUri ("https://api.github.com/users/{0}/repos?type=all" -f [uri]::EscapeDataString($UserOrOrg))
            $items = @($repos | ForEach-Object { [pscustomobject]@{ Name = $_.name; Description = $_.description } })
            if ($EntityType -eq 'user') { return ($items | Sort-Object -Property Name -Unique) }
            if ($items -and $items.Count -gt 0) { return ($items | Sort-Object -Property Name -Unique) }
        }
        catch {
            if ($EntityType -eq 'user') { throw "Failed to fetch user repos for '$UserOrOrg': $($_.Exception.Message)" }
        }
    }

    if ($EntityType -eq 'org' -or $EntityType -eq 'auto') {
        try {
            $repos = Get-PagedRepos -BaseUri ("https://api.github.com/orgs/{0}/repos?type=all" -f [uri]::EscapeDataString($UserOrOrg))
            $items = @($repos | ForEach-Object { [pscustomobject]@{ Name = $_.name; Description = $_.description } })
            return ($items | Sort-Object -Property Name -Unique)
        }
        catch {
            throw "Failed to fetch org repos for '$UserOrOrg': $($_.Exception.Message)"
        }
    }
}

function Load-KnownRepositories {
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return @() }
    try {
        $raw = Get-Content -LiteralPath $Path -Raw
        if ([string]::IsNullOrWhiteSpace($raw)) { return @() }
        $arr = $raw | ConvertFrom-Json
        if ($arr -is [array]) { return $arr }
        return @()
    }
    catch {
        Write-Warning "Failed to read state from $($Path): $($_.Exception.Message)"
        return @()
    }
}

function Save-KnownRepositories {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string[]]$RepoNames
    )
    try {
        $dir = Split-Path -Parent -Path $Path
        if ($dir -and -not (Test-Path -LiteralPath $dir)) { $null = New-Item -ItemType Directory -Path $dir -Force }
        $RepoNames | Sort-Object -Unique | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $Path -NoNewline
    }
    catch {
        throw "Failed to write state to $($Path): $($_.Exception.Message)"
    }
}

Write-Host "Fetching repositories for: $GithubUserOrOrg (type: $GithubEntityType)"
$currentRepos = @(Get-GitHubRepositories -UserOrOrg $GithubUserOrOrg -EntityType $GithubEntityType)
if (-not $currentRepos) { $currentRepos = @() }

Write-Host "Loading known repositories state: $StatePath"
$stateExists = Test-Path -LiteralPath $StatePath
if ($stateExists) {
    $knownRepos = Load-KnownRepositories -Path $StatePath
    if (-not $knownRepos) { $knownRepos = @() }
}
else {
    $knownRepos = @()
    # First run: initialize state with current repos and skip notifications
    $currentRepoNames = @($currentRepos | Select-Object -ExpandProperty Name -Unique)
    Save-KnownRepositories -Path $StatePath -RepoNames $currentRepoNames
    Write-Host "No state file found. Baseline initialized with current repositories. Skipping notifications on first run."
    return
}

$currentRepoNames = @($currentRepos | Select-Object -ExpandProperty Name -Unique)
$newRepos = @($currentRepos | Where-Object { -not ($knownRepos -contains $_.Name) })

if (-not $newRepos -or $newRepos.Count -eq 0) {
    Write-Host "No new repositories detected. Known=$($knownRepos.Count) Current=$($currentRepos.Count)"
    # Keep state up to date with current snapshot
    Save-KnownRepositories -Path $StatePath -RepoNames $currentRepoNames
    return
}

Write-Host "Detected $($newRepos.Count) new repos."

# Save state before sending notifications to ensure idempotency across runs
Save-KnownRepositories -Path $StatePath -RepoNames $currentRepoNames

# Write discovered new repositories to a timestamped file alongside the state file
try {
    $stateDir = Split-Path -Parent -Path $StatePath
    if (-not $stateDir) { $stateDir = $PSScriptRoot }
    if ($stateDir -and -not (Test-Path -LiteralPath $stateDir)) { $null = New-Item -ItemType Directory -Path $stateDir -Force }
    $timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $newReposFile = Join-Path -Path $stateDir -ChildPath ("new-github-repos-{0}.json" -f $timestamp)
    $newRepos | Sort-Object -Property Name -Unique | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $newReposFile -NoNewline
    Write-Host "Wrote new repositories list to: $newReposFile"
}
catch {
    Write-Warning "Failed to write new repositories file: $($_.Exception.Message)"
}

# Determine Slack destination
$targetChannel = $null
$dmUserId = $null
if ($SlackUserEmail) {
    try {
        $dmUserId = Get-SlackUserIdByEmail -Email $SlackUserEmail
        $targetChannel = $dmUserId
    }
    catch {
        $dmErr = $_.Exception.Message
        Write-Warning "Failed to resolve Slack user by email '$SlackUserEmail': $dmErr"
    }
}

if (-not $targetChannel -and $SlackChannelId) {
    $targetChannel = $SlackChannelId
}

foreach ($repo in $newRepos) {
    $name = $repo.Name
    $desc = $repo.Description
    $subject = "New GitHub Repository Detected: $name"
    $body = "A new repository '$name' has been created under $GithubUserOrOrg."
    if ($desc -and -not [string]::IsNullOrWhiteSpace($desc)) {
        $body += "`nDescription: $desc"
    }
    $text = "$subject`n$body"

    $sent = $false
    $directError = $null
    $openError = $null

    if ($targetChannel) {
        try {
            Send-SlackMessage -ChannelId $targetChannel -Text $text
            $sent = $true
            Write-Host "Notified for $name via target $targetChannel"
        }
        catch {
            $directError = $_.Exception.Message
        }
    }
    elseif ($dmUserId) {
        try {
            # Try DM open flow if we specifically intended a DM
            $channelId = Open-SlackImChannel -UserId $dmUserId
            Send-SlackMessage -ChannelId $channelId -Text $text
            $sent = $true
            Write-Host "Notified for $name via opened DM"
        }
        catch {
            $openError = $_.Exception.Message
        }
    }

    if (-not $sent -and $FallbackChannelId) {
        try {
            $mention = if ($dmUserId) { "<@$dmUserId> " } else { "" }
            Send-SlackMessage -ChannelId $FallbackChannelId -Text ($mention + $text)
            $sent = $true
            Write-Host "Notified for $name via fallback channel $FallbackChannelId"
        }
        catch {
            $fallbackError = $_.Exception.Message
            Write-Warning "Failed to notify for $name. directError: $directError; openError: $openError; fallbackError: $fallbackError"
        }
    }

    if (-not $sent -and -not $FallbackChannelId) {
        throw "Unable to send Slack notification for $name. Provide -SlackChannelId or -SlackUserEmail (with required scopes) or -FallbackChannelId. directError: $directError; openError: $openError"
    }
}

Save-KnownRepositories -Path $StatePath -RepoNames $currentRepoNames
Write-Host "Completed. NewRepos=$($newRepos.Count) TotalCurrent=$($currentRepos.Count)"


