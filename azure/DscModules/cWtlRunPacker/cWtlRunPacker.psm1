enum Ensure {
    Absent
    Present
}

[DscResource(RunAsCredential="Optional")]
class cWtlRunPacker {

    # Set the CWD to this value before running Packer
    [DscProperty(Key)]
    [string]
    $WorkDir

    # The location of the Packer template
    # If this is not a fully qualified path, look for it under $WorkDir
    [DscProperty(Key)]
    [string]
    $PackerTemplate

    [DscProperty(Mandatory)]
    [Ensure] $Ensure

    # Class properties

    # Required methods

    [void] Set() {
        if ($this.Ensure -eq [Ensure]::Present) {
            throw "Not implemented"
        } elseif ($this.Ensure -eq [Ensure]::Absent) {
            throw "Not implemented"
        }
    }

    [bool] Test() {
        throw "Not implemented"
    }

    [cWtlRunPacker] Get() {
        throw "Not implemented"
    }

    # Helper methods

    [string] packerTemplatePath() {
        if ([System.IO.Path]::IsPathRooted($this.PackerTemplate)) {
            $ptPath = $this.PackerTemplate
        } else {
            $ptPath = Join-Path -Path $this.WorkDir -ChildPath $this.PackerTemplate
        }
        if (-not (Test-Path $ptPath)) {
            throw "Packer template at $ptPath does not exist"
        }
        return $ptPath
    }
}
