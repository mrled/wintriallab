import-module $PSScriptRoot\wintriallab-postinstall.psm1
$errorActionPreference = "Stop"
Invoke-ScriptblockAndCatch -scriptBlock {

    # Required for Windows 10, not required for 81, not sure about other OSes
    # Should probably happen after installing Guest VM drivers, in case installing the drivers would cause Windows to see the network as a new connection
    Set-AllNetworksToPrivate

    Enable-WinRM
}
