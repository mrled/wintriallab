<#
.description
DSC configurations for WinTrialLab
#>
[CmdletBinding()] Param(
    [string] $chocoInstallDir = (Join-Path -Path ${env:ProgramData} -ChildPath "Chocolatey"),

    [string] $caryatidInstallDir = (Join-Path -Path "${env:AppData}\packer.d" -ChildPath 'plugins'),
    [string] $caryatidPluginFilename = 'packer-post-processor-caryatid.exe',
    [string] $caryatidInstallPath = (Join-Path -Path $caryatidInstallDir -ChildPath $caryatidPluginFilename),
    [string] $caryatidGitHubLatestReleaseEndpoint = 'https://api.github.com/repos/mrled/caryatid/releases/latest',
    [string] $caryatidAssetRegex = '^caryatid_windows_amd64_.*\.zip$'
)

function New-TemporaryDirectory {
    $newTempDirPath = ""
    do {
        $newTempDirPath = Join-Path $env:TEMP (New-Guid | Select-Object -ExpandProperty Guid)
    } while (Test-Path -Path $newTempDirPath)
    New-Item -ItemType Directory -Path $newTempDirPath
}

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
            # Also adds $env:ChocolateyInstall to $env:PATH
            InstallDir = $chocoInstallDir
        }
        cChocoPackageInstaller "ChocoInstallPacker" {
            # Installed to $chocoInstallDir/bin as of 1.0.4
            # https://github.com/StefanScherer/choco-packer/blob/6a059db2d8ec8f1bbc378ee6792d45e5eea54479/tools/chocolateyInstall.ps1
            Name      = 'packer'
            Ensure    = 'Present'
            DependsOn = '[cChocoInstaller]InstallChoco'
        }

        Script "InstallCaryatidPackerPlugin" {
            GetScript = {}
            TestScript = {
                Test-Path -Path $caryatidInstallPath
            }
            SetScript = {
                $asset = Invoke-RestMethod -Uri $caryatidGitHubLatestReleaseEndpoint |
                    Select-Object -ExpandProperty assets |
                    Where-Object -Property "name" -match $caryatidAssetRegex
                $filename = $asset.browser_download_url -split '/' | Select-Object -Last 1
                $downloadDir = New-TemporaryDirectory | Select-Object -ExpandProperty FullName
                $downloadPath = Join-Path -Path $downloadDir -ChildPath $filename
                New-Item -Type Directory -Force -Path $caryatidInstallDir
                Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $downloadPath
                Expand-Archive -Path $downloadPath -DestinationPath $downloadDir
                $caryatidExe = Get-ChildItem -Recurse -File -Path $downloadDir -Include
                Move-Item -Path $caryatidExe -Destination $caryatidInstallPath
            }
            DependsOn = "[cChocoInstaller]ChocoInstallPacker"
        }

        # Script "RunPacker" {
        #     GetScript = {}
        #     TestScript = {}
        #     SetScript = {}
        #     DependsOn = @("[Script]InstallCaryatidPackerPlugin", "[WindowsFeature]Hyper-V-Powershell")
        # }
    }
}
