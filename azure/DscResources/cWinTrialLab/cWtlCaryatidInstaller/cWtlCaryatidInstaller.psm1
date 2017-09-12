enum Ensure {
    Absent
    Present
}

enum InstallLocation {
    User
    Machine
}

[DscResource()] class cWtlCaryatidInstaller {
    # Apparently we need a Key property.
    # Use this to indicate the version we installed
    # Set to a fully qualified path
    [DscProperty(Key)]
    [string]
    $DownloadCacheDirectory

    # Location of the Packer plugins directory
    # Note that "User" probably won't be very useful unless we handle installing using a PSCredential
    [DscProperty()]
    [InstallLocation]
    $InstallLocation = [InstallLocation]::Machine

    # The version to install
    [DscProperty()]
    [string]
    $ReleaseVersion

    [DscProperty(Mandatory)]
    [Ensure] $Ensure

    [DscProperty(NotConfigurable)]
    [Nullable[datetime]]
    $CreationTime

    # Instance properties:

    [string] $caryatidPluginFilename = 'packer-post-processor-caryatid.exe'
    [string] $endpointBase = 'https://api.github.com/repos/mrled/caryatid/releases'
    [string] $assetRegex = '^caryatid_windows_amd64_.*\.zip$'  # Must be single quoted~
    [string] $assetFilename
    [object] $_asset

    [object] get_asset() {
        if (-not $this._asset) {
            $this._asset = Invoke-RestMethod -Uri $this.endpoint |
                Select-Object -ExpandProperty assets |
                Where-Object -Property "name" -match $this.caryatidAssetRegex
            Write-Verbose -Message $this._asset
        }
        return $this._asset
    }

    [string] get_assetFilename() {
        return $this.asset.browser_download_url -split '/' | Select-Object -Last 1
    }

    [string] get_installPath() {
        return (Join-Path -Path $this.PackerPluginsDir -ChildPath $this.caryatidPluginFilename)
    }

    [string] get_endpoint() {
        return "$($this.endpointBase)/$($this.ReleaseVersion)"
    }

    [string] get_downloadCacheLocation() {
        if (-not (Test-Path $this.assetFilename)) {
            throw "assetFileName not set"
        }
        return Join-Path -Path $this.DownloadCacheDirectory -ChildPath $this.assetFileName
    }

    [string] get_installDirectory() {
        switch ($this.InstallLocation) {
            [InstallLocation]::Machine {
                return "${env:ProgramFiles}\Packer"
            }
            [InstallLocation]::User {
                return Join-Path -Path $env:AppData -ChildPath (Join-Path -Path "packer.d" -ChildPath 'plugins')
            }
        }
        throw "Unknown install location: $($this.InstallLocation)"
    }

    [string] get_installPath() {
        return (Join-Path -Path $this.installDirectory -ChildPath $this.assetFilename)
    }

    # Required methods:

    [void] Set() {
        $this.ValidateProperties()
        if ($this.Ensure -eq [Ensure]::Present -and -not $this.Test()) {
            Write-Verbose -Message "Downloading release and installing to $($this.installPath)"

            New-Item -Type Directory -Force -Path $this.installDirectory | Out-Null

            Invoke-WebRequest -Uri $this.asset.browser_download_url -OutFile $this.DownloadCacheDirectory
            Write-Verbose -Message "Downloaded asset to $($this.downloadCacheLocation)"

            $extractDir = $this.NewTemporaryDirectory()
            Expand-Archive -Path $this.DownloadCacheLocation -DestinationPath $extractDir
            Write-Verbose -Message "Extracted asset to $extractDir"

            $caryatidExe = Get-ChildItem -Recurse -File -Path $extractDir -Include $this.caryatidPluginFilename | Select-Object -ExpandProperty FullName
            Write-Verbose -Message "Found extracted file at $caryatidExe"
            
            Move-Item -Path $caryatidExe -Destination $this.installPath
            Write-Verbose -Message "Moved extracted file to $($this.installPath)"

        } elseif ($this.Ensure -eq [Ensure]::Absent) {
            Write-Verbose -Message "Removing release and cache"
            Remove-Item -LiteralPath $this.installPath -Force -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath $this.downloadCacheLocatione -Force -ErrorAction SilentlyContinue
        }
    }

    [bool] Test() {
        if (-not (Test-Path -Path $this.downloadCacheLocation) {
            return $false
        }
        if (-not (Test-Path -Path $this.installPath)) {
            return $false
        }
        return $true
    }

    [cWtlCaryatidInstaller] Get() {
        $this.asset | Out-Null  # Make sure the asset is populated
        return $this
    }

    # Helper methods

    [System.IO.FileSystemInfo] NewTemporaryDirectory() {
        $newTempDirPath = ""
        do {
            $newTempDirPath = Join-Path $env:TEMP (New-Guid | Select-Object -ExpandProperty Guid)
        } while ($newTempDirPath -and (Test-Path -Path $newTempDirPath))
        return (New-Item -ItemType Directory -Path $newTempDirPath)
    }

}
