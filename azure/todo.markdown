# WinTrialLab to do

- This plugin supports S3 authentication in Vagrant boxes and catalogs: https://github.com/WhoopInc/vagrant-s3auth
    - It can even automatically install itself, since a Vagrantfile is just a Ruby program. Lol
    - Add support for uploading to S3 in Caryatid
    - This is good. Crosses off a major goal of Caryatid
- Write a Python program that deletes old boxes from the catalog
    - Ensures I don't pay for S3 storing old expired Windows trial images
    - Should not be related to Caryatid, since Caryatid is an upstream library consumed by WTL
    - Write in Python so that it's cross platform; put it next to the deploy.py script in WTL/azure
    - I think it'll have to get the date info from the version? So it'll rely on the version number being of a certain format.
    - That means it really doesn't belong in the Caryatid repo...
    - Not sure how long I'll need to keep old boxes in there. I want to let vagrant check for new versions... does that necessitate keeping old versions around for a while? If so, maybe I could overwrite them with an empty file, so that the reference is still there but the useless expired trial box isn't?
- Write a DSC resource that runs Packer and uploads to Vagrant
    - The naive implementation of this is just a Script resource that runs `packer.exe`
    - The TestScript doesn't need to test anything - we'll always just build a new one with a new version based on the date
    - How do I handle building more than one Packer box in a single deployment?
    - Doing that might necessitate a real DSC resource, actually. Hmm
- How do I get the Azure resource group to tear itself down when it's done?
    - Ideally, this would be an asynchronous process... it should deploy the resource group and then return immediately, rather than waiting until it's finished like it does now.
    - Maybe an external service? What does Azure have like AWS Lambda... write some kind of simple timer thing that can destroy an environment after a set period of time?
    - This could also be part of the builder VM. Advantage: it'll know when Caryatid is done. Disadvantage: if the deployment gets fucked up, I might not realize it and could keep getting billed
    - Maybe some simple cheap standalone service with a multi-hour timeout that can destroy the entire environment
    - and ALSO a way to call that service from the VM, so that it can call it immediately when Caryatid is done?
    - Azure Scheduler looks like it can do this: https://azure.microsoft.com/en-us/resources/templates/?term=scheduler
- Add remote logging to the cloud builder
    - I need logs for at least the WinTrialLab and DSC event sources
    - I also need the logs from the Azure template's DSC configuration extension from `C:\Package\...`
    - Not sure where to put them tho. If the environment tears itself down afterwards, my AppInsights instance will too, so that's out. Some hosted service with a free tier? Do I need to host my own ELK stack?

Minor improvements

- Make the WinTrialAdmin user autologon to the VM, so that it gets the obnoxious lengthy initial login shit out of the way
- ... fucking use SSH or something to get to the VM, rather than RDP, which is slow and a pain on macOS, which doesn't have a way to pass credentials to Remote Desktop on the CLI (supposedly CoRD allows this - but when I try it, I just get objective C error messages)

Future

- Convert WinTrialLab scripts and modules to DSC
