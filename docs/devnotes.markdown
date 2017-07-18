# Development notes

Some quick notes to self that document problems I've found and how I worked around them.

See also [credits](./credits.markdown), which talks a bit about the intentions of this project.

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


## Miscellaneous notes

- Trouble with provisioners
    - The shell, windows-shell, and powershell provisioners are VERY finicky. The easiest thing I can figure out how to do is to use a Powershell provisioner to call a file with no arguments over WinRM. lol
    - However the situation was much improved when I switched to WinRM with the powershell provisioner. That seems to work OK. I think the problem was that using the shell provisioner with OpenSSH, which provides an emulated POSIX environment of some kind
- There's lots of information on the Internet claiming you can use `HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunServices` (or `RunServicesOnce`) to run something at boot, before logon - analogous to the `Run`/`RunOnce` keys. This is apparently false for any NT operating system. Properties on these keys DO NOT RUN AT BOOT - they are completely ignored by the operating system.
    - The original packer-windows crew got aroudn this by using the `Run` key and disabling UAC in `Autounattend.xml`
    - I'm planning to get around this by creating a scheduled task that starts at boot and runs with highest privileges. This won't work pre-Vista/2008, but that's OK with me.
    - This means I need to write an executor that can start at boot, and then check for things to execute located elsewhere. Bleh.
