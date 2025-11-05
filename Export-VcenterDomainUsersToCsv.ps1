param(
    [Parameter(Mandatory = $true)]
    [string]$vCenterServer,

    [Parameter(Mandatory = $true)]
    [string]$Domain,

    [Parameter(Mandatory = $false)]
    [PSCredential]$Credential,

    [Parameter(Mandatory = $false)]
    [string]$OutputCsv = "./Exported_vCenterUsers_${Domain}_$(Get-Date -Format 'yyyyMMdd_HHmmss').csv",

    [Parameter(Mandatory = $false)]
    [switch]$InstallModules = $false
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
            Write-Color "VMware.vSphere.SsoAdmin not available in PSGallery. Install from: https://github.com/vmware/PowerCLI-Example-Scripts/tree/master/Modules/VMware.vSphere.SsoAdmin" 'Red'
            throw
        }
    }
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
            Connect-SsoAdminServer -Server $Server -Credential $AdminCred -ErrorAction Stop | Out-Null
        }
        catch {
            $user = $AdminCred.UserName
            $pass = $AdminCred.GetNetworkCredential().Password
            Connect-SsoAdminServer -Server $Server -User $user -Password $pass -ErrorAction Stop | Out-Null
        }
    }
}

try {
    if ($InstallModules) { Install-RequiredModules }

    if (-not $Credential) {
        Write-Color "Prompting for vCenter/SSO credential..." 'Yellow'
        $Credential = Get-Credential -Message "Enter vCenter/SSO credential (e.g., administrator@$Domain)"
    }

    Write-Color "Connecting to vCenter and SSO..." 'Yellow'
    Connect-VCenterServerSession -Server $vCenterServer -Cred $Credential
    Connect-SsoAdminSession -Server $vCenterServer -AdminCred $Credential

    Write-Color "Resolving SSO domain: $Domain" 'Yellow'
    $domainObj = $null
    try { $domainObj = Get-SsoDomain -Name $Domain -ErrorAction Stop } catch { $domainObj = $null }
    if (-not $domainObj) {
        # Try list and match
        try { $domainObj = Get-SsoDomain | Where-Object { $_.Name -eq $Domain } } catch { $domainObj = $null }
    }
    if (-not $domainObj) { Write-Color "Warning: Could not resolve domain object for '$Domain'. Will try using the string domain." 'Yellow' }

    Write-Color "Retrieving SSO users for domain '$Domain'..." 'Yellow'
    $users = $null
    $getCmd = Get-Command -Name Get-SsoPersonUser -ErrorAction Stop
    try {
        if ($domainObj) { $users = Get-SsoPersonUser -Domain $domainObj -ErrorAction Stop }
        else { $users = Get-SsoPersonUser -Domain $Domain -ErrorAction Stop }
    }
    catch {
        # Some module versions might use -IdentitySource or require alternate parameter shapes; make a best-effort second try
        try { $users = Get-SsoPersonUser -ErrorAction Stop } catch { throw "Failed to retrieve SSO users: $($_.Exception.Message)" }
    }

    if (-not $users) { throw "No users returned for domain '$Domain'" }

    $exportRows = $users | ForEach-Object {
        $effectiveDomain = if ($_.PSObject.Properties.Name -contains 'Domain' -and $_.Domain) { $_.Domain } else { $Domain }
        $idValue = if ($_.PSObject.Properties.Name -contains 'Id' -and $_.Id) { $_.Id } else { "$( $_.Name )@$effectiveDomain" }
        [PSCustomObject]@{
            Name         = $_.Name
            Domain       = $effectiveDomain
            Id           = $idValue
            FirstName    = if ($_.PSObject.Properties.Name -contains 'FirstName') { $_.FirstName } else { $null }
            LastName     = if ($_.PSObject.Properties.Name -contains 'LastName') { $_.LastName } else { $null }
            EmailAddress = if ($_.PSObject.Properties.Name -contains 'EmailAddress') { $_.EmailAddress } else { $null }
            Disabled     = if ($_.PSObject.Properties.Name -contains 'Disabled') { $_.Disabled } else { $null }
            Locked       = if ($_.PSObject.Properties.Name -contains 'Locked') { $_.Locked } else { $null }
        }
    }

    Write-Color "Exporting $($exportRows.Count) user(s) to: $OutputCsv" 'Yellow'
    $exportRows | Export-Csv -Path $OutputCsv -NoTypeInformation -Force
    Write-Color "Export complete." 'Green'
}
catch {
    Write-Error $_.Exception.Message
    exit 1
}
finally {
    try { if ($Global:DefaultSsoAdminServers) { Disconnect-SsoAdminServer -Server $Global:DefaultSsoAdminServers[0] -ErrorAction SilentlyContinue } } catch {}
    try { if ($Global:DefaultVIServers) { Disconnect-VIServer -Server $Global:DefaultVIServers -Confirm:$false -ErrorAction SilentlyContinue } } catch {}
}


