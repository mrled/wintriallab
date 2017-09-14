<#
DSC configuration for WinTrialLab
#>

$defaultChocoInstallDir = Join-Path -Path ${env:ProgramData} -ChildPath "Chocolatey"

<#
.parameter ComputerName
This probably has to be "localhost".
The reason for this it that any other value - for instance, '$env:COMPUTERNAME' - triggers behavior that attempts to run the configuration over WinRM. This won't see the custom $env:PSModulePath we may have set in deployInit.ps1, and may have Execution Policy issues as well.
#>
[DSCLocalConfigurationManager()]
Configuration WtlLcmConfig {
    param(
        [string[]] $ComputerName = "localhost",
        [string] $DscCertificateThumbprint
    )
    Node $ComputerName {
        Settings {
            RebootNodeIfNeeded = $true
            ActionAfterReboot = 'ContinueConfiguration'
            CertificateId = $DscCertificateThumbprint
        }
    }
}

<#
Enable debugging crap.
Not useful once everything is fully automated, but they're annoying the fuck out of me when I'm RDPing to the server all the time during debugging.
Note that this *should not* do anything that requires a restart, since we call it with `Start-DscConfiguration -Wait`
#>
Configuration WtlDbgConfig {
    param(
        [string[]] $ComputerName = $env:COMPUTERNAME,
        [string] $ChocoInstallDir = $defaultChocoInstallDir
    )

    Import-DscResource -ModuleName PSDesiredStateConfiguration
    Import-DscResource -ModuleName cChoco

    Node $ComputerName {

        cChocoInstaller "InstallChoco" {
            # It seems like this should add $ChocoInstallDir\bin to PATH, but it doesn't appear to do so at the Machine level
            InstallDir = $ChocoInstallDir
        }
        Script "AddChocoToSystemPath" {
            GetScript = { return @{ Result = "" } }
            TestScript = {
                [Environment]::GetEnvironmentVariable("Path", "Machine") -split ';' -contains "${using:ChocoInstallDir}\bin"
            }
            SetScript = {
                $path = [Environment]::GetEnvironmentVariable("Path", "Machine") + [System.IO.Path]::PathSeparator + "${using:ChocoInstallDir}\bin"
                [Environment]::SetEnvironmentVariable("Path", $path, "Machine")
            }
        }

        # Fucking line endings and fucking Notepad make me want to kms
        cChocoPackageInstaller "ChocoInstallVsCode" {
            Name = 'VisualStudioCode'
            Ensure = 'Present'
            DependsOn = '[cChocoInstaller]InstallChoco'
        }
        cChocoPackageInstaller "ChocoInstallVsCodePowershellSyntax" {
            Name = 'vscode-powershell'
            Ensure = 'Present'
            DependsOn = '[cChocoPackageInstaller]ChocoInstallVsCode'
        }


        Script "SetNetworkCategoryPrivate" {
            GetScript = { return @{ Result = "" } }
            TestScript = { return $false }
            SetScript = {
                enum NetworkType {
                    Private = 1
                    Public = 3
                }
                $networkListManagerGuid = [Guid]"{DCB00C01-570F-4A9B-8D69-199FDBA5723B}"
                $networkListManager = [Activator]::CreateInstance([Type]::GetTypeFromCLSID($networkListManagerGuid))
                foreach ($connection in $networkListManager.GetNetworkConnections()) {
                    $network = $connection.GetNetwork()
                    $oldNetworkTypeName = [System.Enum]::GetName([NetworkType], $network.GetCategory())
                    Write-Output "Network called '$($network.GetName())' currently set to type '$oldNetworkTypeName'; forcing to Private..."
                    $connection.GetNetwork().SetCategory([NetworkType]::Private)
                }
            }
        }

        Registry "DoNotOpenServerManagerAtLogon" {
            Ensure = "Present"
            Force = $true
            Key = "HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\ServerManager"
            ValueName = "DoNotOpenServerManagerAtLogon"
            Hex = $true
            ValueData = "0x1"
            ValueType = "Dword"
        }

        cWtlShortcut "AddPowershellDesktopShortcut" {
            Ensure = "Present"
            ShortcutPath = "${env:Public}\Desktop\Powershell.lnk"
            TargetPath = "${env:SystemRoot}\System32\WindowsPowerShell\v1.0\powershell.exe"
        }
        cWtlShortcut "AddEventvwrDesktopShortcut" {
            Ensure = "Present"
            ShortcutPath = "${env:Public}\Desktop\eventvwr.lnk"
            TargetPath = "${env:SystemRoot}\System32\eventvwr.exe"
        }

    }
}

Configuration WtlConfig {
    param(
        [string[]] $ComputerName = $env:COMPUTERNAME,
        [string] $ChocoInstallDir = $defaultChocoInstallDir,
        [string] $CaryatidReleaseVersion = "latest",
        [Parameter(Mandatory)] [PSCredential] $PackerUserCredential
    )

    Import-DscResource -ModuleName PSDesiredStateConfiguration
    Import-DscResource -ModuleName xHyper-V
    Import-DscResource -ModuleName cChoco
    Import-DscResource -ModuleName cWtlShortcut
    Import-DscResource -ModuleName cWtlCaryatidInstaller

    Node $ComputerName {

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
            # It seems like this should add $ChocoInstallDir\bin to PATH, but it doesn't appear to do so at the Machine level
            InstallDir = $ChocoInstallDir
        }
        Script "AddChocoToSystemPath" {
            GetScript = { return @{ Result = "" } }
            TestScript = {
                [Environment]::GetEnvironmentVariable("Path", "Machine") -split ';' -contains "${using:ChocoInstallDir}\bin"
            }
            SetScript = {
                $path = [Environment]::GetEnvironmentVariable("Path", "Machine") + [System.IO.Path]::PathSeparator + "${using:ChocoInstallDir}\bin"
                [Environment]::SetEnvironmentVariable("Path", $path, "Machine")
            }
        }
        cChocoPackageInstaller "ChocoInstallPacker" {
            # Installed to $ChocoInstallDir/bin as of 1.0.4; see chocolateyInstall.ps1
            Name      = 'packer'
            Ensure    = 'Present'
            DependsOn = '[cChocoInstaller]InstallChoco'
        }
        cChocoPackageInstaller "InstallSsh" {
            Name = 'openssh'
            Ensure = 'Present'
            Params = '/SSHServerFeature'
            DependsOn = '[cChocoInstaller]InstallChoco'
        }

        cWtlCaryatidInstaller "InstallCaryatidPackerPlugin" {
            Ensure = "Present"
            ReleaseVersion = $CaryatidReleaseVersion
            PsDscRunAsCredential = $PackerUserCredential
        }

    }
}
