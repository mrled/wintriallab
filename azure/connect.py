#!/usr/bin/env python3

import argparse
import collections
import logging
import re
import subprocess
import sys


def getlogger(name='wintriallab-cloud-builder-connector'):
    log = logging.getLogger(name)
    log.setLevel(logging.WARNING)
    conhandler = logging.StreamHandler()
    conhandler.setFormatter(logging.Formatter('%(levelname)s: %(message)s'))
    log.addHandler(conhandler)
    return log


log = getlogger()


def rdp_win(server, username, password):
    """Connect to a server using Remote Desktop on Windows

    There's no way to pass username/password to mstsc.exe, but we can save the
    credentials to the system using cmdkey.exe. This function saves the creds,
    attempts to connect, and removes the creds afterwards.
    """

    def cmdkey(arguments):
        """Run cmdkey.exe

        For some reason I can't get this command to run successfully unless I
        wrap it in Powershell's Start-Process cmdlet. Even cmd /c was failing.
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


def rfc_1738_encode(text):
    """Encode username/password for use in URLs

    Example: A password of 'b@d:/st%ff' becomes 'b%40d%3A%2Fst%25ff' after
    encoding. Note that this is different from URL encoding e.g. '/some path/'
    to '/some%20path'.

    Via https://www.metabrite.com/devblog/posts/python-obfuscate-url-password/
    """
    def replacement(match):
        return "%%%X" % ord(match.group(0))
    return re.sub(r'[:@/%]', replacement, text)


def cord_mac(server, username, password):
    """Connect to a server using CoRD on macOS

    Like Remote Desktop Connection for Windows, there's no way to pass a
    username/password on the command line. Unlike RDC for Windows, there's not
    a good cmdkey.exe equivalent either. RDC appears to use the macOS Keychain,
    which could work in theory, but would require the keychain password every
    time.

    Instead we use CoRD, a third party Remote Desktop client for macOS.
    """

    # This didn't work for me - it doesn't seem to be able to handle the password propertly
    # rdpuri = f'rdp://{rfc_1738_encode(username)}:{rfc_1738_encode(password)}@{server}'
    # print(f"Connecting to {rdpuri}")
    # subprocess.check_output(['open', '-a', '/Applications/CoRD.app', rdpuri])

    subprocess.check_output([
        '/Applications/CoRD.app/Contents/MacOS/CoRD', '-host', server,
        '-u', username, '-p', password])


def main(*args, **kwargs):
    parser = argparse.ArgumentParser()
    parser.add_argument('--verbose', '-v', action='store_true')
    parser.add_argument('hostname', help='Remote host')
    parser.add_argument('username', help='Remote username')
    parser.add_argument('password', help='Remote password')
    parsed = parser.parse_args()

    if parsed.verbose:
        log.setLevel(logging.DEBUG)

    if sys.platform == "win32":
        rdp_win(parsed.hostname, parsed.username, parsed.password)
    elif sys.platform == "darwin":
        cord_mac(parsed.hostname, parsed.username, parsed.password)
    else:
        raise Exception(
            f"No RDP connector configured for platform '{sys.platform}'")


if __name__ == '__main__':
    sys.exit(main(*sys.argv))
