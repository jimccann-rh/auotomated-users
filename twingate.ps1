param(
  [Parameter(Mandatory = $false)]
  [string]$CsvPath,
  [switch]$ListGroups
)

# Inputs
$subdomain = "acme"          # e.g. "acme"
$apiKey = $env:TWINGATE_API_KEY        # Read from environment
if (-not $apiKey -or $apiKey.Trim() -eq '') {
  throw "Environment variable TWINGATE_API_KEY is not set"
}

# If only listing groups, fetch and display groups then exit
if ($ListGroups) {
  $headers = @{
    "X-API-KEY"    = $apiKey
    "Content-Type" = "application/json"
  }

  $queryGroups = @'
query Groups($first: Int, $after: String) {
  groups(first: $first, after: $after) {
    edges { node { id name } }
    pageInfo { hasNextPage endCursor }
  }
}
'@

  $allGroups = @()
  $after = $null
  do {
    $groupsBody = @{
      query     = $queryGroups
      variables = @{ first = 200; after = $after }
    } | ConvertTo-Json -Depth 5
    $groupsResp = Invoke-RestMethod -Uri "https://$subdomain.twingate.com/api/graphql/" -Method Post -Headers $headers -Body $groupsBody
    $edges = $groupsResp.data.groups.edges
    foreach ($edge in $edges) {
      $allGroups += [pscustomobject]@{ Name = [string]$edge.node.name; Id = $edge.node.id }
    }
    $pageInfo = $groupsResp.data.groups.pageInfo
    $hasNext = if ($pageInfo) { [bool]$pageInfo.hasNextPage } else { $false }
    $after = if ($pageInfo) { $pageInfo.endCursor } else { $null }
  } while ($hasNext)

  $allGroups | Sort-Object Name
  return
}

# Path to CSV of users (expects header "Email")
$csvPath = if ($CsvPath -and $CsvPath.Trim() -ne '') { $CsvPath } else { Join-Path $PSScriptRoot 'new-users-passwords.csv' }
if (-not (Test-Path -LiteralPath $csvPath)) {
  throw "CSV not found at $csvPath"
}

# Load email and group from CSV.
# - If the CSV has an "Email" header, use it and try to detect a Group/GroupName header.
# - Otherwise, treat it as headerless and take col2 as Email and col6 as Group.
$firstLine = Get-Content -LiteralPath $csvPath -TotalCount 1
$hasEmailHeader = ($firstLine -match '(?i)\bemail\b')

if ($hasEmailHeader) {
  $imported = Import-Csv -LiteralPath $csvPath
  $rowsData = foreach ($row in $imported) {
    if ($row.Email -and $row.Email.Trim() -ne '') {
      $groupProp = $row.PSObject.Properties | Where-Object { $_.Name -match '^(?i)group(Name)?$' } | Select-Object -First 1
      [pscustomobject]@{
        Email = $row.Email
        Group = if ($groupProp) { [string]$groupProp.Value } else { $null }
      }
    }
  }
  # De-duplicate by Email
  $rowsData = $rowsData | Group-Object Email | ForEach-Object { $_.Group | Select-Object -First 1 }
}
else {
  $csvString = (Get-Content -LiteralPath $csvPath | Where-Object { $_.Trim() -ne '' } | Out-String)
  $rows = ConvertFrom-Csv -InputObject $csvString -Header 'Col1', 'Col2', 'Col3', 'Col4', 'Col5', 'Col6', 'Col7', 'Col8'
  $rowsData = $rows |
  Where-Object { $_.Col2 -and $_.Col2.Trim() -ne '' } |
  ForEach-Object {
    [pscustomobject]@{
      Email = $_.Col2
      Group = $_.Col6
    }
  }
  # De-duplicate by Email
  $rowsData = $rowsData | Group-Object Email | ForEach-Object { $_.Group | Select-Object -First 1 }
}

if (-not $rowsData -or $rowsData.Count -eq 0) {
  throw "No emails found in CSV at $csvPath"
}

# Request
$headers = @{
  "X-API-KEY"    = $apiKey
  "Content-Type" = "application/json"
}

$query = @'
mutation UserCreate($email: String!, $shouldSendInvite: Boolean) {
  userCreate(email: $email, shouldSendInvite: $shouldSendInvite) {
    ok
    error
    entity { id email }
  }
}
'@

$queryGroups = @'
query Groups($first: Int, $after: String) {
  groups(first: $first, after: $after) {
    edges { node { id name } }
    pageInfo { hasNextPage endCursor }
  }
}
'@

$mutationGroupUpdate = @'
mutation GroupUpdate($groupId: ID!, $addedUserIds: [ID!]) {
  groupUpdate(id: $groupId, addedUserIds: $addedUserIds) {
    ok
    error
    entity { id name }
  }
}
'@

# Resolve groups once (optional, with pagination)
$groupMap = @{}
try {
  $after = $null
  do {
    $groupsBody = @{
      query     = $queryGroups
      variables = @{ first = 200; after = $after }
    } | ConvertTo-Json -Depth 5
    $groupsResp = Invoke-RestMethod -Uri "https://$subdomain.twingate.com/api/graphql/" -Method Post -Headers $headers -Body $groupsBody
    $edges = $groupsResp.data.groups.edges
    foreach ($edge in $edges) {
      $name = [string]$edge.node.name
      $nameLower = if ($name) { $name.Trim().ToLowerInvariant() } else { $null }
      if ($nameLower -and -not $groupMap.ContainsKey($nameLower)) {
        $groupMap[$nameLower] = $edge.node.id
      }
    }
    $hasNext = $false
    $pageInfo = $groupsResp.data.groups.pageInfo
    if ($pageInfo) {
      $hasNext = [bool]$pageInfo.hasNextPage
      $after = $pageInfo.endCursor
    }
  } while ($hasNext)
}
catch {}

# Execute per-user create/invite and add to group
$results = @()
foreach ($row in $rowsData) {
  $email = $row.Email
  $groupName = if ($row.Group) { [string]$row.Group.Trim() } else { $null }

  $variables = @{
    email            = $email
    shouldSendInvite = $true
  }
  $body = @{
    query     = $query
    variables = $variables
  } | ConvertTo-Json -Depth 5

  $resp = Invoke-RestMethod -Uri "https://$subdomain.twingate.com/api/graphql/" -Method Post -Headers $headers -Body $body
  $userOk = $resp.data.userCreate.ok
  $userErr = $resp.data.userCreate.error
  $userId = if ($resp.data.userCreate.entity) { $resp.data.userCreate.entity.id } else { $null }

  $groupOk = $null
  $groupErr = $null
  $groupId = $null

  if ($userOk -and $userId -and $groupName -and $groupName.Trim() -ne '') {
    $key = $groupName.ToLowerInvariant()
    if ($groupMap.ContainsKey($key)) {
      $groupId = $groupMap[$key]
    }

    if ($groupId) {
      $gBody = @{
        query     = $mutationGroupUpdate
        variables = @{ groupId = $groupId; addedUserIds = @($userId) }
      } | ConvertTo-Json -Depth 5
      $gResp = Invoke-RestMethod -Uri "https://$subdomain.twingate.com/api/graphql/" -Method Post -Headers $headers -Body $gBody
      $groupOk = $gResp.data.groupUpdate.ok
      $groupErr = $gResp.data.groupUpdate.error
    }
    else {
      $groupOk = $false
      $groupErr = "Group not found by name: $groupName"
    }
  }

  $result = [pscustomobject]@{
    Email    = $email
    UserOk   = $userOk
    UserErr  = $userErr
    UserId   = $userId
    Group    = $groupName
    GroupOk  = $groupOk
    GroupErr = $groupErr
  }
  $results += $result
}

$results
