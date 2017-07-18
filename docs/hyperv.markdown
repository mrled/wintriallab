# Hyper-V notes

Hyper-V is promising, but has some problems with both Vagrant and Packer.

## Hyper-V cannot be enabled with other virtualization systems

While you can have, say, VMware and VirtualBox installed on the same workstation and happily generate a Vagrant artifact for each from the same packerfile, enabling Hyper-V will keep you from running other virtualizers. If it's necessary to use the same machine to generate Hyper-V and non-Hyper-V artifacts, you might address this in one of the following ways:

-   You can [create a boot entry](http://www.hanselman.com/blog/SwitchEasilyBetweenVirtualBoxAndHyperVWithABCDEditBootEntryInWindows81.aspx) to switch between a boot configuration with Hyper-V enabled and one with Hyper-V disabled
-   You can (apparently - I haven't tried this myself) generate a Hyper-V Vagrant box from a VirtualBox Vagrant box via the [Packer post-processor: VirtualBox to Hyper-V](https://github.com/dwickern/packer-post-processor-virtualbox-to-hyperv) Packer plugin

Note that you may also keep Hyper-V and other builders in your packerfile, but only invoke selected ones via the `-only=builder1,builder2...` flag that can be [passed to `packer build`](https://www.packer.io/docs/command-line/build.html). This won't solve the problem for users wishing to have one machine build Hyper-V and other Vagrant boxes without rebooting, but if you wish to use the same packerfile across some machines with Hyper-V and some machines with another virtualizer, it may be good enough.

## Hyper-V networking is tricky

By default, Packer appears to create a host-only network for communicating with the VM, which doesn't give the VM any Internet access.

Furthermore, Hyper-V bridged networks only bridge to one adapter at a time, which is a pain if you switch between Ethernet and Wifi.

### For Packer: configure a NAT network

Our recommendation is to [create a NAT network](https://docs.microsoft.com/en-us/virtualization/hyper-v-on-windows/user-guide/setup-nat-network), which can only be done with Powershell for the time being, and then setting the `switch_name` parameter for the `hyperv-iso` builder in your Packerfile so your VM will use it.

We wrote a `New-HyperVNatNetwork.ps1` script can create the network for you... however, it is running into intermittent problems. It looks like under some conditions a different version of the `New-NetNat` cmdlet gets loaded? And the parameter set changes so that `-InternalIPInterfaceAddressPrefix` is no longer a valid parameter? Here are some links

-   [The version of the instructions I used](https://github.com/Microsoft/Virtualization-Documentation/blob/2cf6d04c4a8de0148a2f981d21bec72cff23f6e8/virtualization/hyper-v-on-windows/user-guide/setup-nat-network.md) where it says to use `-InternalIPInterfaceAddressPrefix`
-   [Someone else](https://github.com/Microsoft/Virtualization-Documentation/issues/361) ran into this same problem 6 months ago
-   Looks like Docker uses NAT as well... maybe some insight can be gained from [this](https://docs.microsoft.com/en-us/virtualization/windowscontainers/manage-containers/container-networking?
-   Comment on [this page](https://4sysops.com/archives/native-nat-in-windows-10-hyper-v-using-a-nat-virtual-switch/) says "The following powershell as administrator worked today for me in Win 10 Enterprise: `Add-NetNatStaticMapping -NatName NAT -Protocol TCP -ExternalIPAddress 0.0.0.0 -InternalIPAddress 10.0.75.X -InternalPort 22 -ExternalPort 20122; Get-NetNatStaticMapping`"
-   Looks like maybe it got [intentionally removed](https://blogs.technet.microsoft.com/virtualization/2016/05/14/what-happened-to-the-nat-vmswitch/) from Server? Would this have affected Win 10?
-   Hahahahahaha, [this guy](https://thomasvochten.com/archive/2014/01/hyper-v-nat/) suggests installing VMware Player, using the VMnet8 NAT adapter it creates, and creating a new vswitch on that adapter. Bonus: you get DHCP this way too! Lol

One major caveat is that *there is no DHCP on your NAT network*, meaning that all guest VMs, including Packer VMs, on the NAT network need to manually configure their IP address, default gateway, and DNS servers. This isn't automated yet, but we plan to automate it.

### For Packer: statically assign IP addresses

For Packer: statically assign IP addresses

Unfortunately, the NAT networking in Windows is in a state of flux. It turns out that staticaly assigning an IP address may work better for now.

To do that, the static address must be hardcoded in `autounattend-postinstall.ps1`. At the time of this writing, we have done that, but it requires your virtual network to have a matching configuration.

### For Vagrant: use the public network

If you can, the easiest thing to do is to use a public network in HyperV, like this:

    config.vm.network :public_network, :adapter=>1, type:"dhcp", :bridge=>'HyperVWifiSwitch'

That requires a vswitch named, in this case, `HyperVWifiSwitch` (which I have bridged with the wifi adapter on my laptop), to already exist.
