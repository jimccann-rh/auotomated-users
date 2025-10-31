param(
    [Parameter(Mandatory = $true)]
    [string]$CsvPath,
    
    [Parameter(Mandatory = $true)]
    [string]$vCenterServer,

    [Parameter(Mandatory = $false)]
    [PSCredential]$Credential,

    [Parameter(Mandatory = $false)]
    [string]$SsoDomain = "vsphere.local",

    [Parameter(Mandatory = $false)]
    [string]$OutputPasswordFile = "./Created_vCenterUsers_$(Get-Date -Format 'yyyyMMdd_HHmmss').csv",

    [Parameter(Mandatory = $false)]
    [switch]$InstallModules = $false,

    [Parameter(Mandatory = $false)]
    [switch]$WhatIf = $false,

    [Parameter(Mandatory = $false)]
    [switch]$UsePermissionFallback = $false,

    [Parameter(Mandatory = $false)]
    [string]$FallbackRole = "ReadOnly",

    [Parameter(Mandatory = $false)]
    [string]$FallbackScope = "Datacenters"
)

function Write-Color {
    param(
        [Parameter(Mandatory = $true)][string]$Message,
        [Parameter()][string]$Color = 'White'
    )
    Write-Host $Message -ForegroundColor $Color
}

function Install-RequiredModules {
    Write-Color "Checking required modules..." 'Yellow'
    if (-not (Get-Module -ListAvailable -Name VMware.PowerCLI)) {
        Write-Color "Installing VMware.PowerCLI..." 'Yellow'
        Install-Module -Name VMware.PowerCLI -Scope CurrentUser -Force -ErrorAction Stop
    }
    if (-not (Get-Module -ListAvailable -Name VMware.vSphere.SsoAdmin)) {
        Write-Color "Installing VMware.vSphere.SsoAdmin..." 'Yellow'
        try {
            Install-Module -Name VMware.vSphere.SsoAdmin -Scope CurrentUser -Force -ErrorAction Stop
        }
        catch {
            Write-Color "VMware.vSphere.SsoAdmin not available in PSGallery. Please install from GitHub: https://github.com/vmware/PowerCLI-Example-Scripts/tree/master/Modules/VMware.vSphere.SsoAdmin" 'Red'
            throw
        }
    }
}

function New-StrongPassword {
    param([int]$Length = 20)
    $upper = "ABCDEFGHJKLMNPQRSTUVWXYZ"
    $lower = "abcdefghijkmnopqrstuvwxyz"
    $digits = "23456789"
    $special = "!"

    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    function Get-RandChar([string]$chars) {
        $bytes = New-Object byte[] 4
        $rng.GetBytes($bytes)
        $idx = [BitConverter]::ToUInt32($bytes, 0) % $chars.Length
        return $chars[$idx]
    }

    $passwordChars = @()
    $passwordChars += Get-RandChar $upper
    $passwordChars += Get-RandChar $lower
    $passwordChars += Get-RandChar $digits
    $passwordChars += Get-RandChar $special

    $all = ($upper + $lower + $digits + $special)
    for ($i = $passwordChars.Count; $i -lt $Length; $i++) { $passwordChars += Get-RandChar $all }

    # Shuffle
    $shuffled = $passwordChars | Sort-Object { Get-Random }
    -join $shuffled
}

function Connect-VCenterServerSession {
    param([string]$Server, [PSCredential]$Cred)
    Import-Module VMware.PowerCLI -ErrorAction Stop
    Set-PowerCLIConfiguration -InvalidCertificateAction Ignore -Confirm:$false -Scope Session | Out-Null
    if ($Cred) { Connect-VIServer -Server $Server -Credential $Cred -ErrorAction Stop | Out-Null }
    else { Connect-VIServer -Server $Server -ErrorAction Stop | Out-Null }
}

function Connect-SsoAdminSession {
    param([string]$Server, [PSCredential]$AdminCred)
    Import-Module VMware.vSphere.SsoAdmin -ErrorAction Stop
    if (-not $AdminCred) { throw "Credential is required for SSO admin connection" }
    try {
        Connect-SsoAdminServer -Server $Server -Credential $AdminCred -SkipCertificateCheck -ErrorAction Stop | Out-Null
    }
    catch {
        try {
            # Retry without SkipCertificateCheck in case the module version doesn't support it
            Connect-SsoAdminServer -Server $Server -Credential $AdminCred -ErrorAction Stop | Out-Null
        }
        catch {
            # Final fallback using username/password parameters if available
            $user = $AdminCred.UserName
            $pass = $AdminCred.GetNetworkCredential().Password
            Connect-SsoAdminServer -Server $Server -User $user -Password $pass -ErrorAction Stop | Out-Null
        }
    }
}

function Get-CsvRowsNoHeader {
    param([string]$Path)
    $lines = Get-Content -Path $Path | Where-Object { $_.Trim().Length -gt 0 }
    foreach ($line in $lines) {
        $parts = $line.Split(',')
        if ($parts.Count -lt 5) { continue }
        [PSCustomObject]@{
            UserName  = $parts[0].Trim()
            Email     = $parts[1].Trim()
            Group     = $parts[2].Trim()
            FirstName = $parts[3].Trim()
            LastName  = $parts[4].Trim()
        }
    }
}

# Compatibility wrappers for SSO cmdlets across module versions
function Get-SsoPersonUserCompat {
    param([string]$User, [string]$Domain)
    $cmd = Get-Command Get-SsoPersonUser -ErrorAction Stop
    Write-Color ("Get-SsoPersonUser params: " + ($cmd.Parameters.Keys -join ', ')) 'Cyan'
    $p = @{}
    if ($cmd.Parameters.ContainsKey('Name')) { $p.Name = $User }
    elseif ($cmd.Parameters.ContainsKey('UserName')) { $p.UserName = $User }
    elseif ($cmd.Parameters.ContainsKey('User')) { $p.User = $User }
    if ($cmd.Parameters.ContainsKey('Domain')) { $p.Domain = $Domain }
    elseif ($cmd.Parameters.ContainsKey('Id')) { $p.Id = "$User@$Domain" }
    return & Get-SsoPersonUser @p -ErrorAction Stop
}

function New-SsoPersonUserCompat {
    param([string]$User, [string]$Domain, [string]$First, [string]$Last, [string]$Email, [string]$Password)
    $cmd = Get-Command New-SsoPersonUser -ErrorAction Stop
    Write-Color ("New-SsoPersonUser params: " + ($cmd.Parameters.Keys -join ', ')) 'Cyan'
    $p = @{}
    if ($cmd.Parameters.ContainsKey('Name')) { $p.Name = $User }
    elseif ($cmd.Parameters.ContainsKey('UserName')) { $p.UserName = $User }
    elseif ($cmd.Parameters.ContainsKey('User')) { $p.User = $User }
    if ($cmd.Parameters.ContainsKey('Domain')) { $p.Domain = $Domain }
    if ($cmd.Parameters.ContainsKey('FirstName')) { $p.FirstName = $First }
    elseif ($cmd.Parameters.ContainsKey('Firstname')) { $p.Firstname = $First }
    if ($cmd.Parameters.ContainsKey('LastName')) { $p.LastName = $Last }
    elseif ($cmd.Parameters.ContainsKey('Lastname')) { $p.Lastname = $Last }
    if ($cmd.Parameters.ContainsKey('EmailAddress')) { $p.EmailAddress = $Email }
    if ($cmd.Parameters.ContainsKey('Password')) { $p.Password = $Password }
    return & New-SsoPersonUser @p -ErrorAction Stop
}

function Get-SsoGroupCompat {
    param([string]$Group, [string]$Domain)
    $cmd = Get-Command Get-SsoGroup -ErrorAction Stop
    Write-Color ("Get-SsoGroup params: " + ($cmd.Parameters.Keys -join ', ')) 'Cyan'
    $p = @{}
    if ($cmd.Parameters.ContainsKey('Name')) { $p.Name = $Group }
    elseif ($cmd.Parameters.ContainsKey('GroupName')) { $p.GroupName = $Group }
    if ($cmd.Parameters.ContainsKey('Domain')) { $p.Domain = $Domain }
    return & Get-SsoGroup @p -ErrorAction Stop
}

function New-SsoGroupCompat {
    param([string]$Group, [string]$Domain, [string]$Description)
    $cmd = Get-Command New-SsoGroup -ErrorAction Stop
    Write-Color ("New-SsoGroup params: " + ($cmd.Parameters.Keys -join ', ')) 'Cyan'
    $p = @{}
    if ($cmd.Parameters.ContainsKey('Name')) { $p.Name = $Group }
    elseif ($cmd.Parameters.ContainsKey('GroupName')) { $p.GroupName = $Group }
    if ($cmd.Parameters.ContainsKey('Domain')) { $p.Domain = $Domain }
    if ($cmd.Parameters.ContainsKey('Description')) { $p.Description = $Description }
    return & New-SsoGroup @p -ErrorAction Stop
}

function Test-UserInSsoGroupCompat {
    param($GroupObj, $UserObj, [string]$Domain)
    # Prefer dedicated list-members cmdlet if present
    $listCmd = Get-Command -Name Get-UsersInSsoGroup -ErrorAction SilentlyContinue
    if ($listCmd) {
        Write-Color ("Get-UsersInSsoGroup params: " + ($listCmd.Parameters.Keys -join ', ')) 'Cyan'
        try {
            $p = @{}
            if ($listCmd.Parameters.ContainsKey('TargetGroup')) { $p.TargetGroup = $GroupObj }
            elseif ($listCmd.Parameters.ContainsKey('GroupName')) { $p.GroupName = $GroupObj.Name }
            elseif ($listCmd.Parameters.ContainsKey('Group')) { $p.Group = $GroupObj.Name }
            $members = & Get-UsersInSsoGroup @p -ErrorAction Stop
            if ($members) {
                $match = $members | Where-Object { $_.Name -eq $UserObj.Name -or $_.Id -eq "$($UserObj.Name)@$Domain" }
                if ($match) { return $true }
            }
        }
        catch {}
    }
    # Unknown -> not sure; let caller decide to attempt add
    return $false
}

function Add-SsoGroupMemberCompat {
    param($GroupObj, $UserObj, [string]$Domain)
    $cmd = Get-Command -Name Add-SsoGroupMember -ErrorAction SilentlyContinue
    if ($cmd) {
        Write-Color ("Add-SsoGroupMember params: " + ($cmd.Parameters.Keys -join ', ')) 'Cyan'
        try {
            if ($cmd.Parameters.ContainsKey('Group') -and $cmd.Parameters.ContainsKey('Members')) {
                Add-SsoGroupMember -Group $GroupObj -Members @($UserObj) -ErrorAction Stop | Out-Null
                return $true
            }
            elseif ($cmd.Parameters.ContainsKey('GroupName') -and $cmd.Parameters.ContainsKey('Principal')) {
                Add-SsoGroupMember -GroupName $GroupObj.Name -Domain $Domain -Principal $UserObj.Name -ErrorAction Stop | Out-Null
                return $true
            }
        }
        catch {
            $msg = $_.Exception.Message
            if ($msg -match 'already' -or $msg -match 'exists' -or $msg -match 'not added') {
                Write-Color "User appears to already be a member of group (Add-SsoGroupMember): $msg" 'Yellow'
                return $true
            }
        }
    }
    # Alternative cmdlet name in your module
    $cmd2 = Get-Command -Name Add-UserToSsoGroup -ErrorAction SilentlyContinue
    if ($cmd2) {
        Write-Color ("Add-UserToSsoGroup params: " + ($cmd2.Parameters.Keys -join ', ')) 'Cyan'
        $principal = if ($UserObj.PSObject.Properties.Name -contains 'Domain' -and $UserObj.Domain) { "${($UserObj.Name)}@${($UserObj.Domain)}" } else { $UserObj.Name }
        $groupBase = if ($GroupObj -and ($GroupObj.PSObject.Properties.Name -contains 'Name')) { $GroupObj.Name } else { [string]$GroupObj }
        $groupWithDomain = if ($Domain) { "$groupBase@$Domain" } else { $groupBase }

        # This cmdlet expects objects, not strings; build both object and string variants
        # First attempt: pass objects for User and TargetGroup
        try {
            $pObj = @{}
            if ($cmd2.Parameters.ContainsKey('User')) { $pObj.User = $UserObj } elseif ($cmd2.Parameters.ContainsKey('UserName')) { $pObj.UserName = $UserObj.Name }
            if ($cmd2.Parameters.ContainsKey('TargetGroup')) { $pObj.TargetGroup = $GroupObj } elseif ($cmd2.Parameters.ContainsKey('GroupName')) { $pObj.GroupName = $GroupObj.Name } elseif ($cmd2.Parameters.ContainsKey('Group')) { $pObj.Group = $GroupObj.Name }
            & Add-UserToSsoGroup @pObj -ErrorAction Stop | Out-Null
            return $true
        }
        catch {
            $msg = $_.Exception.Message
            Write-Color ("Add-UserToSsoGroup object try failed: $msg") 'Yellow'
            if ($msg -match 'not added' -or $msg -match 'already' -or $msg -match 'exists') {
                Write-Color "User appears to already be a member of group (object form). Treating as success." 'Yellow'
                return $true
            }
        }

        # Second attempt: pass string principal and group name
        try {
            $pStr = @{}
            if ($cmd2.Parameters.ContainsKey('User')) { $pStr.User = $principal } elseif ($cmd2.Parameters.ContainsKey('UserName')) { $pStr.UserName = $principal }
            if ($cmd2.Parameters.ContainsKey('TargetGroup')) { $pStr.TargetGroup = $groupBase } elseif ($cmd2.Parameters.ContainsKey('GroupName')) { $pStr.GroupName = $groupBase } elseif ($cmd2.Parameters.ContainsKey('Group')) { $pStr.Group = $groupBase }
            & Add-UserToSsoGroup @pStr -ErrorAction Stop | Out-Null
            return $true
        }
        catch {
            $msg = $_.Exception.Message
            Write-Color ("Add-UserToSsoGroup string try failed: $msg") 'Yellow'
            if ($msg -match 'not added' -or $msg -match 'already' -or $msg -match 'exists') {
                Write-Color "User appears to already be a member of group (string form). Treating as success." 'Yellow'
                return $true
            }
        }
    }
    Write-Color "Group membership cmdlet not available in your VMware.vSphere.SsoAdmin module." 'Yellow'
    Write-Color "Detected commands: $(($cmd | ForEach-Object Name) -join ', '), $(($cmd2 | ForEach-Object Name) -join ', '))" 'Yellow'
    return $false
}

function Grant-VIPermissionFallback {
    param(
        [string]$UserPrincipal,
        [string]$RoleName,
        [string]$ScopeName
    )
    try {
        $entity = $null
        # Common global scopes
        if ($ScopeName -eq 'Datacenters') {
            $entity = Get-Folder -Name 'Datacenters' -ErrorAction Stop
        }
        elseif ($ScopeName -eq 'Root') {
            # Root folder is parent of Datacenters
            $entity = (Get-Folder -Name 'Datacenters' -ErrorAction Stop).Parent
        }
        else {
            # Try to resolve by name generically
            $entity = Get-Inventory -Name $ScopeName -ErrorAction Stop
        }
        New-VIPermission -Entity $entity -Principal $UserPrincipal -Role $RoleName -Propagate:$true -ErrorAction Stop | Out-Null
        return $true
    }
    catch {
        Write-Color "Permission fallback failed: $($_.Exception.Message)" 'Red'
        return $false
    }
}

try {
    if (-not (Test-Path -Path $CsvPath)) { throw "CSV file not found: $CsvPath" }
    if ($InstallModules) { Install-RequiredModules }

    if (-not $Credential) {
        Write-Color "Prompting for vCenter/SSO credential..." 'Yellow'
        $Credential = Get-Credential -Message "Enter vCenter/SSO admin credential (e.g., administrator@$SsoDomain)"
    }

    Write-Color "Connecting to vCenter and SSO..." 'Yellow'
    Connect-VCenterServerSession -Server $vCenterServer -Cred $Credential
    Connect-SsoAdminSession -Server $vCenterServer -AdminCred $Credential

    $rows = Get-CsvRowsNoHeader -Path $CsvPath
    if (-not $rows) { throw "No rows parsed from CSV: $CsvPath" }

    $results = @()
    foreach ($row in $rows) {
        $user = $row.UserName
        $email = $row.Email
        $group = $row.Group
        $first = $row.FirstName
        $last = $row.LastName

        Write-Color "Processing user: $user (Group: $group)" 'Cyan'

        # Check if SSO person user exists
        $existing = $null
        try { $existing = Get-SsoPersonUserCompat -User $user -Domain $SsoDomain } catch { $existing = $null }
        $ssoUser = $null

        if ($existing) {
            Write-Color "User exists: $user@$SsoDomain - skipping creation" 'Yellow'
            $passwordPlain = $null
            $ssoUser = $existing
        }
        else {
            $passwordPlain = New-StrongPassword -Length 20
            if ($WhatIf) {
                Write-Color "WhatIf: Would create SSO user $user@$SsoDomain" 'Yellow'
            }
            else {
                New-SsoPersonUserCompat -User $user -Domain $SsoDomain -First $first -Last $last -Email $email -Password $passwordPlain | Out-Null
                Write-Color "Created SSO user: $user@$SsoDomain" 'Green'
                try { $ssoUser = Get-SsoPersonUserCompat -User $user -Domain $SsoDomain } catch { $ssoUser = $null }
            }
        }

        # Ensure group exists (local SSO group)
        $groupObj = $null
        try { $groupObj = Get-SsoGroupCompat -Group $group -Domain $SsoDomain } catch { $groupObj = $null }
        if (-not $groupObj -and -not $WhatIf) {
            try {
                New-SsoGroupCompat -Group $group -Domain $SsoDomain -Description "Auto-created by script" | Out-Null
                $groupObj = Get-SsoGroupCompat -Group $group -Domain $SsoDomain
                Write-Color "Created SSO group: $group@$SsoDomain" 'Green'
            }
            catch {
                Write-Color "Failed to create group '$group' in domain '$SsoDomain': $($_.Exception.Message)" 'Red'
            }
        }

        # Add user to group
        if ($groupObj -or $WhatIf) {
            if ($WhatIf) {
                Write-Color "WhatIf: Would add $user to group $group@$SsoDomain" 'Yellow'
            }
            else {
                try {
                    if ($ssoUser) {
                        $already = $false
                        try { $already = Test-UserInSsoGroupCompat -GroupObj $groupObj -UserObj $ssoUser -Domain $SsoDomain } catch { $already = $false }
                        if ($already) {
                            Write-Color "User $user is already a member of $group@$SsoDomain - skipping" 'Yellow'
                        }
                        else {
                            $added = Add-SsoGroupMemberCompat -GroupObj $groupObj -UserObj $ssoUser -Domain $SsoDomain
                            if ($added) {
                                Write-Color "Added $user to group $group@$SsoDomain" 'Green'
                            }
                            elseif ($UsePermissionFallback) {
                                $principal = "$($ssoUser.Name)@$($ssoUser.Domain)"
                                Write-Color "Group add not available. Applying permission fallback: Role=$FallbackRole, Scope=$FallbackScope" 'Yellow'
                                if (Grant-VIPermissionFallback -UserPrincipal $principal -RoleName $FallbackRole -ScopeName $FallbackScope) {
                                    Write-Color "Granted role '$FallbackRole' to $principal at '$FallbackScope'" 'Green'
                                }
                                else {
                                    throw "Fallback permission grant failed"
                                }
                            }
                            else {
                                throw "Add-SsoGroupMember cmdlet not available"
                            }
                        }
                    }
                }
                catch {
                    Write-Color "Failed to add user to group '$group': $($_.Exception.Message)" 'Red'
                }
            }
        }

        if ($passwordPlain) {
            $results += [PSCustomObject]@{
                Username      = $user
                UserPrincipal = "$user@$SsoDomain"
                Password      = $passwordPlain
                vCenterUrl    = $vCenterServer
                Email         = $email
            }
        }
    }

    # Write password mapping (append new users only; do not modify existing rows)
    if ($results.Count -gt 0) {
        if (Test-Path $OutputPasswordFile) {
            Write-Color "Appending new users to: $OutputPasswordFile" 'Yellow'
            $existingRows = Import-Csv -Path $OutputPasswordFile
            $hasPrincipal = ($existingRows.Count -gt 0 -and ($existingRows[0].PSObject.Properties.Name -contains 'UserPrincipal'))
            $hasEmail = ($existingRows.Count -gt 0 -and ($existingRows[0].PSObject.Properties.Name -contains 'Email'))
            if (-not $hasPrincipal -or -not $hasEmail) {
                Write-Color "Upgrading output schema to include missing columns" 'Yellow'
                $usernameToEmail = @{}
                foreach ($r in $rows) { $usernameToEmail[$r.UserName.ToLower()] = $r.Email }
                $migrated = @()
                foreach ($r in $existingRows) {
                    if (-not ($r.PSObject.Properties.Name -contains 'UserPrincipal')) {
                        $r | Add-Member -NotePropertyName UserPrincipal -NotePropertyValue ("$($r.Username)@$SsoDomain")
                    }
                    if (-not ($r.PSObject.Properties.Name -contains 'Email')) {
                        $emailVal = ''
                        $key = $r.Username
                        if ($key) { $keyLower = $key.ToLower(); if ($usernameToEmail.ContainsKey($keyLower)) { $emailVal = $usernameToEmail[$keyLower] } }
                        $r | Add-Member -NotePropertyName Email -NotePropertyValue $emailVal
                    }
                    $migrated += $r
                }
                $migrated | Select-Object Username, UserPrincipal, Password, vCenterUrl, Email | Export-Csv -Path $OutputPasswordFile -NoTypeInformation -Force
                $existingRows = Import-Csv -Path $OutputPasswordFile
            }
            $existingUsers = @{}
            foreach ($row in $existingRows) { $existingUsers[$row.Username.ToLower()] = $true }
            $toAppend = $results | Where-Object { -not $existingUsers.ContainsKey($_.Username.ToLower()) }
            if ($toAppend.Count -gt 0) {
                $toAppend | Select-Object Username, UserPrincipal, Password, vCenterUrl, Email | Export-Csv -Path $OutputPasswordFile -NoTypeInformation -Append
                Write-Color "Appended $($toAppend.Count) new user(s)" 'Green'
            }
            else {
                Write-Color "No new users to append" 'Yellow'
            }
        }
        else {
            Write-Color "Creating output: $OutputPasswordFile" 'Yellow'
            $results | Select-Object Username, UserPrincipal, Password, vCenterUrl, Email | Export-Csv -Path $OutputPasswordFile -NoTypeInformation -Force
            Write-Color "Wrote $($results.Count) user(s)" 'Green'
        }
    }
    else {
        Write-Color "No newly created users; output not modified" 'Yellow'
    }

}
catch {
    Write-Error $_.Exception.Message
    exit 1
}
finally {
    try { if ($Global:DefaultSsoAdminServers) { Disconnect-SsoAdminServer -Server $Global:DefaultSsoAdminServers[0] -ErrorAction SilentlyContinue } } catch {}
    try { if ($Global:DefaultVIServers) { Disconnect-VIServer -Server $Global:DefaultVIServers -Confirm:$false -ErrorAction SilentlyContinue } } catch {}
}


