windows-trial-lab: scripts for building one or more machines from Windows trial ISOs

## Prerequisites

- Python (for the buildlab script)
- VirtualBox
- Packer
- Vagrant

## Using buildlab

The buildlab script is just a wrapper script around packer.exe and vagrant.exe. It can build a packer image and import it into vagrant.

    > .\buildlab.py -h
    usage: buildlab.py [-h] [--base-out-dir BASE_OUT_DIR]
                       [--action {packer,vagrant,packervagrant}] [--whatif]
                       [--force] [--verbose]
                       baseconfigname

    Windows Trial Lab: build trial Vagrant boxes.

    positional arguments:
      baseconfigname        The name of one of the subdirs of the 'packer'
                            directory, like windows_81_x86

    optional arguments:
      -h, --help            show this help message and exit
      --base-out-dir BASE_OUT_DIR, -o BASE_OUT_DIR
                            The base output directory, where Packer does its work
                            and saves its final output. (NOT the VM directory,
                            which is a setting in VirtualBox.)
      --action {packer,vagrant,packervagrant}, -a {packer,vagrant,packervagrant}
                            The action to perform. By default, build with packer
                            and add to vagrant.
      --whatif, -w          Do not perform any actions, only say what would have
                            been done
      --force, -f           Force continue, even if old output directories already
                            exist
      --verbose, -v         Print verbose messages

    NOTE: requires packer 0.8.6 or higher and vagrant 1.8 or higher. EXAMPLE:
    buildlab --baseconfigname windows_10_x86; cd vagrant/FreyjaA; vagrant up

Note that doing the actual `vagrant up` is not part of buildlab - it only makes the box available for you to `vagrant up` later. See my example Vagrant boxes in the vagrant subdirectory, but note that these will be specific to my use; you'll probably want to define your own Vagrantfile(s) with your own provisioner scripts.

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

## Layout and script purpose

- marionettist/windows-trial-lab/
    - buildlab.ps1                          # controls the whole flow of everything
	- scripts/
		- windeploy-marionettist/
			- windeploy-marionettist.psm1
			- (etc)
		- autounattend-postinstall.ps1      # run from Autounattend.xml, contains hardcoded values
		- provisioner-postinstall.ps1       # run by a packer provisioner, contains hardcoded values
        - win-updates.ps1                   # run from autounattend-postinstall if desired, reboots system repeatedly
        - enable-winrm.ps1                  # run from autounattend-postinstall
    - packer/
        - (folders for each version of Windows)

## To do

packer/vagrant/postinstall improvements:

- store passwords securely for shit and/or generate them on the fly
- use client certs for WinRM: https://msdn.microsoft.com/en-us/library/aa384295%28v=vs.85%29.aspx ?? only if packer/vagrant can support it tho
- would be great if I didn't have duplicated Autounattend.xml files everywhere - can I templatize this?
- in Autounattend.xml, we turn off UAC. (That's the `<EnableLUA>false</EnableLUA>` setting.) Is this really required? Or was it only required for using shitty SSH?

vagrant provisioners

- decide on a systems management system. DSC seems like maybe the most natural option.
- pull down git, conemu, my dhd repo
- configure launch bar
- configure taskbar

other improvements

- I really wish I had a way to slipstream updates into ISOs so the first Windows Update run is just getting recent stuff. There are 150+ updates for Win 8.1 at first boot, and these take a few hours to install. Ughhhh.

upstream improvements

- It's possible that the original project might be interested in some of the stuff I've done, particularly the Windows Update work, and maybe even my postinstall module. Clean up the code and submit it to them and see what they think.

## Whines

- The shell, windows-shell, and powershell provisioners are VERY finicky. I canNOT make them work reliably. The easiest thing I can figure out how to do is to use a Powershell provisioner to call a file with no arguments over WinRM. lmfao
- However the situation was much improved when I switched to WinRM with the powershell provisioner. That seems to work OK
- I think the problem was that using the shell provisioner with OpenSSH, which provides an emulated POSIX environment of some kind
- There's lots of information on the Internet claiming you can use `HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunServices` (or `RunServicesOnce`) to run something at boot, before logon - analogous to the `Run`/`RunOnce` keys. This is apparently false for any NT operating system. Properties on these keys DO NOT RUN AT BOOT - they are completely ignored by the operating system.
    - The original packer-windows crew got aroudn this by using the `Run` key and disabling UAC in `Autounattend.xml`
    - I'm planning to get around this by creating a scheduled task that starts at boot and runs with highest privileges. This won't work pre-Vista/2008, but that's OK with me.
    - This means I need to write an executor that can start at boot, and then check for things to execute located elsewhere. Bleh.
