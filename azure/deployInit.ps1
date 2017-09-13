<#
.synopsis
Configure the WinTrialLab cloud builder VM
.description
Perform deployment work on the system, including installing Powershell DSC prerequisite modules, creating the DSC MOF files, and actually running the configuration.
.parameter wtlRepoZipUri
The URI to the wintriallab repository zipfile generated by GitHub.
Note that we rely on GitHub's behavior of creating a zipfile with a single directory in the root, and all files in the repo added under that directory, but that we do not have to know the name of the directory beforehand.
.parameter runLocal
If *not* passed, assume that this script has been downloaded alone; download the WTL zip file and extract it before using resources found in it to continue.
If passed, assume that this script is running in a checked-out copy WTL repo, and use $PSScriptRoot to find other resources. Also, run DSC configurations with -Force (rationale: we are probably trying things, having them fail, and trying again; without -Force, DSC will not attempt a new configuration after a failure.
.parameter packerUserName
The name for the Packer user. User must already exist.
.parameter packerUserPassword
The password for the Packer user.
.parameter eventLogName
The name of the event log to use during initial setup. Created if nonexistent. Note that DSC logs are sent to the normal event log, not the one named here.
.parameter eventLogSource
Arbitrary string to use as a name to use for the "source" of the event log entries we create.
.parameter installDebuggingTools
Install tools that are helpful for troubleshooting and debugging my DSC configuration on the VM.
#>
[CmdletBinding(DefaultParameterSetName="InitializeVm")] Param(
    [Parameter(ParameterSetName="InitializeVm", Mandatory)] [string] $wtlRepoZipUri,
    [Parameter(ParameterSetName="RunLocal", Mandatory)] [switch] $runLocal,
    [Parameter(Mandatory)] [string] $packerUserName,
    [Parameter(Mandatory)] [string] $packerUserPassword,
    [string] $eventLogName = "WinTrialLab",
    [string] $eventLogSource = "WinTrialLab-azure-deployInit.ps1",
    [switch] $installDebuggingTools
)

<#
Development notes:

Do *not* use $PSScriptRoot to reference other files in the repository. This script is downloaded and run to clone the repo. Once the repo is cloned, reference files from $wtlCheckoutDir

Note that the DSC `Configuration` blocks can *not* be part of this file, even though it's dot-sourced and it looks like it could be added. This is because this script installs DSC resources. The DSC configurations load them via `Import-DscResource`, which is *not* a cmdlet, but is a dynamic keyword. Because it's a keyword, it isn't encapsulated in the `Configuration` and run when the configuration is invoked, but is actually run as soon as the script executes - and in this case, since this script is installing those DSC resources, that means it will run before the resources are installed, and therefore fail. Note also that even encapsulating the `Configuration` block in a scriptblock that is executed later will still result in an error. For these reasons, the DSC configuration itself must exist in a separate file which is called from this deployment script.

We go to some effort to make sure that this script doesn't have to know much about the wintriallab repository. In fact, it doesn't even need git installed, since we can just download the zipfile from GitHub. That said, we do rely on the structure of the zipfile that GitHub generates, as mentioned above.
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

function New-TemporaryDirectory {
    do {
        $newTempDirPath = Join-Path $env:TEMP (New-Guid | Select-Object -ExpandProperty Guid)
    } while (Test-Path -Path $newTempDirPath)
    New-Item -ItemType Directory -Path $newTempDirPath
}

Write-EventLogWrapper -message "Initializing the WinTrialLab cloud builder deployment..."
Set-ExecutionPolicy -ExecutionPolicy Unrestricted -Scope LocalMachine

# Install DSC prerequisites
Install-PackageProvider -Name NuGet -Force
Set-PSRepository -Name PSGallery -InstallationPolicy Trusted
Install-Module -Name xHyper-V, cChoco

if ($PsCmdlet.ParameterSetName -match "InitializeVm") {
    # Download the wintriallab repo
    $wtlDlDir = New-TemporaryDirectory
    $wtlExtractDir = New-Item -Type Directory -Force -Path (Join-Path -Path $wtlDlDir -ChildPath "extracted")
    $wtlZipFile = Join-Path -Path $wtlDlDir -ChildPath "wtl.zip"
    Invoke-WebRequest -Uri $wtlRepoZipUri -OutFile $wtlZipFile
    Expand-Archive -Path $wtlZipFile -DestinationPath $wtlExtractDir
    $wtlDir = Get-ChildItem -Path $wtlExtractDir | Select-Object -First 1 -ExpandProperty FullName
    Write-EventLogWrapper "wintriallab files and directories:`r`nwtlDlDir = '$wtlDlDir'`r`nwtlExtractDir = '$wtlExtractDir'`r`nwtlZipFile = '$wtlZipFile'`r`nwtlDir = '$wtlDir'`r`n"
} else {
    $wtlDir = Resolve-Path -Path $PSScriptRoot\..
}

# Ensure Powershell can find our DSC resources
# Note that DSC configurations are applied under the SYSTEM user, so we cannot just set our own copy of $env:PSModulePath and expect it to pick that up
$machinePsModPath = "$env:ProgramFiles\WindowsPowerShell\Modules"
Copy-Item -Recurse -Force -Path $wtlDir\azure\DscModules\* -Destination $machinePsModPath

# Initialize the DSC configuration
Write-EventLogWrapper "Invoking DSC configuration..."
. "$wtlDir\azure\dscConfiguration.ps1"
$dscWorkDirBase = New-Item -Type Directory -Path "$wtlDir\azure\DscConfigs" -Force | Select-Object -ExpandProperty FullName
Write-EventLogWrapper -message "Using '$dscWorkDirBase' for DSC configurations"
if (Test-Path $dscWorkDirBase) {
    Remove-Item -Force -Recurse -Path $dscWorkDirBase
}

# Configure the Local Configuration Manager first
$lcmWorkDir = Join-Path -Path $dscWorkDirBase -ChildPath "WtlLcmConfig"
WtlLcmConfig -OutputPath $lcmWorkDir | Write-EventLogWrapper
Set-DscLocalConfigurationManager -Path $lcmWorkDir | Write-EventLogWrapper

if ($installDebuggingTools) {
    $wtlDbgWorkDir = Join-Path -Path $dscWorkDirBase -ChildPath "WtlDbgConfig"
    $wtlDbgConfigParams = @{
        OutputPath = $wtlDbgWorkDir
    }
    WtlDbgConfig @wtlDbgConfigParams | Write-EventLogWrapper
    # DSC will throw an error if you try to Start-DscConfiguration while another is running
    # Therefore, run with -Wait here so the next configuration can continue
    Start-DscConfiguration -Path $wtlDbgWorkDir -Wait -Force:$runLocal | Write-EventLogWrapper
}

# Now run the WinTrialLab DSC configuration
$wtlWorkDir = Join-Path -Path $dscWorkDirBase -ChildPath "WtlConfig"
$wtlConfigParams = @{
    OutputPath = $wtlWorkDir
    PackerUserCredential = New-Object -TypeName PSCredential -ArgumentList @($packerUserName, (ConvertTo-SecureString -String $packerUserPassword -AsPlainText -Force))
}
WtlConfig @wtlConfigParams | Write-EventLogWrapper
Start-DscConfiguration -Path $wtlWorkDir -Force:$runLocal | Write-EventLogWrapper
