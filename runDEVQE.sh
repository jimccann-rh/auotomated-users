#!/bin/bash

bw login
# sudo dnf install https://github.com/PowerShell/PowerShell/releases/download/v7.5.4/powershell-7.5.4-1.rh.x86_64.rpm
# pwsh -File New-vCenterUsersFromCsv.ps1  --InstallModules true

pwsh -File New-vCenterUsersFromCsv.ps1 -CsvPath ./usernames-devqe.csv -vCenterServer 'vcenter.vsphere.com' -SsoDomain 'vsphere.com' -OutputPasswordFile ./new-users-passwords-devqe.csv

echo "log in bitwarden? * bw login * * bw unlock * * export BW_SESSION= * "
export BW_SESSION=$(bw unlock --raw)
#export BW_SESSION=$(bw login emailaddress@at.com --raw --code 000000)

pwsh -File Create-BWSendsFromCsv.ps1 -CsvPath ./new-users-passwords-devqe.csv -OutputCsv ./bw-send-links-devqe.csv

export SLACK_BOT_TOKEN="xoxp-..."
pwsh -File ./send-bw-links-to-slack.ps1 -CsvPath ./bw-send-links-devqe.csv


rm ./new-users-passwords-devqe.csv
rm ./bw-send-links-devqe.csv

export TWINGATE_API_KEY="qZ7..."
#pwsh -File twingate.ps1 --CsvPath ./usernames-devqe.csv --ListGroups
pwsh -File twingate.ps1 --CsvPath ./usernames-devqe.csv

echo "done"

