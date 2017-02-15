Windows Trial Lab: Build Vagrant boxes from Windows trial ISOs

## Prerequisites

- A hypervisor (VirtualBox or Hyper-V currently)
- Packer
- [Caryatid](https://github.com/mrled/caryatid), a Packer plugin
- Vagrant

Everything is intended to work from Windows or Unix hosts

## Status

- vbox win10 32bit: working
- hyperv win10 32bit: broken
- vbox win10 64bit: unimplemented
- hyperv win10 64bit: unimplemented
- vbox server2016 64bit: unimplemented
- hyperv server2016 64bit: unimplemented

## Usage

1. Change directory to one of the packer builder directories, e.g. `cd packer/wintriallab-win10-32`
2. Examine the `variables` section of the packerfile, especially `boxname`, `version`, and `catalog_root_url`
3. Run packer for whatever hypervisor you are using, and optionally supplying an override value for some variables, e.g. `packer -only=virtualbox-iso -var catalog_root_url=$HOME/Vagrant -var version=0.0.1`
4. When this finishes, your `catalog_root_url` will have a file name `<BOXNAME>.json`. You can use a `file://` URL to that catalog as the value for `box_url` in a `Vagrantfile`, and Vagrant will notice when you publish new versions of the box. (See [Caryatid](https://github.com/mrled/caryatid)'s documentation for more information.)

There are some Vagrant boxes in the `vagrant` directory. They are intended as examples and are not guaranteed to work or remain stable over time.

## Hyper-V notes

1.  While you can have, say, VMware and VirtualBox installed on the same workstation and happily generate a Vagrant artifact for each from the same packerfile, enabling Hyper-V will keep you from running other virtualizers. If it's necessary to use the same machine to generate Hyper-V and non-Hyper-V artifacts, you might address this in one of the following ways:

    -   You can [create a boot entry](http://www.hanselman.com/blog/SwitchEasilyBetweenVirtualBoxAndHyperVWithABCDEditBootEntryInWindows81.aspx) to switch between a boot configuration with Hyper-V enabled and one with Hyper-V disabled
    -   You can (apparently - I haven't tried this myself) generate a Hyper-V Vagrant box from a VirtualBox Vagrant box via the [Packer post-processor: VirtualBox to Hyper-V](https://github.com/dwickern/packer-post-processor-virtualbox-to-hyperv) Packer plugin

    Note that you may also keep Hyper-V and other builders in your packerfile, but only invoke selected ones via the `-only=builder1,builder2...` flag that can be [passed to `packer build`](https://www.packer.io/docs/command-line/build.html). This won't solve the problem for users wishing to have one machine build Hyper-V and other Vagrant boxes without rebooting, but if you wish to use the same packerfile across some machines with Hyper-V and some machines with another virtualizer, it may be good enough.

2.  Networking with Hyper-V is tricky.

    By default, Packer appears to create a host-only network for communicating with the VM, which doesn't give the VM any Internet access.

    Furthermore, Hyper-V bridged networks only bridge to one adapter at a time, which is a pain if you switch between Ethernet and Wifi.

    Our recommendation is to [create a NAT network](https://docs.microsoft.com/en-us/virtualization/hyper-v-on-windows/user-guide/setup-nat-network), which can only be done with Powershell for the time being, and then setting the `switch_name` parameter for the `hyperv-iso` builder in your Packerfile so your VM will use it.

    We wrote a `New-HyperVNatNetwork.ps1` script can create the network for you... however, it is running into intermittent problems. It looks like under some conditions a different version of the `New-NetNat` cmdlet gets loaded? And the parameter set changes so that `-InternalIPInterfaceAddressPrefix` is no longer a valid parameter? Here are some links

    -   [The version of the instructions I used](https://github.com/Microsoft/Virtualization-Documentation/blob/2cf6d04c4a8de0148a2f981d21bec72cff23f6e8/virtualization/hyper-v-on-windows/user-guide/setup-nat-network.md) where it says to use `-InternalIPInterfaceAddressPrefix`
    -   [Someone else](https://github.com/Microsoft/Virtualization-Documentation/issues/361) ran into this same problem 6 months ago
    -   Looks like Docker uses NAT as well... maybe some insight can be gained from [this](https://docs.microsoft.com/en-us/virtualization/windowscontainers/manage-containers/container-networking?
    -   Comment on [this page](https://4sysops.com/archives/native-nat-in-windows-10-hyper-v-using-a-nat-virtual-switch/) says "The following powershell as administrator worked today for me in Win 10 Enterprise: `Add-NetNatStaticMapping -NatName NAT -Protocol TCP -ExternalIPAddress 0.0.0.0 -InternalIPAddress 10.0.75.X -InternalPort 22 -ExternalPort 20122; Get-NetNatStaticMapping`"
    -   Looks like maybe it got [intentionally removed](https://blogs.technet.microsoft.com/virtualization/2016/05/14/what-happened-to-the-nat-vmswitch/) from Server? Would this have affected Win 10?
    -   Hahahahahaha, [this guy](https://thomasvochten.com/archive/2014/01/hyper-v-nat/) suggests installing VMware Player, using the VMnet8 NAT adapter it creates, and creating a new vswitch on that adapter. Bonus: you get DHCP this way too! Lol

    One major caveat is that *there is no DHCP on your NAT network*, meaning that all guest VMs, including Packer VMs, on the NAT network need to manually configure their IP address, default gateway, and DNS servers. This isn't automated yet, but we plan to automate it.

## To do

Scripts:

- Figure out a way to determine hypervisor during `autounattend-postinstall.ps1` and install the hypervisor drivers (right now it's hardcoded to just install the vbox ones, which will break on other hypervisors)
- Convert the postinstall scripts to use Powershell DSC
- Write Pester tests for all script logic (including DSC logic)
- What's the impact of `Install-CompiledDotNetAssemblies` and `Compress-WindowsInstall` (called at the bottom of `provisioner-postinstall.ps1`)? They both add about 15 minutes to the build time... are they worth it?

Packer:

- Fix NAT networking with Hyper-V (see above)
- Determine once and for all if we can do everything necessary without turning off UAC (`<EnableLUA>false</EnableLUA>` in Autounattend) and document the findings
- Can [sysprep](https://msdn.microsoft.com/en-us/windows/hardware/commercialize/manufacture/desktop/sysprep--generalize--a-windows-installation) do anything interesting for us? I'm particularly interested in its `/generalize` option, because the docs I've seen claim it shuts down the machine, and the next time it boots, the clock for Windows activation resets. (Also seen docs say you can only `/generalize` a given Windows image 8 times.) Could this mean I can create a Windows trial Vagrant box that I don't have to recreate every 90 days?
- Add/fix all unimplemented/broken boxes from the "Status" section above

Vagrant:

- Store passwords securely and change them automatically on logon... not sure how to do this yet though

Wishlist (no plans to attempt these, but I wish I had time to)

- Use some kind of templating system for Autounattend.xml files? Looks like the [inductor](https://github.com/joefitzgerald/inductor) project from @joefitzgerald (also responsible for the packer-windows project that wintriallab is based on) was intended to do this
- Include VMware provisioner. Not really interested in doing this without being able to test the resulting VMware boxes, which I can't do without paying Hashicorp $80
- Apply Windows updates to ISOs so the first Windows Update run is faster. This can take over 6 hours on an unpatched Windows 8.1 build.
- I wish Packer and Vagrant could support client certs for WinRM (see the [WinRM docs](https://msdn.microsoft.com/en-us/library/aa384295%28v=vs.85%29.aspx)) so we could do away with passwords

## Execution flow

- Packer spins up a VM with an ISO and an Autounattend.xml file
- Windows installer reads from Autounattend and installs Windows. Packer cannot see what's going on in this step, because it cannot connect to the machine over WinRM yet
- The final step in the Autounattend.xml file is to run the `autounattend-postinstall.ps1` script. Packer still can't see what's happening, so as little logic as possible should go here
- The final step in `autounattend-postinstall.ps1` is to reboot and then either 1) `enable-winrm.ps1` or 2) run `win-updates.ps1`, which runs `enable-winrm.ps1` when it completes.
    - `win-updates.ps1` will run Windows update, set itself to be run at startup, reboot, and get started again by the OS to start over until there are no more updates. Warning: on a Windows 7/8 system this can take many hours!
- Once WinRM is enabled, Packer can finally connect; it does so and runs the `provisioner-postinstall.ps1` script. Now Packer can see the output of the commands it runs, and output them to the console
- After `provisioner-postinstall.ps1` is finished, Packer shuts down the VM and continues to run the post-processor steps to generate a Vagrant box and invoke Caryatid

Some general notes

- It's best to put the most logic where Packer can see it, meaning that as much logic as possible should go in `provisioner-postinstall.ps1`
- You can't run Windows Update before enabling WinRM, because once Packer connects there is no way for it to gracefully handle reboots
- It's best to install hypervisor drivers in the VM before running Windows update for speed. Note that different hypervisors use different ways to install their drivers; with VirtualBox, Packer can just attach the local guest additions ISO, but with Hyper-V, all updates come via Windows Update anyway.
- We log to a custom event log (see `Write-EventLogWrapper` in `wintriallab-postinstall.psm1`) even before Packer connects over WinRM, so if you're having problems, checek the `PostInstall-Marionettist` event log

## Development notes

- Trouble with provisioners
    - The shell, windows-shell, and powershell provisioners are VERY finicky. The easiest thing I can figure out how to do is to use a Powershell provisioner to call a file with no arguments over WinRM. lol
    - However the situation was much improved when I switched to WinRM with the powershell provisioner. That seems to work OK. I think the problem was that using the shell provisioner with OpenSSH, which provides an emulated POSIX environment of some kind
- There's lots of information on the Internet claiming you can use `HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunServices` (or `RunServicesOnce`) to run something at boot, before logon - analogous to the `Run`/`RunOnce` keys. This is apparently false for any NT operating system. Properties on these keys DO NOT RUN AT BOOT - they are completely ignored by the operating system.
    - The original packer-windows crew got aroudn this by using the `Run` key and disabling UAC in `Autounattend.xml`
    - I'm planning to get around this by creating a scheduled task that starts at boot and runs with highest privileges. This won't work pre-Vista/2008, but that's OK with me.
    - This means I need to write an executor that can start at boot, and then check for things to execute located elsewhere. Bleh.

## Credits

This started as some customizations for [joefitzgerald/packer-windows](https://github.com/joefitzgerald/packer-windows) that got a liiiiiiiittle out of hand.

These were the *types* of changes I'm trying to make:

- I rewrote their Windows Update script to be much more readable (imo). Now it has clearly defined functions with parameter blocks, you can set the postinstall step when calling it (rather than hardcoding calling `A:\openssh.ps1`) and you only have to set it once, and all functions MAY read global variables set at the top level but DO NOT write to them.
- I want to use WinRM rather than OpenSSH
    - As a result of this, I don't copy anything to the host for provisioning, because this is buggy with WinRM. This isn't a big deal though - I just put everything I want to use on the A:\ drive and use the "attach" guest additions mode in Packer
    - I have a much easier time dealing with my provisioners though
- I rewrote lots of their scripts as functions in my Powershell module, and a couple of scripts that call into that module
    - This means that my Autounattend.xml is simpler - I just have one or two postinstall commands in there. The last one must enable WinRM.
    - It also means my packerfile is simpler AND it lets me place comments next to commands - packerfile uses JSON which doesn't allow this for stupid reasons
- I log to Windows Event Log

And these are some specific changes that may impact you

- The original project has [a way to install KB2842230](https://github.com/joefitzgerald/packer-windows/blob/master/scripts/hotfix-KB2842230.bat). I haven't run into this problem, but if I did, I'd have to figure this one out too. I'm not sure but it appears that they have an installer script but not a downloader script - it's unclear whether people are actually using this or not.
- The original project has [a script that forces all network locations to be private](https://github.com/joefitzgerald/packer-windows/blob/master/scripts/fixnetwork.ps1), which is necessary to enable PS Remoting. I haven't hit a problem that this solved yet, so I don't include it.
    - The Windows 10 Autounattend.xml also sets the NewNetworkWindowOff registry key, per <https://technet.microsoft.com/en-us/library/gg252535%28v=ws.10%29.aspx>, by doing `cmd.exe /c reg add "HKLM\System\CurrentControlSet\Control\Network\NewNetworkWindowOff"`, before running the fixnetwork.ps1 script.
- I don't have VMware, only VirtualBox, so all the VMware support was removed (since I was rewriting it and couldn't test it, this seemed like the right thing to do)
- I use WinRM rather than OpenSSH
- I don't include installers for puppet/salt/etc
- I had to change the vagrant user's password to something more complex so you could remote in to it
