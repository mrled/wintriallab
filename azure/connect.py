import argparse
import collections
import logging
import subprocess
import sys


def getlogger(name='deploy-wintriallab-cloud-builder'):
    log = logging.getLogger(name)
    log.setLevel(logging.WARNING)
    conhandler = logging.StreamHandler()
    conhandler.setFormatter(logging.Formatter('%(levelname)s: %(message)s'))
    log.addHandler(conhandler)
    return log


log = getlogger()


def rdp_win(server, username, password):
    """Connect to a server using Remote Desktop on Windows"""

    def cmdkey(arguments):
        """Run cmdkey.exe

        For some reason I can't get this command to run successfully unless I
        wrap it in Powershell's Start-Process cmdlet
        """
        def quotify(s):  # Wrap a string in double quotes
            return f'"{s}"'
        if isinstance(arguments, str) or not isinstance(arguments, collections.Iterable):
            arguments = [arguments]
        arglist = ",".join(map(quotify, arguments))
        cmdlet = f'Start-Process -Wait -NoNewWindow -FilePath cmdkey.exe -ArgumentList @( {arglist} )'
        command = ['powershell.exe', '-NoProfile', '-Command', cmdlet]
        log.info("Running cmdkey: " + ' '.join(command))
        out = subprocess.check_output(command).decode().strip()
        log.info(out)
        return out

    entryname = f'LegacyGeneric:target={server}'

    cmdkey([
        f'/generic:{entryname}',
        f'/user:{username}',
        f'/pass:{password}'])
    try:
        mstsccmd = ['mstsc.exe', f'/v:{server}']
        log.info("Running command: " + ' '.join(mstsccmd))
        out = subprocess.check_output(mstsccmd).decode().strip()
        if out:
            log.info(out)
    finally:
        cmdkey(f'/delete:{entryname}')


def main(*args, **kwargs):
    parser = argparse.ArgumentParser()
    parser.add_argument('--verbose', '-v', action='store_true')
    parser.add_argument('hostname', help='Remote host')
    parser.add_argument('username', help='Remote username')
    parser.add_argument('password', help='Remote password')
    parsed = parser.parse_args()

    if parsed.verbose:
        log.setLevel(logging.DEBUG)

    rdp_win(parsed.hostname, parsed.username, parsed.password)


if __name__ == '__main__':
    sys.exit(main(*sys.argv))
