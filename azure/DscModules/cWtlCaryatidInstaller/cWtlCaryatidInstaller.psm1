enum Ensure {
    Absent
    Present
}

# FIXME: This doesn't ensure that the version requested is actually installed, just that some file exists in the install location

# Require a credential because we install to $env:AppData, but DSC configurations are run by SYSTEM
[DscResource(RunAsCredential="Required")]
class cWtlCaryatidInstaller {

    # The version to install
    # "latest" will get the latest release
    [DscProperty(Key)]
    [string]
    $ReleaseVersion

    [DscProperty(Mandatory)]
    [Ensure] $Ensure

    # Instance properties:

    [string] $caryatidPluginFilename = 'packer-post-processor-caryatid.exe'
    [string] $endpointBase = 'https://api.github.com/repos/mrled/caryatid/releases'
    [string] $assetRegex = '^caryatid_windows_amd64_.*\.zip$'  # Must be single quoted~
    [object] $_asset

    [object] asset() {
        $endpoint = "$($this.endpointBase)/$($this.ReleaseVersion)"
        if (-not $this._asset) {
            $this._asset = Invoke-RestMethod -Uri $endpoint |
                Select-Object -ExpandProperty assets |
                Where-Object -Property "name" -match $this.assetRegex
            Write-Verbose -Message $this._asset
        }
        return $this._asset
    }

    [string] assetFilename() {
        return $this.asset().browser_download_url -split '/' | Select-Object -Last 1
    }

    [string] installPath() {
        return Join-Path -Path $env:AppData -ChildPath "packer.d" | Join-Path -ChildPath "plugins" | Join-Path -ChildPath $this.caryatidPluginFilename
    }

    # Required methods:

    [void] Set() {
        if ($this.Ensure -eq [Ensure]::Present -and -not $this.Test()) {
            Write-Verbose -Message "Downloading release and installing to $($this.installPath())"

            New-Item -Type Directory -Force -Path (Split-Path -Parent $this.installPath()) | Out-Null
            $workDir = $this.NewTempDir() | Select-Object -ExpandProperty FullName
            $dlPath = Join-Path -Path $workDir -ChildPath $this.assetFilename()

            try {
                Invoke-WebRequest -Uri $this.asset().browser_download_url -OutFile $dlPath
                Write-Verbose -Message "Downloaded asset to $dlPath"

                Expand-Archive -Path $dlPath -DestinationPath $workDir
                Write-Verbose -Message "Extracted asset to $workDir"

                $caryatidExe = Get-ChildItem -Recurse -File -Path $workDir -Include $this.caryatidPluginFilename | Select-Object -ExpandProperty FullName
                Write-Verbose -Message "Found extracted file at $caryatidExe"
                
                Move-Item -Path $caryatidExe -Destination $this.installPath()
                Write-Verbose -Message "Moved extracted file to $($this.installPath())"
            } finally {
                Write-Verbose -Message "Encountered an error, deleting $workDir"
                Remove-Item -Force $workDir
            }

        } elseif ($this.Ensure -eq [Ensure]::Absent) {
            Write-Verbose -Message "Removing release and cache"
            Remove-Item -LiteralPath $this.installPath() -Force -ErrorAction SilentlyContinue
        }
    }

    [bool] Test() {
        return Test-Path -Path $this.installPath()
    }

    [cWtlCaryatidInstaller] Get() {
        $this.asset() | Out-Null  # Make sure the asset is populated
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
