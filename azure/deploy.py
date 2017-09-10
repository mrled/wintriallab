#!/usr/bin/env python3

import argparse
import copy
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
import time
import urllib.request

import requests
import yaml

import adal
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


def genpass(length=24):
    """Generate a passphrase that will meet default Windows complexity reqs

    Is this like, a good idea? Idk, maybe not. I'm hoping that whatever is
    wrong with my algorithm is worked around by the length and mitigated by the
    short length of time this machine should be up.

    ¡¡ More thought required for other scenarios !!
    """

    # This list is restricted to characters that don't require escaping on the
    # command line for sh, cmd, or PowerShell shells so that it's easy to copy
    # and paste.
    alphabet = string.ascii_letters + string.digits

    def testwinpass(password):
        """Test whether a password will meet default Windows complexity reqs"""
        return (
            any(c.islower() for c in password) and
            any(c.isupper() for c in password) and
            any(c.isdigit() for c in password))

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


class QualifiedPath:
    """Fully qualify a path"""

    def __init__(self, path):
        self.path = self.resolve(path)

    def __repr__(self):
        return self.path

    @classmethod
    def resolve(cls, path):
        os.path.realpath(os.path.normpath(os.path.expanduser(path)))

    @classmethod
    def Resolved(self, mustexist=False):
        """Return a function that resolves a path, optionally requiring it to exist

        Intended for use as a type= argument for arguments from argparse. For
        example:
            parser.add_argument(
                '-p', type=QualifiedPath.Resolved(mustexist=True))
        """
        def r(path):
            p = QualifiedPath(path)
            if mustexist and not os.path.exists(p):
                raise Exception(f'Path at "{p}" does not exist')
            return p
        return r


class ComposableUri:
    """A URI with changeable components

    I wanted to use urllib.parse.ParseResult, but that class has made all its
    attributes read only (...why?)
    """

    def __init__(
            self,
            scheme,
            netloc,
            path=[],
            query={},
            fragment=''):
        self.scheme = scheme
        self.netloc = netloc
        self.path = path
        self.query = query
        self.fragment = fragment

    @property
    def uri(self):
        q = '?' + urllib.encode(self.query) if self.query else ""
        p = '/' + '/'.join(self.path)
        f = '#' + self.fragment if self.fragment else ""
        uri = f'{self.scheme}://{self.netloc}{p}{q}{f}'
        log.debug(f'Composed URI "{uri}"')
        return uri


class AzureLogAnalyticsClient:
    """Interact with the Azure web API for log analytics

    Adapted from
    https://docs.microsoft.com/en-us/azure/log-analytics/log-analytics-log-search-api-python
    """

    def __init__(
            self,
            subscription_id,
            tenant_id,
            application_id,
            application_key,
            resource_group,
            workspace_name):

        self.authcontext = adal.AuthenticationContext(
            'https://login.microsoftonline.com/' + tenant_id)
        self.application_id = application_id
        self.application_key = application_key

        # self.endpoint = f'https://management.azure.com/subscriptions/{subscription_id}/resourcegroups/{self.resource_group}/providers/Microsoft.OperationalInsights/workspaces/{self.workspace_name}/search'
        self.endpoint = ComposableUri(
            'https', 'management.azure.com',
            path=[
                'subscriptions', subscription_id,
                'resourcegroups', resource_group,
                'providers', 'Microsoft.OperationalInsights',
                'workspaces', workspace_name,
                'search'
            ],
            query={'api-version': '2015-11-01-preview'})

    @property
    def access_token(self):
        """Get an access token from the authentication context API

        Not clear how long this lasts, so I made it get a new one for each
        query... if it lasts long enough, consider refactoring to just get set
        in the constructor.
        """
        token_response = self.authcontext.acquire_token_with_client_credentials(
            'https://management.core.windows.net/',
            self.application_id, self.application_key)
        return token_response.get('accessToken')

    def query(
            self,
            query,
            num_results=100,
            end_time=datetime.datetime.utcnow(),
            start_time=None):
        """Run a query against the web API

        query:          A query string
        num_results:    Number of results to return
        start_time:     Find events no earlier than this
                        If unset, default to 24 hours before end_time
        end_time:       Find events no later than this
        """

        # Unfortunately, you cannot set a parameter based on the value from
        # another parameter, so we set the default here
        if not start_time:
            start_time = end_time - datetime.timedelta(hours=24)

        headers = {
            "Authorization": 'Bearer ' + self.access_token,
            "Content-Type": 'application/json'}

        dateformat = '%Y-%m-%dT%H:%M:%S'
        search_params = {
            "query": query,
            # Note: if top is not passed, Azure only returns 10 results at once
            "top": num_results,
            "start": start_time.strftime(dateformat),
            "end": end_time.strftime(dateformat)}

        response = requests.post(
            self.endpoint.uri, json=search_params, headers=headers)
        log.debug(f"Posted initial search request. Response: '{response}'")

        if response.status_code == 200:
            data = response.json()
            search_id = data["id"].split("/")[-1]
            results_endpoint = copy.deepcopy(self.endpoint)
            results_endpoint.path.append(search_id)

            while data["__metadata"]["Status"] == "Pending":
                log.debug(f"Search request '{search_id}' pending...")
                response = requests.get(results_endpoint.uri, headers=headers)
                data = response.json()
                time.sleep(1)
        else:
            # Request failed
            log.info(response.status_code)
            response.raise_for_status()

        log.verbose(textwrap.dedent("""
            Search request successful!
            Total records:" + str(data["__metadata"]["total"]))
            Returned top:" + str(data["__metadata"]["top"]))
            Value:
            {data["value"]}
            """))
        return data["value"]


class WinTrialLabAzureWrapper:
    """Wrap generic Azure API methods for WinTrialLab"""

    _tenant_id = None
    _armclient = None
    _loganalytics = None

    def __init__(
            self,
            service_principal_id,
            service_principal_key,
            tenant_name,
            subscription_id,
            resource_group_name,
            opinsights_workspace_name):
        self.service_principal_id = service_principal_id
        self.service_principal_key = service_principal_key
        self.tenant_name = tenant_name
        self.subscription_id = subscription_id
        self.resource_group_name = resource_group_name
        self.opinsights_workspace_name = opinsights_workspace_name

    @classmethod
    def tname2tid(cls, name):
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

    @classmethod
    def templparam(cls, indict):
        """Create a template parameter object from a Python dict

        For some reason, ARM template parameters require weird objects. Sorry.

        indict:  a python dict like {'k1': 'v1', 'k2': 'v2'}
        """
        return {k: {'value': v} for k, v in indict.items()}

    @property
    def tenant_id(self):
        """A lazily-loaded tenant id, based on the tenant name"""
        if not self._tenant_id:
            self._tenant_id = self.tname2tid(self.tenant_name)
        return self._tenant_id

    @property
    def armclient(self):
        """A lazily-loaded authenticated ResourceManagementClient

        Lets us create the WinTrialLabAzureWrapper object without blocking until
        the API calls to authenticate complete; this way, those API calls
        aren't started until we want to actually use them.
        """
        if not self._armclient:
            self._armclient = ResourceManagementClient(
                ServicePrincipalCredentials(
                    client_id=self.service_principal_id,
                    secret=self.service_principal_key,
                    tenant=self.tenant_id),
                self.subscription_id)
        return self._armclient

    @property
    def loganalytics(self):
        if not self._loganalytics:
            self._loganalytics = AzureLogAnalyticsClient(
                self.subscription_id, self.tenant_id, self.application_id,
                self.application_key, self.resource_group_name,
                self.opinsights_workspace_name)
        return self._loganalytics

    def testdeployed(self, name):
        """Test whether a resource group exists"""
        try:
            self.armclient.resource_groups.get(name)
            return True
        except CloudError as exp:
            if exp.status_code == 404:
                return False
            else:
                raise exp

    def deletegroup(self, name):
        """Delete a resource group if it exists"""
        if self.testdeployed(name):
            self.armclient.resource_groups.delete(name).wait()
            log.info(f"Successfully deleted the {name} resource group")
        else:
            log.info(f"The {name} resource group did not exist")

    def deploytempl(
            self,
            groupname,
            grouplocation,
            template,
            parameters,
            deploymentname,
            deploymode='incremental',
            deletefirst=False,
            validate=False):
        """Deploy a cloud builder template

        groupname:      the name of the resource group
        grouplocation:  th location for the resource group
        template:       a dict containing the ARM template
                        (perhaps created via json.load())
        parameters:     a dict containing template parameters
        deploymentname: the name for this deployment
        deploymode:     the Azure RM deployment mode
        deletefirst:    if True, delete the resource group before deploying
        validate:       if True, do not deploy the template, but return whether
                        it would deploy
        """

        if deletefirst:
            self.deletegroup(groupname)

        result = self.armclient.resource_groups.create_or_update(
            groupname, {'location': grouplocation})
        log.info(f"Azure resource group: {result}")

        deploy_params = {
            'mode': deploymode,
            'template': template,
            'parameters': self.templparam(parameters)}

        if validate:
            self.armclient.deployments.validate(
                groupname, deploymentname, deploy_params)
        else:
            async_operation = self.armclient.deployments.create_or_update(
                groupname, deploymentname, deploy_params)
            # .result() blocks until the operation is complete
            result = async_operation.result()
            return result.properties.outputs


class ProcessedDeployConfig:
    """A class that can parse arguments and read from a config file

    Set a property on the object for each item in the dictionary
    """

    mastercfg = os.path.join(scriptdir, 'cloudbuilder.cfg')
    usercfg = os.path.join(homedir(), '.wintriallab.cloudbuilder.cfg')
    defaulttempl = os.path.join(scriptdir, 'cloudbuilder.yaml')

    # Set a key name and a type value
    # 'get' + the type value must be a valid ConfigParser getter
    # For instance, a value type of 'boolean' will call 'config.getboolean()'
    # Any types not included here are assumed to be strings
    config_value_types = {
        'debug': 'boolean',
        'delete': 'boolean',
        'pass_length': 'int'}

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
            5.  Any value in a later, existing config file will override values from
                earlier config files, and arguments passed on the command line will
                override values from all config files.
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
            '--configfile', '-c',
            type=QualifiedPath.Resolved(mustexist=True),
            help="The path to a config file")
        parser.add_argument(
            '--showconfig', action='store_true',
            help="If passed, gather the arguments from the command line and config files, print the configuration, but exit before performing any action")

        # Options for all subcommands dealing with the YAML template
        templateopts = argparse.ArgumentParser(add_help=False)
        templateopts.add_argument(
            '--arm-template', type=QualifiedPath.Resolved(mustexist=True))

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
        deployopts.add_argument('--opinsights-workspace-name')
        deployopts.add_argument('--builder-vm-size')
        deployopts.add_argument(
            '--delete', action='store_true',
            help="If the resource group already exists, delete it before starting the deployment.")

        # Options for the log subcommand
        logopts = argparse.ArgumentParser(add_help=False)
        logopts.add_argument('--query')

        # Options for the genpass subcommand
        genpassopts = argparse.ArgumentParser(add_help=False)
        genpassopts.add_argument(
            '--pass-length', default=24, type=int,
            help='Length of the passphrase to generate.')

        # Configure subcommands
        subparsers = parser.add_subparsers(dest="action")
        subparsers.add_parser(
            'convertyaml', parents=[templateopts],
            help='Convert the YAML template to JSON')
        subparsers.add_parser(
            'deploy',
            parents=[templateopts, buildvmcredopts, azurecredopts, azurergopts, deployopts, genpassopts],
            help='Deploy the ARM template to Azure')
        subparsers.add_parser(
            'validate',
            parents=[templateopts, buildvmcredopts, azurecredopts, azurergopts, deployopts],
            help='Validate the ARM template')
        subparsers.add_parser(
            'delete', parents=[azurecredopts, azurergopts],
            help='Delete an Azure Resource Group')
        subparsers.add_parser(
            'testgroup', parents=[azurecredopts],
            help='Check if the resource group has been deployed')
        subparsers.add_parser(
            'log', parents=[azurecredopts, azurergopts, logopts],
            help='Query the Azure Operational Insights log analytics service')
        subparsers.add_parser(
            'genpass', parents=[genpassopts], help='Generate a passphrase')

        return parser.parse_args()

    def parseconfig(self, configs=[]):
        allconfigs = [cfg for cfg in [self.mastercfg, self.usercfg] + configs if cfg]
        configdict = {}
        config = configparser.ConfigParser()
        config.read(allconfigs)

        for k in config['DEFAULT'].keys():
            if k in self.config_value_types:
                getvalue = getattr(config['DEFAULT'], 'get' + self.config_value_types[k])
            else:
                getvalue = getattr(config['DEFAULT'], 'get')
            configdict[k] = getvalue(k)

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

        datestamp = datetime.datetime.now().strftime('%Y-%d-%m-%H-%M-%S')
        setifempty(self, 'builder_vm_admin_password', genpass(self.pass_length))
        setifempty(self, 'arm_template', self.defaulttempl)
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
                'service_principal_id',
                'service_principal_key',
                'tenant',
                'subscription_id',
                'resource_group_name']
        elif self.action == 'deploy' or self.action == 'validate':
            required = [
                'arm_template',
                'service_principal_id',
                'service_principal_key',
                'tenant',
                'subscription_id',
                'resource_group_name',
                'resource_group_location',
                'storage_account_name',
                'opinsights_workspace_name',
                'builder_vm_admin_username',
                'builder_vm_admin_password',
                'builder_vm_size',
                'deployment_name']
        elif self.action == 'delete':
            required = [
                'service_principal_id',
                'service_principal_key',
                'tenant',
                'subscription_id',
                'resource_group_name']
        elif self.action == 'log':
            required = [
                'service_principal_id',
                'service_principal_key',
                'tenant',
                'subscription_id',
                'resource_group_name',
                'resource_group_location',
                'storage_account_name',
                'opinsights_workspace_name',
                'builder_vm_admin_username',
                'builder_vm_admin_password',
                'builder_vm_size',
                'query']
        elif self.action == 'genpass':
            required = ['pass_length']
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
        msg = "PROCESSED CONFIGURATION:\n"
        for k, v in config.__dict__.items():
            msg += f"{k} = {v}\n"
        log.info(msg)
        return 0

    wtlazwrapper = WinTrialLabAzureWrapper(
        config.service_principal_id,
        config.service_principal_key,
        config.tenant,
        config.subscription_id,
        config.resource_group_name,
        config.opinsights_workspace_name)

    with open(config.arm_template) as tf:
        # Convert to JSON first to ensure that the template we see from
        # convertyaml is exactly what Azure sees
        json_template = json.dumps(yaml.load(tf), indent=2)
        template = json.loads(json_template)

    def save_json_template(
            dictionary=json_template,
            jsonfile=config.arm_template.replace('.yaml', '.json')):
        with open(jsonfile, 'w+') as jtf:
            jtf.write(dictionary)
        log.info(f"Converted template from YAML to JSON and saved to {jsonfile}")

    if config.debug:
        save_json_template()

    if config.action == 'convertyaml':
        save_json_template()

    elif config.action == 'genpass':
        log.info(f"Generated passphrase: {genpass(config.pass_length)}")

    elif config.action == 'testgroup':
        if wtlazwrapper.testdeployed(config.resource_group_name):
            log.info(f"YES, the resource group '{config.resource_group_name}' is deployed and costing you $$$")
        else:
            log.info(f"NO, the resource group '{config.resource_group_name}' is not present")

    elif config.action == 'delete':
        wtlazwrapper.deletegroup(config.resource_group_name)
        log.info(f"Deleted resource group '{config.resource_group_name}'")

    elif config.action == 'deploy' or config.action == 'validate':
        log.info(f"Using builder VM password '{config.builder_vm_admin_password}'")
        outputs = wtlazwrapper.deploytempl(
            config.resource_group_name,
            config.resource_group_location,
            template,
            {
                'storageAccountName':       config.storage_account_name,
                'opInsightsWorkspaceName':  config.opinsights_workspace_name,
                'builderVmAdminUsername':   config.builder_vm_admin_username,
                'builderVmAdminPassword':   config.builder_vm_admin_password,
                'builderVmSize':            config.builder_vm_size},
            config.deployment_name,
            deletefirst=config.delete,
            validate=(config.action == 'validate'))

        conninfo = outputs['builderConnectionInformation']['value']
        msg = "Deployment completed. To connect, run connect.py on your Docker *host* machine (not within the container) like so:"
        msg += f"connect.py {conninfo['IPAddress']} {conninfo['Username']} '{conninfo['Password']}'"
        log.info(msg)
    elif config.action == 'log':
        log.info(wtlazwrapper.loganalytics.query(config.query))
    else:
        raise Exception(f"I don't know how to process an action called '{config.action}'")


if __name__ == '__main__':
    sys.exit(main(*sys.argv))
