## Automated Users: Script Reference and Usage

This repository contains scripts to automate provisioning and onboarding tasks for new users across vCenter, Bitwarden, Slack, and Twingate.

### Overview
- **New-vCenterUsersFromCsv.ps1**: Creates SSO users in vCenter, ensures group membership, and outputs credentials.
- **Create-BWSendsFromCsv.ps1**: Generates Bitwarden Sends for credentials and produces shareable access links.
- **send-bw-links-to-slack.ps1**: Direct-messages users on Slack with their Bitwarden Send link and vCenter URL.
- **twingate.ps1**: Creates Twingate users and optionally adds them to a Twingate group.
- **Add-UsersToSslVpn.ps1**: Enables IBM Classic VPN for users and grants access to subnets from `vpn-subnets.yml`.
- **Pending-IbmAccountUsers.ps1**: Lists IBM Cloud account users in a pending state; can remove those pending >60 days.
- **runDEVQE.sh**: Orchestrates the end-to-end flow for the DEVQE environment.
- **usernames-devqe.csv**: Example input CSV of users for automation.

---

### New-vCenterUsersFromCsv.ps1
Creates vCenter SSO users from a CSV, ensures a local SSO group exists, and adds users to that group. For new users, it generates strong passwords and writes an output CSV of credentials and metadata.

Requirements:
- PowerShell 7+ (pwsh)
- VMware.PowerCLI module
- VMware.vSphere.SsoAdmin module (see comments in script for install guidance)

Inputs:
- CSV without headers where columns are: `UserName, Email, Group, FirstName, LastName` (extra columns are ignored).

Key parameters:
- `-CsvPath <path>`: Input CSV (no header expected).
- `-vCenterServer <fqdn>`: vCenter hostname.
- `-Credential <PSCredential>`: SSO admin credential; prompts if not supplied.
- `-SsoDomain <domain>`: SSO domain (default `vsphere.local`).
- `-OutputPasswordFile <path>`: Output CSV with created users and passwords.
- `-InstallModules`: Install required PowerShell modules if missing.
- `-WhatIf`: Dry run; does not create users.
- `-UsePermissionFallback`, `-FallbackRole`, `-FallbackScope`: Grant a vSphere permission if group membership cmdlets are unavailable.

Output CSV columns:
- `Username, UserPrincipal, Password, vCenterUrl, Email`

Example:
```bash
pwsh -File New-vCenterUsersFromCsv.ps1 \
  -CsvPath ./usernames-devqe.csv \
  -vCenterServer 'vcenter.vsphere.com' \
  -SsoDomain 'vsphere.com' \
  -OutputPasswordFile ./new-users-passwords-devqe.csv
```

---

### Create-BWSendsFromCsv.ps1
Creates Bitwarden Send links (one-time access) for each row in an input credentials CSV and writes the Send access URLs to an output CSV.

Requirements:
- Bitwarden CLI (`bw`) installed and available in PATH
- Unlocked Bitwarden session (`BW_SESSION` exported)

Inputs:
- CSV with headers: `Username, UserPrincipal, Password, vCenterUrl, Email` (e.g., the output of `New-vCenterUsersFromCsv.ps1`).

Key parameters:
- `-CsvPath <path>`: Input credentials CSV (default `new-users-passwords.csv`).
- `-OutputCsv <path>`: Output CSV (default `bw-send-links.csv`).

Output CSV columns:
- `Username, UserPrincipal, Email, vCenterUrl, AccessUrl`

Example:
```bash
export BW_SESSION=$(bw unlock --raw)
pwsh -File Create-BWSendsFromCsv.ps1 \
  -CsvPath ./new-users-passwords-devqe.csv \
  -OutputCsv ./bw-send-links-devqe.csv
```

---

### send-bw-links-to-slack.ps1
Sends a Slack DM to each user with their vCenter URL and Bitwarden Send link. Attempts to message the user directly, falls back to opening a DM, and optionally posts to a fallback channel.

Requirements:
- Slack API token with necessary scopes, supplied via `-SlackToken` or `SLACK_TOKEN`/`SLACK_BOT_TOKEN` env vars.

Inputs:
- CSV with headers: `Username, UserPrincipal, Email, vCenterUrl, AccessUrl` (e.g., from `Create-BWSendsFromCsv.ps1`).

Key parameters:
- `-CsvPath <path>`: Input CSV of Send links (default `$PSScriptRoot/bw-send-links.csv`).
- `-SlackToken <token>`: Slack API token; falls back to `SLACK_TOKEN` then `SLACK_BOT_TOKEN` env vars.
- `-FallbackChannelId <id>`: Channel to post mention + message if DMs cannot be opened.
- `-WhatIf`: Print what would be sent without sending.

Example:
```bash
export SLACK_BOT_TOKEN="xoxb-..." # or set SLACK_TOKEN
pwsh -File send-bw-links-to-slack.ps1 \
  -CsvPath ./bw-send-links-devqe.csv \
  -FallbackChannelId C0123456789
```

---

### twingate.ps1
Creates Twingate users by email and optionally adds them to a named Twingate group. Can also list existing groups. The tenant subdomain is set in the script (`$subdomain = "acme"`).

Requirements:
- `TWINGATE_API_KEY` environment variable set (Admin API key)

Inputs:
- CSV can be headerless or have `Email` (and optionally `Group`/`GroupName`).
  - If headerless, column 2 is treated as Email, column 6 as Group.

Key parameters:
- `-CsvPath <path>`: Input users CSV.
- `-ListGroups`: List groups and exit.

Examples:
```bash
# List groups
export TWINGATE_API_KEY="..."
pwsh -File twingate.ps1 -ListGroups

# Create/invite users and add to groups by name
export TWINGATE_API_KEY="..."
pwsh -File twingate.ps1 -CsvPath ./usernames-devqe.csv
```

---

### Add-UsersToSslVpn.ps1
Enables IBM Classic Infrastructure SSL VPN for each user in a CSV and assigns access to the subnets listed in `vpn-subnets.yml`. If an email does not yet have an IBM Cloud account, the script sends an invite and skips VPN setup until accepted.

Requirements:
- IBM Cloud CLI (`ibmcloud`) installed and logged in
- `vpn-subnets.yml` containing a `subnetid:` list (supports `ConvertFrom-Yaml` if available)

Inputs:
- Headerless CSV with columns: `Username, Email, Group, FirstName, LastName, AccountName, Ticket`

Key parameters:
- `-CsvPath <path>`: Input CSV (default `./usernames-cee.csv`).
- `-SubnetsYamlPath <path>`: YAML file with `subnetid` list (default `./vpn-subnets.yml`).

Example:
```bash
pwsh -File Add-UsersToSslVpn.ps1 \
  -CsvPath ./usernames-cee.csv \
  -SubnetsYamlPath ./vpn-subnets.yml
```

---

### Pending-IbmAccountUsers.ps1
Summarizes IBM Cloud account users who are still in a pending/invited state, flags those pending more than 60 days, and can optionally remove them.

Requirements:
- IBM Cloud CLI (`ibmcloud`) installed and logged in

Key parameters:
- `-RemoveUsers` (or `--RemoveUsers`): Remove users flagged as candidates (>60 days pending).

Examples:
```bash
# List pending users and removal candidates (no changes)
pwsh -File Pending-IbmAccountUsers.ps1

# Remove users pending >60 days
pwsh -File Pending-IbmAccountUsers.ps1 -RemoveUsers
```

---

### runDEVQE.sh
Orchestrates the full DEVQE flow: create vCenter users, generate Bitwarden Sends, DM users in Slack, and create Twingate users.

What it does:
1. `bw login` and unlocks Bitwarden (`BW_SESSION`).
2. Runs `New-vCenterUsersFromCsv.ps1` with `./usernames-devqe.csv`, outputs `./new-users-passwords-devqe.csv`.
3. Runs `Create-BWSendsFromCsv.ps1` to create Sends, outputs `./bw-send-links-devqe.csv`.
4. Sends Slack DMs via `send-bw-links-to-slack.ps1` (requires Slack token env var).
5. Cleans intermediate CSVs.
6. Runs `twingate.ps1` (requires `TWINGATE_API_KEY`).

Before running, set/replace environment variables and placeholders in the script:
- `BW_SESSION` (via `bw unlock --raw`), Slack token (`SLACK_TOKEN` or `SLACK_BOT_TOKEN`), `TWINGATE_API_KEY`.

Example:
```bash
bash ./runDEVQE.sh
```

---

### usernames-devqe.csv
Example CSV row format used by the automation. Headerless example:
```
username,email,group,first,last,envOrTeam,trackingId
kerboid,emailaddress@at.com,DEVQE,First,Last,C-devqe,tid

```

Notes:
- `New-vCenterUsersFromCsv.ps1` uses the first five columns.
- `twingate.ps1` (headerless mode) expects email in column 2 and group in column 6.

---

### Typical end-to-end flow
1. Create vCenter users and produce `new-users-passwords-*.csv` with credentials.
2. Generate Bitwarden Sends and produce `bw-send-links-*.csv` with access URLs.
3. DM users their access URLs on Slack.
4. Create/invite Twingate users and add to group.

Environment variables commonly needed:
- `BW_SESSION` for Bitwarden CLI
- `SLACK_TOKEN` or `SLACK_BOT_TOKEN` for Slack messaging
- `TWINGATE_API_KEY` for Twingate GraphQL API
- `IBMCLOUD_API_KEY` for Adding user to SSL VPN

