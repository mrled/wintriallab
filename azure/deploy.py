#!/usr/bin/env python3

import argparse
import json
import logging
import os
import pdb
import secrets
import string
import sys
import urllib.request

import yaml

from azure.common.credentials import ServicePrincipalCredentials
from azure.mgmt.resource import ResourceManagementClient


scriptdir = os.path.dirname(os.path.realpath(__file__))


def getlogger(name='deploy-wintriallab-cloud-builder'):
    log = logging.getLogger(name)
    log.setLevel(logging.WARNING)
    conhandler = logging.StreamHandler()
    conhandler.setFormatter(logging.Formatter('%(levelname)s: %(message)s'))
    log.addHandler(conhandler)
    return log


log = getlogger()


strace = pdb.set_trace


def idb_excepthook(type, value, tb):
    """Call an interactive debugger in post-mortem mode

    If you do "sys.excepthook = idb_excepthook", then an interactive debugger
    will be spawned at an unhandled exception
    """
    if hasattr(sys, 'ps1') or not sys.stderr.isatty():
        # we are in interactive mode or we don't have a tty-like
        # device, so we call the default hook
        sys.__excepthook__(type, value, tb)
    else:
        import traceback
        # we are NOT in interactive mode, print the exception...
        traceback.print_exception(type, value, tb)
        print
        # ...then start the debugger in post-mortem mode.
        pdb.pm()


def resolvepath(path):
    return os.path.realpath(os.path.normpath(os.path.expanduser(path)))


def genpass(length=24):
    """Generate a passphrase that will meet default Windows complexity reqs

    Is this like, a good idea? Idk, maybe not. I'm hoping that whatever is
    wrong with my algorithm is worked around by the length.
    """

    symbols = '!@#$%^&*()'
    alphabet = string.ascii_letters + string.digits + symbols

    def testwinpass(password):
        """Test whether a password will meet default Windows complexity reqs"""
        return (
            any(c.islower() for c in password) and
            any(c.isupper() for c in password) and
            any(c.isdigit() for c in password) and
            any(c in symbols for c in password))

    while True:
        password = ''.join(secrets.choice(alphabet) for i in range(length))
        if testwinpass(password):
            return password


def tname2tid(name):
    """Convert a tenant name to a tenant ID

    Use the unauthenticated Azure public API - no credentials required

    name: The name of the tenant, like example.onmicrosoft.com
    """
    log.info(f"Attempting to obtain tenant ID from the {name} Azure tenant...")
    # This can be done with a simple unauthenticated call to the Azure API
    # We obtain it from the "token endpoint", also called the STS URL
    oidcfg_url = f'https://login.windows.net/{name}/.well-known/openid-configuration'
    oidcfg = json.loads(urllib.request.urlopen(oidcfg_url).read().decode())
    tenant_id = oidcfg['token_endpoint'].split('/')[3]
    log.info(f"Found a tenant ID of {tenant_id}")
    return tenant_id


def deploytempl(
        resourceclient,
        groupname,
        grouplocation,
        storageacct,
        vmadminpass,
        vmsize,
        template,
        deploymentname,
        deploymode='incremental'):
    """Deploy the YAML cloud builder template

    resourceclient: an authenticated ResourceManagementClient instance
    groupname:      the name of the resource group
    grouplocation:  the location for the resource group
    storageacct:    the name of the storage account
    vmadminpass:    a password to use for the cloud builder VM
    vmsize:         the size of the cloud builder VM
    template:       the path to the ARM template
    deploymentname: a name for this deployment
    deploymode:     the Azure RM deployment mode
    """

    result = resourceclient.resource_groups.create_or_update(
        groupname, {'location': grouplocation})
    log.info(f"Azure resource group: {result}")

    # For some reason, ARM template parameters require weird objects. Sorry.
    # The indict argument is a python dict like {'k1': 'v1', 'k2': 'v2'}
    def templparam(indict):
        return {k: {'value': v} for k, v in indict.items()}

    deploy_params = {
        'mode': deploymode,
        'template': template,
        'parameters': templparam({
            'storageAccountName': storageacct,
            'builderVmAdminPassword': vmadminpass,
            'builderVmSize': vmsize})
    }

    async_operation = resourceclient.deployments.create_or_update(
        groupname, deploymentname, deploy_params)

    # .result() blocks until the operation is complete
    return async_operation.result()


def parseargs(*args, **kwargs):
    parser = argparse.ArgumentParser()
    parser.add_argument(
        'action', choices=['deploy', 'delete', 'convertyaml'],
        help='Action to perform. Either deploy the ARM template to the resource group, delete the entire resource group, or convert the ARM template from YAML to JSON (for debugging purposes).')
    parser.add_argument(
        '--debug', '-d', action='store_true',
        help="Show debug messages")
    parser.add_argument(
        '--deployment-name', default='wintriallab',
        help="Deployment name")
    parser.add_argument(
        '--group-name', default="wintriallab",
        help="Azure Resource Group name")
    parser.add_argument(
        '--arm-template', type=resolvepath,
        default=os.path.join(scriptdir, 'cloudbuilder.yaml'),
        help="Location of the ARM template")
    parser.add_argument(
        '--group-location', default='westus2',
        help="The resource group location. Note that only a few resource groups support the types of VMs we require; see also https://azure.microsoft.com/en-us/blog/introducing-the-new-dv3-and-ev3-vm-sizes/")
    parser.add_argument(
        '--storage-account-name', required=True,
        help="A name for a new storage account. Note that this must follow Microsoft's rules for DNS hostnames, which are more restrictive than the DNS spec.")
    parser.add_argument(
        '--service-principal-id', required=True,
        help="The ID (GUID) of the service princiapl to use")
    parser.add_argument(
        '--service-principal-key', required=True,
        help="The secret key for the service principal to use")
    parser.add_argument(
        '--tenant', required=True,
        help="The Azure Active Directory tenant (e.g. example.onmicrosoft.com)")
    parser.add_argument(
        '--subscription-id', required=True,
        help="The Azure subscription ID (GUID)")
    parser.add_argument(
        '--builder-vm-admin-password', default=genpass(),
        help="The admin password for the builder VM")
    parser.add_argument(
        '--builder-vm-size', default='Standard_D2_v3',
        help="The size of the builder VM. Note that only Standard Dv3 and Standard Ev3 VMs support the nested virtualization that we need for the cloud boilder.")
    parsed = parser.parse_args()
    return parsed


def main(*args, **kwargs):
    parsed = parseargs(args, kwargs)
    if parsed.debug:
        sys.excepthook = idb_excepthook
        parsed.save_json_template = True
        log.setLevel(logging.DEBUG)

    with open(parsed.arm_template) as tf:
        template = yaml.load(tf)

    # First, handle actions that do NOT require talking to the API (fast)
    if parsed.action == 'convertyaml':
        jsonfile = parsed.arm_template.replace('.yaml', '.json')
        with open(jsonfile, 'w+') as jtf:
            jtf.write(json.dumps(template, indent=2))
        print("Converted template from YAML to JSON and saved to {jsontempl}")
        return 0

    # Now work with actions that do require talking to the API (blocking/slower)
    resource = ResourceManagementClient(
        ServicePrincipalCredentials(
            client_id=parsed.service_principal_id,
            secret=parsed.service_principal_key,
            tenant=tname2tid(parsed.tenant)),
        parsed.subscription_id)

    if parsed.action == 'delete':
        resource.resource_groups.delete(parsed.group_name).wait()
        print(f"Successfully deleted the {parsed.group_name} resource group")

    elif parsed.action == 'deploy':
        result = deploytempl(
            resource, parsed.group_name, parsed.group_location,
            parsed.storage_account_name, parsed.builder_vm_admin_password,
            parsed.builder_vm_size, template, parsed.deployment_name)
        msg = "Deployment completed. Outputs:"
        for k, v in result.properties.outputs.items():
            msg += f"\n- {k} = {str(v['value'])}"
        print(msg)


if __name__ == '__main__':
    sys.exit(main(*sys.argv))
