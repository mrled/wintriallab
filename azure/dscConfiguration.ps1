<#
DSC configuration for WinTrialLab

General notes:
- The debug configuration isn't going to be useful once everything is fully automated, but it's solving the most fucking annoying problems I'm having during debugging when I have to RDP to the server all the time
- Script resources are weird. Unlike other resources, you cannot use external variables in them, so instead, we use {0} and the -f string format argument to pass in any external variables we require. This also means that we cannot use external functions, which would be harder to pass that way. See also https://stackoverflow.com/questions/23346901/powershell-dsc-how-to-pass-configuration-parameters-to-scriptresources#27848013
#>

$defaultChocoInstallDir = Join-Path -Path ${env:ProgramData} -ChildPath "Chocolatey"

<#
.parameter computerName
This probably has to be "localhost".
The reason for this it that any other value - for instance, '$env:COMPUTERNAME' - triggers behavior that attempts to run the configuration over WinRM. This won't see the custom $env:PSModulePath we may have set in deployInit.ps1, and may have Execution Policy issues as well.
#>
[DSCLocalConfigurationManager()]
Configuration WtlLcmConfig {
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
            # New-ItemProperty -Path HKLM:\SOFTWARE\Microsoft\ServerManager -Name DoNotOpenServerManagerAtLogon -PropertyType DWORD -Value "0x1" –Force
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

        ## WinTrialLab settings

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
            # Installed to $ChocoInstallDir/bin as of 1.0.4
            # https://github.com/StefanScherer/choco-packer/blob/6a059db2d8ec8f1bbc378ee6792d45e5eea54479/tools/chocolateyInstall.ps1
            Name      = 'packer'
            Ensure    = 'Present'
            DependsOn = '[cChocoInstaller]InstallChoco'
        }

        cWtlCaryatidInstaller "InstallCaryatidPackerPlugin" {
            Ensure = "Present"
            ReleaseVersion = $CaryatidReleaseVersion
            PsDscRunAsCredential = $PackerUserCredential
        }

        # Script "RunPacker" {
        #     GetScript = {}
        #     TestScript = {}
        #     SetScript = {}
        #     DependsOn = @("[Script]InstallCaryatidPackerPlugin", "[WindowsFeature]Hyper-V-Powershell")
        # }
    }
}
