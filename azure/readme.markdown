# Cloud Builder

Using Microsoft's 2017 support for nested virtualization in Azure, build WinTrialLab images in the clerd.

## Deploying

Run the `deploy.py` script. There are several required arguments; run `./deploy.py --help` to see what arguments it accepts.

`deploy.py` is designed to frontend the whole template deployment process; it includes creating the resource group (something that must be done prior to deploying an ARM template), reading the template, and passing parameters to it. Using the Azure CLI is not required.

## Authenticating with Azure

Create a service principal account. Follow [these instructions](https://docs.microsoft.com/en-us/azure/azure-resource-manager/resource-group-create-service-principal-portal) to create the account, create a key for that account, and then assign it the `Contributor` role. Note the ID of the application you created to pass as `--service-principal-id` (this will be a GUID), the secret key value you created to pass as `--service-principal-key` (this will look like Base64 data), and your tenant ID to pass as `--tenant-id` (this will look like `example.onmicrosoft.com`).

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
