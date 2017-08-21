# Cloud Builder

Using Microsoft's 2017 support for nested virtualization in Azure, build WinTrialLab images in the clerd.

## Deploying

Run the `deploy.py` script. There are several required arguments; run `./deploy.py --help` to see what arguments it accepts.

`deploy.py` is designed to frontend the whole template deployment process; it includes creating the resource group (something that must be done prior to deploying an ARM template), reading the template, and passing parameters to it. Using the Azure CLI is not required.

## Authenticating with Azure

Create a service principal account. Follow [these instructions](https://docs.microsoft.com/en-us/azure/azure-resource-manager/resource-group-create-service-principal-portal) to create the account, create a key for that account, and then assign it the `Contributor` role. Note the ID of the application you created to pass as `--service-principal-id` (this will be a GUID), the secret key value you created to pass as `--service-principal-key` (this will look like Base64 data), and your tenant ID to pass as `--tenant-id` (this will look like `example.onmicrosoft.com`).

## Connecting to the Cloud Builder

We include a `connect.py` script, because Remote Desktop Connection (`mstsc.exe`) doesn't support passing credentials directly. We use `cmdkey.exe` to first save the credentials, then launch `mstsc.exe`, and then finally to remove the credentials (I guess it's more secure to remove them afterwards, but the real reason is that cached credentials have a very short shelf life - the cloud builder is not intended to be up for longer than a few hours anyway).

If you're on a domain, you may need to enable use of saved credentials - by default, machines in a domain are prohibited from using saved credentials to RDP to servers that aren't on the same domain. However, by default, this is not *enforced* by Group Policy, so you can override it in the Local Group Policy Editor, or by importing a registry file like this:

    Windows Registry Editor Version 5.00

    [HKEY_CURRENT_USER\SOFTWARE\Microsoft\Windows\CurrentVersion\Group Policy Objects\{3A67DD42-347B-40D7-B9F0-E27948C54EC8}Machine\Software\Policies\Microsoft\Windows\CredentialsDelegation]
    "AllowSavedCredentials"=dword:00000001
    "ConcatenateDefaults_AllowSaved"=dword:00000001
    "AllowSavedCredentialsWhenNTLMOnly"=dword:00000001
    "ConcatenateDefaults_AllowSavedNTLMOnly"=dword:00000001

    [HKEY_CURRENT_USER\SOFTWARE\Microsoft\Windows\CurrentVersion\Group Policy Objects\{3A67DD42-347B-40D7-B9F0-E27948C54EC8}Machine\Software\Policies\Microsoft\Windows\CredentialsDelegation\AllowSavedCredentials]
    "1"="TERMSRV/*"

    [HKEY_CURRENT_USER\SOFTWARE\Microsoft\Windows\CurrentVersion\Group Policy Objects\{3A67DD42-347B-40D7-B9F0-E27948C54EC8}Machine\Software\Policies\Microsoft\Windows\CredentialsDelegation\AllowSavedCredentialsWhenNTLMOnly]
    "1"="TERMSRV/*"

Notes:

1.  The LGPE sets the same values in the registry as the .reg file does; they are two methods of accomplishing the exact same thing.
2.  You can prohibit this in a domain-wide Group Policy, in which case you'll have to either resove to copy/paste the password each time, or use a different RDP client that saves credentials differently (third party clients, and even RDCman, do not follow these settings).
3.  I'm not sure, but my guess is the GUID in the example .reg file below is static and does not change between Windows installs; if it does, then setting it with the LGPE is probably easier.
4.  These settings are specific to "Terminal Servers" aka RDP servers; if we want to use Powershell to remote into the cloud builder VM, I think we'd have to set some more options here.

## How it works

- `deploy.py` creates a resource group and deploys the `cloudbuilder.yaml` template to it
- In the template is a `CustomScriptExtention` that downloads the latest commit to this repository as a zip file on the builder VM, unpacks it, and executes the `deployInit.ps1` script from this directory
- That script configures the machine, including Hyper-V, packer, and everything else, and then starts building the packer images

## Notes on the cloudbuilder.yaml template

### YAML

JSON is a piece of shit format for configuration files, because there are no fucking comments and quoting is a nightmare. We write ours in YAML instead, and convert it to a Python dictionary - the same way `json.load()` would convert JSON to a Python dictionary - before passing it to the Azure SDK, and this works well.

### The CustomScriptExtension and its logs

As described above, we use a CustomScriptExtension to run commands after deployment. These commands will run any time the template is redeployed, not just the first time the VM is created.

The logging is a little weird, but it is available if you connect to the VM after its deployed. You can see some messages in Windows Event Viewer under `Applications and Services Logs\Microsoft\WindowsAzure\Status\Plugins`. From there, you can see that the results of commands are logged to files inside of `C:\Packages\Plugins\Microsoft.Compute.CustomScriptExtension\1.8`

### deployInit.ps1 logging

Our `deployInit.ps1` script logs to a separate place in the Event Log - `Applications and Services Logs\WinTrialLab`. As long as the CustomScriptExtension successfully runs that script, its logs should exist.
