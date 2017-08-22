#!/usr/bin/env python3

import argparse
import configparser
import datetime
import json
import logging
import os
import pdb
import secrets
import string
import sys
import textwrap
import urllib.request

import yaml

from azure.common.credentials import ServicePrincipalCredentials
from azure.mgmt.resource import ResourceManagementClient
from msrestazure.azure_exceptions import CloudError

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


def exresolvepath(path):
    rpath = resolvepath(path)
    if not os.path.exists(rpath):
        raise Exception(f"Path does not exist: '{rpath}'")
    return rpath


def genpass(length=24):
    """Generate a passphrase that will meet default Windows complexity reqs

    Is this like, a good idea? Idk, maybe not. I'm hoping that whatever is
    wrong with my algorithm is worked around by the length.
    """

    # Keep quotes out to make sure the password is easy to pass on the command line inside quotes
    symbols = r'!@#$%^&*(),.<>/?;:[]{}\|`~'
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


def homedir():
    for varname in ["HOME", "USERPROFILE"]:
        home = os.environ.get(varname)
        if home:
            log.info(f"Found homedir '{home}' from {varname} environment variable")
        return home
    raise Exception("Could not determine home directory - try setting a $HOME or %USERPROFILE% variable")


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
        vmadminuser,
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
            'builderVmAdminUsername': vmadminuser,
            'builderVmAdminPassword': vmadminpass,
            'builderVmSize': vmsize})
    }

    async_operation = resourceclient.deployments.create_or_update(
        groupname, deploymentname, deploy_params)

    # .result() blocks until the operation is complete
    return async_operation.result()


class ProcessedDeployConfig:
    """A class that can parse arguments and read from a config file

    Set a property on the object for each item in the dictionary
    """

    mastercfg = os.path.join(scriptdir, 'cloudbuilder.cfg')
    usercfg = os.path.join(homedir(), '.wintriallab.cloudbuilder.cfg')
    defaulttempl = os.path.join(scriptdir, 'cloudbuilder.yaml')

    def __init__(self, *args, **kwargs):

        parsed = self.parseargs(*args, **kwargs)

        # Weed out None values from the parsed arguments
        # I can't use (action='store_true') in my arg parser, because if the
        # option isn't passed, it is set to False. Since we override config file
        # parameters with options passed on the command line, this means that
        # 'store_true' options will override a True setting in the config file
        # if they aren't passed explicitly. So, instead I use
        # (action='store_const', const=True), which results in None for
        # unpassed arguments. All I do here is remove those None options.
        parseddict = {k: v for k, v in parsed.__dict__.items() if v is not None}

        # Grab configuration from default config files as well as the one passed
        # on the commandline (if present)
        configdict = self.parseconfig([parsed.configfile])

        # Combine the configs
        combinedconfig = {}
        combinedconfig.update(configdict)
        combinedconfig.update(parseddict)

        # Set the attributes of this object with the combined dict
        # This lets me do 'cfg = ProcessedDeployConfig(); print(cfg.opt_name)'
        for k, v in combinedconfig.items():
            setattr(self, k, v)

        # Apply the defaults and check for the required parameters.
        # I cannot do this in .add_argument(), since parameters may come in from
        # a config file instead.
        self.apply_runtime_defaults()
        self.check_required_params()

    def parseargs(self, *args, **kwargs):

        epilog = textwrap.dedent(f"""
            NOTES:

            1.  Many arguments are required, but any of them may come from a config file.

            2.  All arguments are represented in the config file with dashes replaced by
                underscores; for instance, the --builder-vm-admin-password argument
                corresponds to the builder_vm_admin_password entry in the config file.

            3.  See the config file in the same directory as this script for all options
                and a few notes

            4.  Config files are read in this order:

                1.  {self.mastercfg}
                2.  {self.usercfg}
                3.  Any config file passed on the command line with --config

                Any value in a later, existing config file will overwrite values from
                earlier config files.
            """)

        parser = argparse.ArgumentParser(
            epilog=epilog, add_help=True,
            formatter_class=argparse.RawDescriptionHelpFormatter)

        # Option parsing general notes
        # 1.  I can't use store_true. See comments in __init__() for why.
        #     Instead I use (action='store_const', const=True)

        # Options for the script itself
        parser.add_argument('--debug', '-d', action='store_const', const=True)
        parser.add_argument(
            '--configfile', '-c', type=exresolvepath,
            help="The path to a config file")
        parser.add_argument(
            '--showconfig', action='store_true',
            help="If passed, gather the arguments from the command line and config files, print the configuration, but exit before performing any action")

        # Options for all subcommands dealing with the YAML template
        templateopts = argparse.ArgumentParser(add_help=False)
        templateopts.add_argument('--arm-template', type=exresolvepath)

        # Options for all subcommands dealing with builder VM credentials
        buildvmcredopts = argparse.ArgumentParser(add_help=False)
        buildvmcredopts.add_argument('--builder-vm-admin-username')
        buildvmcredopts.add_argument('--builder-vm-admin-password')

        # Options for all subcommands dealing with Azure credentials
        azurecredopts = argparse.ArgumentParser(add_help=False)
        azurecredopts.add_argument('--service-principal-id')
        azurecredopts.add_argument('--service-principal-key')
        azurecredopts.add_argument('--tenant')
        azurecredopts.add_argument('--subscription-id')

        # Options for all subcommands dealing with the Azure resource group
        azurergopts = argparse.ArgumentParser(add_help=False)
        azurergopts.add_argument('--resource-group-name')

        # Options for the deploy subcommand
        deployopts = argparse.ArgumentParser(add_help=False)
        deployopts.add_argument('--deployment-name')
        deployopts.add_argument('--resource-group-location')
        deployopts.add_argument('--storage-account-name')
        deployopts.add_argument('--builder-vm-size')

        # Configure subcommands
        subparsers = parser.add_subparsers(dest="action")
        subparsers.add_parser(
            'convertyaml', parents=[templateopts],
            help='Convert the YAML template to JSON')
        subparsers.add_parser(
            'deploy',
            parents=[templateopts, buildvmcredopts, azurecredopts, azurergopts, deployopts],
            help='Deploy the ARM template to Azure')
        subparsers.add_parser(
            'delete', parents=[azurecredopts, azurergopts],
            help='Delete an Azure Resource Group')
        subparsers.add_parser(
            'testgroup', parents=[azurecredopts],
            help='Check if the resource group has been deployed')

        return parser.parse_args()

    def parseconfig(self, configs=[]):
        allconfigs = [cfg for cfg in [self.mastercfg, self.usercfg] + configs if cfg]
        configdict = {}
        config = configparser.ConfigParser()
        config.read(allconfigs)
        for k in config['DEFAULT'].keys():
            configdict[k] = config['DEFAULT'].get(k)

        # Munge dictionary values to be the right types
        def setboolval(dictionary, key):
            if key in dictionary.keys():
                boolval = False
                if dictionary[key] in ['true', 'True', 'yes', 'Yes', 1]:
                    boolval = True
                dictionary[key] = boolval

        setboolval(configdict, 'debug')

        return configdict

    def apply_runtime_defaults(self):
        """Apply defaults to some arguments

        Most argument defaults can be handled by setting them in the config
        file. However, some defaults are generated at runtime; these are set
        here.
        """

        def setifempty(obj, name, default):
            if not getattr(obj, name):
                setattr(obj, name, default)

        setifempty(self, 'builder_vm_admin_password', genpass())
        setifempty(self, 'arm_template', self.defaulttempl)

        datestamp = datetime.datetime.now().strftime('%Y-%d-%m-%H-%M-%S')
        setifempty(self, 'deployment_name', f'wintriallab-{datestamp}')

    def check_required_params(self):
        """Check the required parameters

        Ensure that all required parameters are passed either on the command
        line or as configuration values.configuration.

        (We can't just use required=True on .add_argument() because we also
        have to check whether it was in the config file(s).)
        """

        if not hasattr(self, 'action'):
            raise Exception("You must pass an 'action' parameter")
        elif self.action == 'convertyaml':
            required = ['arm_template']
        elif self.action == 'testgroup':
            required = [
                'service_principal_id', 'service_principal_key',
                'tenant', 'subscription_id',
                'resource_group_name']
        elif self.action == 'deploy':
            required = [
                'arm_template',
                'service_principal_id', 'service_principal_key',
                'tenant', 'subscription_id',
                'resource_group_name',
                'resource_group_location',
                'storage_account_name',
                'builder_vm_admin_username', 'builder_vm_admin_password',
                'builder_vm_size', 'deployment_name']
        elif self.action == 'delete':
            required = [
                'service_principal_id', 'service_principal_key',
                'tenant', 'subscription_id',
                'resource_group_name']
        else:
            raise Exception(f"I don't know how to handle an action of '{self.action}'")

        for parameter in required:
            if not hasattr(self, parameter):
                raise Exception(f"Missing parameter '{parameter}' was not passed on the command line or set as a configuration value")


def main(*args, **kwargs):
    config = ProcessedDeployConfig(args, kwargs)

    if config.debug:
        sys.excepthook = idb_excepthook
        log.setLevel(logging.DEBUG)

    if config.showconfig:
        print("PROCESSED CONFIGURATION: ")
        for k, v in config.__dict__.items():
            print(f"{k} = {v}")
        return 0

    with open(config.arm_template) as tf:
        template = yaml.load(tf)

    # First, handle actions that do NOT require talking to the API (fast)
    # Make sure you end each with 'return 0'!

    if config.action == 'convertyaml':
        jsonfile = config.arm_template.replace('.yaml', '.json')
        with open(jsonfile, 'w+') as jtf:
            jtf.write(json.dumps(template, indent=2))
        print("Converted template from YAML to JSON and saved to {jsontempl}")
        return 0

    # Now work with actions that do require talking to the API (blocking/slower)
    resource = ResourceManagementClient(
        ServicePrincipalCredentials(
            client_id=config.service_principal_id,
            secret=config.service_principal_key,
            tenant=tname2tid(config.tenant)),
        config.subscription_id)

    if config.action == 'testgroup':
        try:
            resource.resource_groups.get(config.resource_group_name)
            print(f"YES, the resource group '{config.resource_group_name}'' is deployed and costing you $$$")
        except CloudError as exp:
            if exp.status_code == 404:
                print(f"NO, the resource group '{config.resource_group_name}'' is not present")
            else:
                raise exp
    elif config.action == 'delete':
        resource.resource_groups.delete(config.resource_group_name).wait()
        print(f"Successfully deleted the {parsed.resource_group_name} resource group")
    elif config.action == 'deploy':
        result = deploytempl(
            resource, config.resource_group_name, config.resource_group_location,
            config.storage_account_name,
            config.builder_vm_admin_username, config.builder_vm_admin_password,
            config.builder_vm_size, template, config.deployment_name)
        conninfo = result.properties.outputs['builderConnectionInformation']
        print('Deployment completed. To connect, run connect.py on your Docker *host* machine (not within the container) like so:')
        print(f'connect.py {conninfo.IPAddress} {conninfo.Username} "{conninfo.Password}"')
    else:
        raise Exception(f"I don't know how to process an action called '{config.action}'")


if __name__ == '__main__':
    sys.exit(main(*sys.argv))
