<#
.description
Provision the 'Freyja' boxes, which I use for DLP
#>

$ErrorActionPreference = "Stop"

Invoke-WebRequest -UseBasicParsing https://raw.githubusercontent.com/mrled/dhd/master/opt/powershell/magic.ps1 | Invoke-Expression
