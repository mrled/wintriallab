#!/usr/bin/env python3

import argparse
import glob
import logging
import os
import shutil
import subprocess
import sys


scriptdir = os.path.dirname(os.path.realpath(__file__))


def resolvepath(path):
    return os.path.realpath(os.path.normpath(os.path.expanduser(path)))


def buildpacker(packerfile, outdir, force=False, whatif=False):
    packerfile = resolvepath(packerfile)
    if not os.path.isfile(packerfile):
        raise Exception("No such packerfile: '{}'".format(packerfile))
    outdir = resolvepath(outdir)
    if not os.path.isdir(outdir):
        os.makedirs(outdir, exist_ok=True)

    logdir = os.path.join(outdir, "packer_log")
    cachedir = os.path.join(outdir, "packer_cache")
    packerdir = os.path.dirname(packerfile)

    oldoutputs = glob.glob("{}/output-*".format(packerdir))
    if len(oldoutputs) > 0:
        for oldoutput in oldoutputs:
            if force:
                shutil.rmtree(oldoutput)
            else:
                raise Exception("A packer output directory exists at '{}'".format(oldoutput))

    cli = 'packer.exe build -var output_directory="{}" {}'.format(outdir, packerfile)

    # NOTE: Packer gives a very weird error if you do not COPY the entire environment
    # When I was setting env to be just a dictionary with the PACKER_* variables I needed,
    # I was seeing errors like this:
    # Failed to initialize build 'virtualbox-iso': error initializing builder 'virtualbox-iso': Unrecognized remote plugin message: Error starting plugin server: Couldn't bind plugin TCP listener
    # Once I copied the entire environment, it was fine. I have no idea why.
    env = os.environ
    env['PACKER_CACHE_DIR'] = cachedir
    env['PACKER_DEBUG'] = '1'
    env['PACKER_LOG'] = '1'
    env['PACKER_LOG_PATH'] = logdir
    env['CHECKPOINT_DISABLE'] = '1'

    logging.info("Running command:\n    {}\n  from directory: {}\n  with environment:\n    {}".format(cli, packerdir, env))
    if whatif:
        return
    subprocess.check_call(cli, env=env, cwd=packerdir)

    boxes = glob.glob("{}/*.box".format(outdir))
    if len(boxes) > 1:
        raise Exception("Somehow you came up with more than one box here: '{}'".format(boxes))
    elif len(boxes) < 1:
        raise Exception("Apparently the packer process failed, no boxes were created")

    logging.info("Packed .box file: '{}'".format(boxes[0]))
    return boxes[0]


def addvagrantbox(vagrantboxname, packedboxpath, force, whatif):
    """Add the box to vagrant directly
    Note that doing it this way means that Vagrant doesn't know your box's version, and cannot upgrade it
    """
    packedboxdir = os.path.dirname(packedboxpath)
    packedboxname = os.path.basename(packedboxpath)

    forcearg = '--force' if force else ''
    cli = "vagrant.exe box add {} --name {} {}".format(forcearg, vagrantboxname, packedboxname)

    print("Running vagrant:\n    {}".format(cli))
    if whatif:
        return
    else:
        subprocess.check_call(cli, cwd=packedboxdir)


def main(*args, **kwargs):
    parser = argparse.ArgumentParser(
        description="Windows Trial Lab: build trial Vagrant boxes.",
        epilog="NOTE: requires packer 0.8.6 or higher and vagrant 1.8 or higher. EXAMPLE: buildlab --baseconfigname windows_10_x86; cd vagrant/FreyjaA; vagrant up")

    parser.add_argument(
        "baseconfigname", action='store',
        help="The name of one of the subdirs of the 'packer' directory, like windows_81_x86")

    parser.add_argument(
        "--base-out-dir", "-o", action='store', default="{}/output".format(scriptdir),
        help="The base output directory, where Packer does its work and saves its final output. (NOT the VM directory, which is a setting in VirtualBox.)")
    parser.add_argument(
        "--action", "-a", action='store', default="packervagrant",
        choices=['packer', 'vagrant', 'packervagrant'],
        help="The action to perform. By default, build with packer and add to vagrant.")
    parser.add_argument(
        "--whatif", "-w", action='store_true',
        help="Do not perform any actions, only say what would have been done")
    parser.add_argument(
        "--force", "-f", action='store_true',
        help="Force continue, even if old output directories already exist")
    parser.add_argument(
        "--verbose", "-v", action='store_true',
        help="Print verbose messages")

    parsed = parser.parse_args()
    if parsed.verbose:
        logging.basicConfig(level=logging.DEBUG)
    fullconfigname = "wintriallab-{}".format(parsed.baseconfigname)
    packeroutdir = os.path.join(resolvepath(parsed.base_out_dir), fullconfigname)
    packerfile = os.path.join(scriptdir, 'packer', parsed.baseconfigname, '{}_packerfile.json'.format(parsed.baseconfigname))

    if 'packer' in parsed.action:
        buildpacker(packerfile, packeroutdir, force=parsed.force, whatif=parsed.whatif)

    packedboxpath = glob.glob("{}/{}_*_virtualbox.box".format(packeroutdir, parsed.baseconfigname))[0]

    if 'vagrant' in parsed.action:
        addvagrantbox(fullconfigname, packedboxpath, force=parsed.force, whatif=parsed.whatif)


if __name__ == '__main__':
    sys.exit(main(*sys.argv))
