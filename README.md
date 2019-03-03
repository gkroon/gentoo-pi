# Script to install Gentoo on a Raspberry Pi 2/3
This script fetches an armv7a hardfp stage3 tarball, verifies its authenticity (GPG and hashes) and installs it on your card. It then configures the new installation to properly boot, set the correct timezone, and copies your SSH key. It then copies two extra scripts for you to run manually once succefully booted and logged into root to finish the installation.

## Full disclosure
I'm not a developer by any means, and you may find this repository a comical attempt to automate installing Gentoo on a Raspberry Pi 2/3. And you're probably right, so feel free to:

1. Not use it;
2. Show me how to make it better.

## Usage
```
$ ./install.sh -h
Gentoo Raspberry Pi installer, version 0.1
Usage: ./install.sh [option] ...

  -h, --help         display this help and exit
  -d, --device       raw device to write to (e.g. /dev/sdd)
  -t, --tarball-url  specify the stage3 tarball url (e.g. 
                     http://distfiles.gentoo.org/releases/arm/autobuilds/20180831/stage3-armv7a_hardfp-20180831.tar.bz2)
  -H, --hostname     set hostname (e.g. gentoo)
  -T, --timezone     set timezone (e.g. Europe/Amsterdam)
  -u, --username     specify your preferred username (e.g. larry)
  -f, --fullname     specify your full name (e.g. "Larry the Cow")
  -s, --ssh-pubkey   set your ssh pubkey (e.g. ~/.ssh/id_ed25519.pub)

```

## Example

```
# ./install.sh -d /dev/sdd -t http://distfiles.gentoo.org/releases/arm/autobuilds/current-stage3-armv7a_hardfp/stage3-armv7a_hardfp-20180831.tar.bz2 -H auriga -T Europe/Amsterdam -u larry -f "Larry the Cow" -s ~/.ssh/id_ed25519.pub

* WARNING: This will format /dev/sdd:

Model: Generic- USB3.0 CRW -SD (scsi)
Disk /dev/sdd: 31.3GB
Sector size (logical/physical): 512B/512B
Partition Table: msdos
Disk Flags: 

Number  Start   End     Size    Type     File system     Flags
 1      1049kB  67.1MB  66.1MB  primary  fat32           boot, lba
 2      67.1MB  8657MB  8590MB  primary  linux-swap(v1)
 3      8657MB  29.7GB  21.0GB  primary  ext4

Do you wish to continue formatting this device? [yes|no] yes

>>> Partitioning card ..................................... [OK]
>>> Downloading stage3 tarball ............................ [OK]
>>> Verifying stage3 tarball .............................. [OK]
>>> Installing Gentoo ..................................... [OK]
>>> Installing Portage .................................... [OK]
>>> Configuring Gentoo .................................... [OK]
>>> Installing the latest binary Raspberry Pi kernel ...... [OK]
>>> Synchronising cached writes to card and eject card .... [OK]

Installation succeeded. Try booting your Raspberry Pi , login as root, and run "/root/config.sh" to finish the installation.
```

Then, after running "/root/config.sh" once the Raspberry Pi is successfully booted, you should be able to SSH into your Raspberry Pi using the IP address the script returns, and the SSH key you specified when running "install.sh" from your host.

## Dependencies
1. curl (net-misc/curl)
2. parted (sys-block/parted)
3. wget (net-misc/wget)

## How to contribute
If you wish to contribute (you are encouraged!), feel free to create issues, or fork and create pull requests.

## To do

1. Pull latest armv7a hardfp stage3 tarball automatically

## Ideas
1. Ask again for missing arguments if not provided?
2. Or maybe write ncurses install wizard instead of arguments?
3. Python refactor?