<#
.synopsis
Configure the WinTrialLab cloud builder VM
.parameter winTrialLabDir
The location of an already existing and checked out copy of the WinTrialLab repo
.parameter eventLogName
The name of the event log to use. Creates if nonexistent.
.parameter eventLogSource
The name to use for the "source" of the event log entries we create. Arbitrary string.
.parameter magicUrl
The URL for the "magic" script. This script is run and immediately executed. Useful for arbitrary customization.
#>
[CmdletBinding()] Param(
    [Parameter(Mandatory)] [string] $wtlRepoUri,
    [Parameter(Mandatory)] [string] $wtlRepoBranch,
    [string] $wtlCheckoutDir = "${env:SystemDrive}\WinTrialLab",

    [string] $chocoInstallDir = (Join-Path -Path ${env:ProgramData} -ChildPath "Chocolatey"),

    [string] $caryatidInstallDir = (Join-Path -Path "${env:AppData}\packer.d" -ChildPath 'plugins'),
    [string] $caryatidPluginFilename = 'packer-post-processor-caryatid.exe',
    [string] $caryatidInstallPath = (Join-Path -Path $caryatidInstallDir -ChildPath $caryatidPluginFilename),
    [string] $caryatidGitHubLatestReleaseEndpoint = 'https://api.github.com/repos/mrled/caryatid/releases/latest',
    [string] $caryatidAssetRegex = '^caryatid_windows_amd64_.*\.zip$',

    [string] $eventLogName = "WinTrialLab",
    [string] $eventLogSource = "WinTrialLab-azure-deployInit.ps1"
)

<#
Development notes:

Do *not* use $PSScriptRoot to reference other files in the repository. This script is downloaded and run to clone the repo. Once the repo is cloned, reference files from $wtlCheckoutDir
#>

$ErrorActionPreference = "Stop"

## Helper functions

<#
.synopsis
Wrapper that writes to the event log but also to the screen
#>
function Write-EventLogWrapper {
    [cmdletbinding()] param(
        [Parameter(Mandatory=$true, ValueFromPipeline=$true)] [String] $message,
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
Test whether the current Windows account has administrator privileges
#>
function Test-AdministratorRole {
    $me = [Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()
    $amAdmin = $me.IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator")
    Write-EventLogWrapper -message "Current user has admin privileges: '$($amAdmin)'"
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
Wrap calls to external executables so that we can update the %PATH% first and check the exit code afterwards.
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

function New-TemporaryDirectory {
    $newTempDirPath = ""
    do {
        $newTempDirPath = Join-Path $env:TEMP (New-Guid | Select-Object -ExpandProperty Guid)
    } while (Test-Path -Path $newTempDirPath)
    New-Item -ItemType Directory -Path $newTempDirPath
}

## DSC Configuration

[DSCLocalConfigurationManager()]
Configuration DSConfigure-LocalConfigurationManager {
    param(
        [string[]] $computerName = "localhost"
    )
    Node $computerName {
        Settings {
            RebootNodeIfNeeded = $true
            ActionAfterReboot = 'ContinueConfiguration'
        }
    }
}

Configuration DSConfigure-WinTrialBuilder {
    param(
        [string[]] $computerName = $env:COMPUTERNAME
    )

    Import-DscResource -ModuleName PSDesiredStateConfiguration
    Import-DscResource -ModuleName xHyper-V

    # TODO: Do I have to chain all these with DependsOn? Can I have an array in DependsOn or anything?

    Node $computerName {

        WindowsFeature "Hyper-V" {
            Ensure = "Present"
            Name = "Hyper-V"
        }
        WindowsFeature "Hyper-V-Tools" {
            Ensure = "Present"
            Name = "Hyper-V-Tools"
            DependsOn = "[WindowsFeature]Hyper-V"
        }
        WindowsFeature "Hyper-V-Powershell" {
            Ensure = "Present"
            Name = "Hyper-V-Powershell"
            DependsOn = "[WindowsFeature]Hyper-V"
        }
        # This may not be necessary?
        xVMHost "VmHostConfiguration" {
            IsSingleInstance = 'Yes'
            DependsOn = "[WindowsFeature]Hyper-V"
        }

        cChocoInstaller "InstallChoco" {
            InstallDir = $chocoInstallDir
        }
        cChocoPackageInstaller "ChocoInstallGit" {
            Name      = 'git'
            Ensure    = 'Present'
            DependsOn = '[cChocoInstaller]InstallChoco'
        }
        cChocoPackageInstaller "ChocoInstallPacker" {
            Name      = 'packer'
            Ensure    = 'Present'
            DependsOn = '[cChocoPackageInstaller]ChocoInstallGit'
        }
        Script "CheckoutWinTrialLab" {
            GetScript = {}
            TestScript = {
                Test-Path -Path "$wtlCheckoutDir\.git"
            }
            SetScript = {
                Invoke-PathExecutable "git.exe clone '$wtlRepoUri' --branch '$wtlRepoBranch' '$wtlCheckoutDir'"
            }
            DependsOn = "[cChocoPackageInstaller]ChocoInstallPacker"
        }

        Script "InstallCaryatidPackerPlugin" {
            GetScript = {}
            TestScript = {
                Test-Path -Path $caryatidInstallPath
            }
            SetScript = {
                $asset = Invoke-RestMethod -Uri $caryatidGitHubLatestReleaseEndpoint | Select-Object -ExpandProperty assets | Where-Object -Property "name" -match $caryatidAssetRegex
                $filename = $asset.browser_download_url -split '/' | Select-Object -Last 1
                $downloadDir = New-TemporaryDirectory | Select-Object -ExpandProperty FullName
                $downloadPath = Join-Path -Path $downloadDir -ChildPath $filename
                New-Item -Type Directory -Force -Path $caryatidInstallDir
                Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $downloadPath
                Expand-Archive -Path $downloadPath -DestinationPath $downloadDir
                $caryatidExe = Get-ChildItem -Recurse -File -Path $downloadDir -Include
                Move-Item -Path $caryatidExe -Destination $caryatidInstallPath
            }
            DependsOn = "[Script]CheckoutWinTrialLab"
        }

        # Script "RunPacker" {
        #     GetScript = {}
        #     TestScript = {}
        #     SetScript = {}
        # }
    }
}

if ($MyInvocation.InvocationName -ne '.') {
    Write-EventLogWrapper -message "Initializing the WinTrialLab cloud builder deployment..."
    Set-ExecutionPolicy -ExecutionPolicy Unrestricted -Scope Machine

    Install-PackageProvider -Name NuGet -Force
    Set-PSRepository -Name PSGallery -InstallationPolicy Trusted
    Install-Module -Name xHyper-V, cChoco

    # Initialize DSC configuration
    $dscWorkDirBase = New-TemporaryDirectory | Select-Object -ExpandProperty FullName
    Write-EventLogWrapper -message "Using '$dscWorkDirBase' for DSC configurations"

    # Configure the Local Configuration Manager first
    $lcmWorkDir = Join-Path $dscWorkDirBase "LocalConfigurationManager"
    DSConfigure-LocalConfigurationManager -OutputPath $lcmWorkDir | Write-EventLogWrapper
    Set-DscLocalConfigurationManager -Path $lcmWorkDir | Write-EventLogWrapper

    # Now run the WinTrialLab DSC configuration
    $wtlWorkDir = Join-Path $dscWorkDirBase "WinTrialLab"
    DSConfigure-WinTrialBuilder -OutputPath $wtlWorkDir | Write-EventLogWrapper
    Start-DscConfiguration -Path $wtlWorkDir | Write-EventLogWrapper
}
