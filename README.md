# Script to install Gentoo on a Raspberry Pi
This script fetches an ARM stage3 tarball, verifies its authenticity (GPG and hashes) and installs it on your card. It then configures the new installation to properly boot, set the correct timezone, and copies your SSH key. It then copies two extra scripts for you to run manually once succefully booted and logged into root to finish the installation.

## Full disclosure
I'm not a developer by any means, and you may find this repository a comical attempt to automate installing Gentoo on a Raspberry Pi. And you're probably right, so feel free to:

1. Not use it;
2. Show me how to make it better.

## Usage
```
$ ./rpi-gentoo-install.sh -h
Gentoo Raspberry Pi installer, version 0.1
Usage: ./rpi-gentoo-install.sh [option] ...

  -h, --help         display this help and exit
  -d, --device       raw device to write to (e.g. /dev/sde)
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
# ./rpi-gentoo-install.sh -d /dev/sdd -t http://distfiles.gentoo.org/releases/arm/autobuilds/current-stage3-armv7a_hardfp/stage3-armv7a_hardfp-20180831.tar.bz2 -H auriga -T Europe/Amsterdam -u larry -f "Larry the Cow" -s ~/.ssh/id_ed25519.pub

>>> Partitioning /dev/sdd ................................. [OK]
>>> Downloading stage3 tarball ............................ [OK]
>>> Verifying stage3 tarball .............................. [OK]
>>> Installing Gentoo ..................................... [OK]
>>> Installing Portage .................................... [OK]
>>> Configuring Gentoo .................................... [OK]
>>> Installing the latest binary Raspberry Pi kernel ...... [OK]
>>> Synchronising cached writes to card and eject card .... [OK]

Installation succeeded. Try booting your Raspberry Pi and login as root. Then proceed with the final configuration by launching "/root/rpi-gentoo-config.sh".
```

## How to contribute
If you wish to contribute (you are encouraged!), feel free to create issues, or fork and create pull requests.

## To do

1. Pull latest armv7a hardfp stage3 tarball
2. Check if arguments are valid
3. More UX and feedback on progress of rpi-gentoo-config.sh
4. Remove rpi-gentoo-config.sh after it has succesfully run

## Ideas
1. ncurses install wizard instead of arguments?
2. Python refactor?