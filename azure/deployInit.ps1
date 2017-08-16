<#
.synopsis
Configure the WinTrialLab cloud builder VM
#>
[CmdletBinding()] Param(
    [string] $eventLogName = "WinTrialLab",
    [string] $eventLogSource = "WinTrialLab-azure-deployInit.ps1"
)

<#
.synopsis
Wrapper that writes to the event log but also to the screen
#>
function Write-EventLogWrapper {
    [cmdletbinding()] param(
        [parameter(mandatory=$true)] [String] $message,
        [int] $eventId = 0,
        [ValidateSet("Error",'Warning','Information','SuccessAudit','FailureAudit')] $entryType = "Information"
    )
    if (-not (get-eventlog -logname * |? { $_.Log -eq $eventLogName })) {
        New-EventLog -Source $eventLogSource -LogName $eventLogName
    }
    $messagePlus = "$message`r`n`r`nScript: $($script:ScriptPath)`r`nUser: ${env:USERDOMAIN}\${env:USERNAME}"
    if ($messagePlus.length -gt 32766) {
        # Because Write-EventLog will die otherwise
        $messagePlus = $messagePlus.SubString(0,32766)
    }
    Write-Host -ForegroundColor Magenta "====Writing to $eventLogName event log===="
    # The event log tracks the date, but if viewing the output on the console, then this is helpful
    Write-Host -ForegroundColor DarkGray (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
    write-host -ForegroundColor DarkGray "$messagePlus`r`n"
    Write-EventLog -LogName $eventLogName -Source $eventLogSource -EventID $eventId -EntryType $entryType -Message $MessagePlus
}

<#
.description
Test whether the current Window account has administrator privileges
#>
function Test-AdministratorRole {
    $me = [Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()
    $amAdmin = $me.IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator")
    Write-EventLogWrapper -message "Current user has admin privileges: '$(amAdmin)'"
    return $amAdmin
}

<#
.description
Get the PATH environment variables from Machine, User, and Process locations, and update the current Powershell process's PATH variable to contain all values from each of them. Call it after updating the Machine or User PATH value (which may happen automatically during say installing software) so you don't have to launch a new Powershell process to get them.
#>
function Update-EnvironmentPath {
    [CmdletBinding()] Param()
    $oldPath = $env:PATH
    $machinePath = [Environment]::GetEnvironmentVariable("PATH", "Machine") -split ";"
    $userPath = [Environment]::GetEnvironmentVariable("PATH", "User") -split ";"
    $processPath = [Environment]::GetEnvironmentVariable("PATH", "Process") -split ";"
    $env:PATH = ($machinePath + $userPath + $processPath | Select-Object -Unique) -join ";"
    Write-EventLogWrapper -message "Updated PATH environment variable`r`n`r`nNew value: $($env:PATH -replace ';', "`r`n")`r`n`r`nOld value: $($oldPath -replace ';', "`r`n")"
}

<#
.description
Wrap calls to external executables so that we can update the %PATH% first
#>
function Invoke-PathExecutable {
    [CmdletBinding()] Param(
        [Parameter(Mandatory=$True)] [String] $commandLine
    )
    Update-EnvironmentPath
    try {
        Invoke-Expression $commandLine
        if ($LASTEXITCODE -ne 0) {
            throw "Command line '$commandLine' exited with code '$LASTEXITCODE'"
        } else {
            Write-EventLogWrapper -message "Command line '$commandLine' exited successfully with code '$LASTEXITCODE'"
        }
    } catch {
        Write-EventLogWrapper -message "When attempting to run command '$commandLine', got error '$_'"
        throw $_
    }
}

<#
.description
Set the execution policy to unrestricted for both 32 and 64 bit processes
#>
function Set-ExecPolUnrestricted {
    [CmdletBinding()] Param()
    $sepScope = if (Test-AdministratorRole) { "LocalMachine" } else { "CurrentUser" }
    Set-ExecutionPolicy Unrestricted -Scope $sepScope -Force
    if ([Environment]::Is64BitProcess) {
        Start-Job -ScriptBlock { Set-ExecutionPolicy Unrestricted -Scope $sepScpope -Force } -RunAs32
    }
    Write-EventLogWrapper -message "ExecutionPolicy now set to restricted for scope '$sepScope'"
}

function Install-Chocolatey {
    Invoke-WebRequest https://chocolatey.org/install.ps1 -UseBasicParsing | Invoke-Expression
    Update-EnvironmentPath
    $chocoPath = Get-Command choco.exe | Select-Oject -ExpandProperty Source
    Invoke-PathExecutable "choco.exe feature enable --name=allowGlobalConfirmation --yes"
    Write-EventLogWrapper -message "Chocolatey is now installed to '$chocoPath'"
}

function Install-ChocolateyPackage {
    [CmdletBinding()] Param(
        [Parameter(Mandatory=$true)] [String[]] $packageName
    )
    Invoke-PathExecutable "choco.exe install $packageName"
}

Write-EventLogWrapper -message "Initializing the WinTrialLab cloud builder deployment..."
Set-ExecPolUnrestricted
Install-Chocolatey
Install-ChocolateyPackage -packageName @('packer')
