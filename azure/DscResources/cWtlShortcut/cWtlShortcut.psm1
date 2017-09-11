enum Ensure {
    Absent
    Present
}

# From https://msdn.microsoft.com/en-us/library/w88k7fw2(v=vs.84).aspx
enum WindowStyle {
    Activate = 1
    Maximize = 3
    Minimize = 7
}

<#
Manage shortcuts
#>
[DscResource()] class cWtlShortcut {
    # Fully qualified path to the shortcut file
    # Note that the extension *must* end in .lnk, or we throw an error
    [DscProperty(Key)]
    [string] $ShortcutPath

    # Fully qualified path to the shortcut target
    [DscProperty(Mandatory)]
    [string] $TargetPath

    # Optional arguments to pass to the executable at $TargetPath
    [DscProperty()]
    [Nullable[string]] $TargetArguments = ""

    # The WindowStyle for the shortcut
    [DscProperty()]
    [Nullable[WindowStyle]] $WindowStyle = [WindowStyle]::Activate

    [DscProperty(Mandatory)]
    [Ensure] $Ensure

    [DscProperty(NotConfigurable)]
    [Nullable[datetime]] $CreationTime

    [void] Set() {
        $this.ValidateProperties()
        if ($this.Ensure -eq [Ensure]::Present -and -not $this.TestShortcut()) {
            Write-Verbose -Message "Creating shortcut at path $($this.ShortcutPath)"
            $this.CreateShortcut()
        } elseif ($this.Ensure -eq [Ensure]::Absent -and (Test-Path -Path $this.ShortcutPath)) {
            Write-Verbose -Message "Deleting the file $($this.ShortcutPath)"
            Remove-Item -LiteralPath $this.ShortcutPath -Force
        }
    }

    [bool] Test() {
        $this.ValidateProperties()
        if ($this.Ensure -eq [Ensure]::Present) {
            Write-Verbose -Message "Shortcut at path $($this.ShortcutPath) is present"
            return $this.TestShortcut()
        } else {
            Write-Verbose -Message "Shortcut at path $($this.ShortcutPath) is absent"
            return $false
        }
    }

    [cWtlShortcut] Get() {
        $this.ValidateProperties()
        $present = $this.TestShortcut()
        if ($present) {
            $lnkFile = Get-Item -LiteralPath $this.ShortcutPath
            $this.CreationTime = $lnkFile.CreationTime
            $this.Ensure = [Ensure]::Present
        } else {
            $exShortcut = $this.GetShortcut()

            $this.ShortcutPath = if (Test-Path $this.ShortcutPath) { $this.ShortcutPath } else { $null }
            $this.TargetPath = $exShortcut.TargetPath
            $this.TargetArguments = $exShortcut.Arguments
            $this.WindowStyle = [WindowStyle]$exShortcut.WindowStyle

            $this.CreationTime = $null
            $this.Ensure = [Ensure]::Absent
        }
        return $this
    }

    # Not sure if there's a better way to do this?
    [void] ValidateProperties() {
        if (-not [System.IO.Path]::IsPathRooted($this.ShortcutPath)) {
            throw "The value of the ShortcutPath DSC property is not a rooted path"
        }
        if (-not [System.IO.Path]::IsPathRooted($this.TargetPath)) {
            throw "The value of the TargetPath DSC property is not a rooted path"
        }
        if (-not $this.ShortcutPath.ToLower().EndsWith(".lnk")) {
            throw "The value of the ShortcutPath DSC property does not end in '.lnk', which is required for shortcut files"
        }
    }

    [object] GetShortcut() {
        $wshShell = New-Object -ComObject WScript.Shell
        # Note: $wshshell.CreateShortcut does not create the file if it doesn't exist
        # To create it, you have to call .Save() on the shortcut object
        return $wshShell.CreateShortcut($this.ShortcutPath)
    }

    [bool] TestShortcut() {
        $shortcut = $this.GetShortcut()
        $present = $true
        if (-not (Test-Path $this.ShortcutPath)) {
            Write-Verbose -Message "Shortcut at path $($this.ShortcutPath) does not exist"
            $present = $false
        }
        if ($shortcut.WindowStyle -ne [int]$this.WindowStyle) {
            Write-Verbose -Message "For shortcut at path $($this.ShortcutPath) the WindowStyle property does not match"
            $present = $false
        }
        if ($shortcut.TargetPath -ne $this.TargetPath) {
            Write-Verbose -Message "For shortcut at path $($this.ShortcutPath) the TargetPath property does not match"
            $present = $false
        }
        if ($shortcut.Arguments -ne $this.Arguments) {
            Write-Verbose -Message "For shortcut at path $($this.ShortcutPath) the Arguments property does not match"
            $present = $false
        }
        return $present
    }

    [void] CreateShortcut() {
        $shortcut = $this.GetShortcut()
        $shortcut.WindowStyle = [int]$this.WindowStyle
        $shortcut.TargetPath = $this.TargetPath
        $shortcut.Arguments = $this.TargetArguments  # This can be an empty string
        $shortcut.Save()
    }
}
