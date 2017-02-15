<#
.synopsis
Create a virtual network for doing NAT with Hyper-V
.parameter network
A network range described in CIDR notation, like "192.168.160.0/24". Note that this should not overlap with any network you connect with normally, and, since you cannot predict the address ranges of every LAN you might ever connect to, you will have to pick a rarely used address range and hope no one else picked the same one.
.parameter switchName
The name of the new Hyper-V virtual switch
.parameter natNetworkName
The name of the NAT network
#>
[CmdletBinding()] param(
    [Parameter(Mandatory=$true, Position=0)] $network,
    [Parameter(Position=1)] $switchName = "HyperVNatSwitch",
    [Parameter(Position=2)] $natNetworkName = "NatNetwork",
    [switch] $force
)

$ErrorActionPreference = "Stop"

<#
.description
Increment an IP address
.parameter address
Any string, integer, or array that the IPAddress class can convert to an IP address
Examples: [String]'192.168.1.1', [Int]22222, [String]'::1', [Array]@(192, 168, 0, 1)
.parameter addend
A positive integer to increment, or a negative integer to decrement
#>
function Add-ToIpAddress {
    [CmdletBinding()] Param(
        [Parameter(ValueFromPipeline=$True, Mandatory=$True)] [IPAddress] $address,
        [Int64] $addend = 1
    )

    $addrBytes = $address.GetAddressBytes()

    if ([BitConverter]::IsLittleEndian) {
        # If we're on a little endian architecture like x86, we have to reverse the order of the bytes in order to add our addend to it,
        # and then we'll need to reverse it again (see below) after addition before returning it
        # This is because .GetAddressBytes() always returns in big endian order
        [Array]::Reverse($addrBytes)
    }

    $addrInt = [BitConverter]::ToUInt32($addrBytes, 0)
    $newAddrInt = $addrInt + $addend
    $newAddr = [IPAddress]$newAddrInt

    if ([BitConverter]::IsLittleEndian) {
        $newAddrBytes = $newAddr.GetAddressBytes()
        [Array]::Reverse($newAddrBytes)
        $newAddr = [IPAddress]$newAddrBytes
    }

    return $newAddr
}

# Determine the network prefix and network suffix
$netSplit = $network.Split("/")
$netPrefix = $netSplit[0]
[IPAddress] $netPrefix | Out-Null # Will throw if it fails to convert it to an IP address
$netSuffix = $netSplit[1]
if (($netSuffix -lt 0) -or ($netSuffix -gt 64)) {throw "Invalid network suffix of '$netSuffix'"}

# This sets the IP address for our Hyper-V host machine to the first available address on the network, e.g. if the network is 192.168.0.0/24 this will use 192.168.0.1
$hostNatIpAddr = Add-ToIpAddress -address $netPrefix -addend 1

# The New-VMSwitch cmdlet will always create an adapter named after it
$switchAdapterName = "vEthernet ($switchName)"

# Check for existing switch/adapter/address/NAT
$vmSwitch = Get-VMSwitch |? -Property Name -eq $switchName
$ipAddr = Get-NetIPAddress |? -Property IPAddress -eq $hostNatIpAddr
$netNat = Get-NetNat |? -Property Name -eq $natNetworkName
if ($vmSwitch -or $ipAddr -or $netNat) {
    if ($force) {
        if ($vmSwitch) {Remove-VMSwitch -Name $switchName -Force}
        if ($ipAddr) {Remove-NetIpAddress -IPAddress $hostNatIpAddr}
        if ($netNat) {Remove-NetNat -name $natNetworkName}
    } else {
        throw "Existing switch/address/NAT"
    }
}

# Actually create the switch, adapter, IP address, and NAT
$vmSwitch = New-VMSwitch -SwitchName $switchName -SwitchType Internal
$switchAdapter = Get-NetAdapter -Name "vEthernet ($switchName)"
$ipAddr = New-NetIPAddress -IPAddress $hostNatIpAddr -PrefixLength $netSuffix -InterfaceIndex $switchAdapter.ifIndex
$netNat = New-NetNat -Name $natNetworkName -InternalIPInterfaceAddressPrefix $address
