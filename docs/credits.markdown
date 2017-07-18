# Credits

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
    - The Windows 10 Autounattend.xml also sets the NewNetworkWindowOff registry key, [per Microsoft](https://technet.microsoft.com/en-us/library/gg252535%28v=ws.10%29.aspx), by doing `cmd.exe /c reg add "HKLM\System\CurrentControlSet\Control\Network\NewNetworkWindowOff"`, before running the fixnetwork.ps1 script.
- I don't have VMware, only VirtualBox, so all the VMware support was removed (since I was rewriting it and couldn't test it, this seemed like the right thing to do)
- I use WinRM rather than OpenSSH
- I don't include installers for puppet/salt/etc
- I had to change the vagrant user's password to something more complex so you could remote in to it; this is not required for SSH with no UAC, but it is required to connect via WinRM with UAC enabled.
