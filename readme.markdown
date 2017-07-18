Windows Trial Lab: Build Vagrant boxes from Windows trial ISOs

## Prerequisites

- A hypervisor (VirtualBox or Hyper-V currently)
- Packer
- [Caryatid](https://github.com/mrled/caryatid), a Packer plugin
- Vagrant

Everything is intended to work from Windows or Unix hosts

## Status

- vbox win10 32bit: working
- hyperv win10 32bit: broken
- vbox win10 64bit: unimplemented
- hyperv win10 64bit: unimplemented
- vbox server2016 64bit: unimplemented
- hyperv server2016 64bit: working, with caveats

## Usage

1. Change directory to one of the packer builder directories, e.g. `cd packer/wintriallab-win10-32`
2. Examine the `variables` section of the packerfile, especially `boxname`, `version`, and `catalog_root_url`
3. Run packer for whatever hypervisor you are using, and optionally supplying an override value for some variables, e.g. `packer -only=virtualbox-iso -var catalog_root_url=$HOME/Vagrant -var version=0.0.1`
4. When this finishes, your `catalog_root_url` will have a file name `<BOXNAME>.json`. You can use a `file://` URL to that catalog as the value for `box_url` in a `Vagrantfile`, and Vagrant will notice when you publish new versions of the box. (See [Caryatid](https://github.com/mrled/caryatid)'s documentation for more information.)

There are some Vagrant boxes in the `vagrant` directory. They are intended as examples and are not guaranteed to work or remain stable over time.

## More information

See [the docs folder](https://github.com/mrled/wintriallab/blob/master/docs) for more detailed information on:

- [Hyper-V](https://github.com/mrled/wintriallab/blob/master/docs/hyperv.markdown) details issues with Hyper-V
- [Our to do list](https://github.com/mrled/wintriallab/blob/master/docs/todo.markdown) is long
- [Development notes](https://github.com/mrled/wintriallab/blob/master/docs/devnotes.markdown) are quick notes about problems we've seen and how we have worked around them
- [Credits](https://github.com/mrled/wintriallab/blob/master/docs/credits.markdown) list places we've stolen ideas and code from
