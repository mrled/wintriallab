[cmdletbinding()] Param(
    [switch] $SkipWindowsUpdates
)

import-module $PSScriptRoot\wintriallab-postinstall.psm1
$errorActionPreference = "Stop"

# Messages that aid debugging go here. Keep them extremely simple and therefore extremely unlikely to fail
Invoke-ScriptblockAndCatch {
    $message = "Debugging information: `r`n`r`n"
    $message += "Running as administrator: $(Test-AdminPrivileges)`r`n`r`n"
    $message += "Variables:`r`n"
    foreach ($var in (Get-ChildItem env:\)) {
        $message += "$($var.Name) = $($var.Value)`r`n"
    }
    Write-EventLogWrapper -message $message
}

# Operations changing the state of the VM and other things that might be more inclined to fail go here
Invoke-ScriptblockAndCatch -scriptBlock {
    Write-EventLogWrapper "Starting the autounattend postinstall script"
    Set-IdleDisplayPoweroffTime -seconds 0
    Set-PasswordExpiry -accountName "vagrant" -disable
    Disable-HibernationFile
    Enable-MicrosoftUpdate
    
    # Note that we need to reboot for some of these drivers to take
    # AHHHH, PACKER_BUILDER_TYPE ISN'T AVAILABLE HERE BECAUSE IT'S INVOKED FROM THE WINDOWS INSTALLER. Hmmmmmm. Might have to do this later.
    # if ($env:PACKER_BUILDER_TYPE -contains "virtualbox") {
    #     # Requires that the packerfile attach the Guest VM driver disk, rather than upload it (the packer-windows way). Uploading it gives problems with WinRM for some reason.
    #     Install-VBoxAdditions -fromDisc
    # }
    # elseif ($env:PACKER_BUILDER_TYPE -contains "hyperv") {
    #     Write-EventLogWrapper -message "Hyper-V builder detected, but we don't have a way to install its drivers yet"
    # }
    # else {
    #     Write-EventLogWrapper -message "A builder called '$env:PACKER_BUILDER_TYPE' was detected, but we don't have a way to install its drivers yet"
    # }
    # Install-VBoxAdditions -fromDisc
    
    # Required for Windows 10, not required for 81, not sure about other OSes
    # Should probably happen after installing Guest VM drivers, in case installing the drivers would cause Windows to see the network as a new connection
    Set-AllNetworksToPrivate

    if ($SkipWindowsUpdates) {
        $restartCommand = "A:\enable-winrm.ps1"
    }
    else {
        $restartCommand = "A:\win-updates.ps1 -PostUpdateExpression A:\enable-winrm.ps1"
    }

    Set-RestartScheduledTask -RestartCommand $restartCommand | out-null
    Restart-Computer -force
}
