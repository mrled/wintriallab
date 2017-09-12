enum Ensure {
    Absent
    Present
}

enum InstallLocation {
    User
    Machine
}

[DscResource()] class cWtlCaryatidInstaller {
    # The version to install
    # "latest" will get the latest release
    [DscProperty(Key)]
    [string]
    $ReleaseVersion

    # Location of the Packer plugins directory
    # Note that "User" probably won't be very useful unless we handle installing using a PSCredential
    [DscProperty()]
    [InstallLocation]
    $InstallLocation = [InstallLocation]::Machine

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
    [string] $_workDir
    [object] $_asset

    [object] get_asset() {
        $endpoint = "$($this.endpointBase)/$($this.ReleaseVersion)"
        if (-not $this._asset) {
            $this._asset = Invoke-RestMethod -Uri $endpoint |
                Select-Object -ExpandProperty assets |
                Where-Object -Property "name" -match $this.assetRegex
            Write-Verbose -Message $this._asset
        }
        return $this._asset
    }

    [string] get_workDir() {
        if (-not ($this._workDir)) {
            $this._workDir = $this.NewTempDir()
        }
        return $this._workDir
    }

    [string] get_assetFilename() {
        return $this.asset.browser_download_url -split '/' | Select-Object -Last 1
    }

    [string] get_installPath() {
        return (Join-Path -Path $this.installDirectory -ChildPath $this.caryatidPluginFilename)
    }

    [string] get_installDirectory() {
        switch ($this.InstallLocation) {
            [InstallLocation]::Machine {
                return Join-Path -Path $env:ProgramFiles -ChildPath "Packer"
            }
            [InstallLocation]::User {
                return Join-Path -Path $env:AppData -ChildPath (Join-Path -Path "packer.d" -ChildPath 'plugins')
            }
        }
        throw "Unknown install location: $($this.InstallLocation)"
    }

    # Required methods:

    [void] Set() {
        $this.ValidateProperties()
        if ($this.Ensure -eq [Ensure]::Present -and -not $this.Test()) {
            Write-Verbose -Message "Downloading release and installing to $($this.installPath)"

            New-Item -Type Directory -Force -Path $this.installDirectory | Out-Null
            $workDir = $this.NewTempDir() | Select-Object -ExpandProperty FullName
            $dlPath = Join-Path -Path $this.workDir -ChildPath $this.assetFileName

            try {
                Invoke-WebRequest -Uri $this.asset.browser_download_url -OutFile $workDir
                Write-Verbose -Message "Downloaded asset to $dlPath"

                Expand-Archive -Path $this.dlPath -DestinationPath $workDir
                Write-Verbose -Message "Extracted asset to $workDir"

                $caryatidExe = Get-ChildItem -Recurse -File -Path $workDir -Include $this.caryatidPluginFilename | Select-Object -ExpandProperty FullName
                Write-Verbose -Message "Found extracted file at $caryatidExe"
                
                Move-Item -Path $caryatidExe -Destination $this.installPath
                Write-Verbose -Message "Moved extracted file to $($this.installPath)"
            } finally {
                Write-Verbose -Message "Encountered an error, deleting $workDir"
                Remove-Item -Force $workDir
            }

        } elseif ($this.Ensure -eq [Ensure]::Absent) {
            Write-Verbose -Message "Removing release and cache"
            Remove-Item -LiteralPath $this.installPath -Force -ErrorAction SilentlyContinue
        }
    }

    [bool] Test() {
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

    [System.IO.FileSystemInfo] NewTempDir() {
        $newTempDirPath = ""
        do {
            $newTempDirPath = Join-Path $env:TEMP (New-Guid | Select-Object -ExpandProperty Guid)
        } while ($newTempDirPath -and (Test-Path -Path $newTempDirPath))
        return (New-Item -ItemType Directory -Path $newTempDirPath)
    }

}
