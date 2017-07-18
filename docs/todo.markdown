# To do

There is quite a bit of room for improvement

Scripts:

- Figure out a way to determine hypervisor during `autounattend-postinstall.ps1` and install the hypervisor drivers (right now it's hardcoded to just install the vbox ones, which will break on other hypervisors)
- Convert the postinstall scripts to use Powershell DSC
- Write Pester tests for all script logic (including DSC logic)
- What's the impact of `Install-CompiledDotNetAssemblies` and `Compress-WindowsInstall` (called at the bottom of `provisioner-postinstall.ps1`)? They both add about 15 minutes to the build time... are they worth it?

Packer:

- Fix NAT networking with [Hyper-V](./hyperv.markdown)
- Determine once and for all if we can do everything necessary without turning off UAC (`<EnableLUA>false</EnableLUA>` in Autounattend) and document the findings
- Can [sysprep](https://msdn.microsoft.com/en-us/windows/hardware/commercialize/manufacture/desktop/sysprep--generalize--a-windows-installation) do anything interesting for us? I'm particularly interested in its `/generalize` option, because the docs I've seen claim it shuts down the machine, and the next time it boots, the clock for Windows activation resets. (Also seen docs say you can only `/generalize` a given Windows image 8 times.) Could this mean I can create a Windows trial Vagrant box that I don't have to recreate every 90 days?
- Add/fix all unimplemented/broken boxes from the "Status" section in [the readme](../readme.markdown)

Vagrant:

- Store passwords securely and change them automatically on logon... not sure how to do this yet though
- Add optional functionality that can back up an entire user, including `%APPDATA%`/`%LOCALAPPDATA%`, and restore it to a new Vagrant machine. This would be intended to work with long-running boxes that are still using Windows trial keys.

Wishlist (no plans to attempt these, but I wish I had time to)

- Use some kind of templating system for Autounattend.xml files? Looks like the [inductor](https://github.com/joefitzgerald/inductor) project from @joefitzgerald (also responsible for the packer-windows project that wintriallab is based on) was intended to do this
- Include VMware provisioner. Not really interested in doing this without being able to test the resulting VMware boxes, which I can't do without paying Hashicorp $80
- Apply Windows updates to ISOs so the first Windows Update run is faster. This can take over 6 hours on an unpatched Windows 8.1 build.
- I wish Packer and Vagrant could support client certs for WinRM (see the [WinRM docs](https://msdn.microsoft.com/en-us/library/aa384295%28v=vs.85%29.aspx)) so we could do away with passwords
