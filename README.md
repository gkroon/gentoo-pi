# A script to install Gentoo on a Raspberry Pi 2/3
The aim of this project is to create a minimal, vanilla Gentoo installation for the Raspberry Pi 2/3, plus necessary configurations to properly boot. It achieves this by fetching the latest official armv7a hardfp stage3 tarball from Gentoo, and installs it on your card. It then proceeds with some necessary configurations of your own choosing, partly by chrooting using qemu-binfmt.

## Full disclosure
I'm not a developer by any means, and you may find this repository a comical attempt to automate installing Gentoo on a Raspberry Pi 2/3. And you're probably right, so feel free to:

1. Not use it;
2. Show me how to make it better (you are encouraged!).

## Usage
```
$ ./installer.sh -h
Gentoo Pi installer, version 0.1
Usage: ./installer.sh -d DEVICE -H HOSTNAME -t TIMEZONE -u USERNAME -p PASSWORD 
       -f FULLNAME -r ROOT_PASSWD [option] ...

  -h, --help           display this help and exit
  -d, --device         card to write to (e.g. /dev/sde)
  -H, --hostname       set hostname (e.g. gentoo)
  -t, --timezone       set timezone (e.g. Europe/Amsterdam)
  -u, --username       specify your preferred username (e.g. larry)
  -p, --password       specify your preferred password (e.g. 
                       correcthorsebatterystaple)
  -f, --fullname       specify your full name (e.g. "Larry the Cow")
  -r, --root-password  specify your preferred password for root (e.g. 
                       correcthorsebatterystaple)

Options:
      --tarball-url    optionally set a different stage3 tarball URL 
                       (e.g. http://distfiles.gentoo.org/releases/\
                             arm/autobuilds/20180831/\
                             stage3-armv7a_hardfp-20180831.tar.bz2)
  -s, --ssh            optionally enable SSH
      --ssh-port       optionally set a different SSH port (e.g. 2222)
      --ssh-pubkey     optionally set your ssh pubkey (e.g. 
                       ~/.ssh/id_ed25519.pub)
      --hardened       optionally switch to a hardened profile 
                       (experimental)


```

## Example
`installer.sh` needs to be run as root, and also expects the `files` directory, with its underlying scripts, within its working directory. The following output shows a successful installation using my own Gentoo desktop:
```
# ./installer.sh -d /dev/sdd -H gentoo -t Europe/Amsterdam -u larry \
-p 'correcthorsebatterystaple' -f "Larry the Cow" \
-r 'correcthorsebatterystaple' -s --ssh-pubkey ~/.ssh/id_ed25519.pub

* WARNING: This will format /dev/sdd:

Model: Generic- USB3.0 CRW -SD (scsi)
Disk /dev/sdd: 63.9GB
Sector size (logical/physical): 512B/512B
Partition Table: msdos
Disk Flags: 

Number  Start   End     Size    Type     File system     Flags
 1      1049kB  67.1MB  66.1MB  primary  fat32           boot, lba
 2      67.1MB  8657MB  8590MB  primary  linux-swap(v1)
 3      8657MB  60.7GB  52.0GB  primary  ext4

Do you wish to continue formatting this device? [yes|no] yes

>>> Partitioning card ..................................... [ ok ]
>>> Downloading stage3 tarball ............................ [ ok ]
>>> Verifying stage3 tarball .............................. [ ok ]
>>> Installing Gentoo ..................................... [ ok ]
>>> Installing Portage .................................... [ ok ]
>>> Configuring Gentoo .................................... [ ok ]
>>> Installing the latest binary Raspberry Pi firmware .... [ ok ]
>>> Preparing chroot ...................................... [ ok ]

--- Chrooting to card ---

>>> Changing passwd for root .............................. [ ok ]
>>> Creating new user ..................................... [ ok ]
>>> Changing passwd for new user .......................... [ ok ]
>>> Setting hostname ...................................... [ ok ]
>>> Enabling eth0 to start at boot ........................ [ ok ]
>>> Synchronising Portage ................................. [ ok ]
>>> Updating Gentoo (could take a few hours) .............. [ ok ]
>>> Installing packages ................................... [ ok ]
>>> Configuring packages .................................. [ ok ]
>>> Enabling services ..................................... [ ok ]

--- Returning to host ---

>>> Synchronising cached writes to card and eject card .... [ ok ]

Installation succeeded. Try booting your Gentoo Pi.
```

Then, after the Gentoo Pi is successfully booted, you should be able to login as your new user.

## Dependencies
This script assumes any amd64 Linux host, using either OpenRC or systemd (to start the qemu-binfmt service), with the following packages:

1. alien (app-arch/alien);
2. awk (virtual/awk);
3. coreutils (sys-apps/coreutils);
4. curl (net-misc/curl);
5. dosfstools (sys-fs/dosfstools);
6. e2fsprogs (sys-fs/e2fsprogs);
7. file (sys-apps/file);
8. git (dev-vcs/git);
9. gpg (app-crypt/gnupg);
10. grep (sys-apps/grep);
11. kmod (sys-apps/kmod);
12. parted (sys-block/parted);
13. qemu-static-user (app-emulation/qemu +static-user);
14. rsync (net-misc/rsync);
15. sed (sys-apps/sed);
16. tar (app-arch/tar);
17. util-linux (sys-apps/util-linux);
18. wget (net-misc/wget).

## How to contribute
If you wish to contribute (you are encouraged!), feel free to create issues, or fork and create pull requests.

## To do
1. Compiling kernel from source, instead of using the (very convenient) Raspberry Pi binary firmware;
2. Update "files/update.sh" to automatically remove old kernel modules upon firmware upgrade;
3. Add argument for encrypted swap with random IV at boot;
4. Add argument for encrypted root (LUKS w/ GPG key);
5. Add argument to create a stage4 image instead.

## Ideas
1. Ask again for missing arguments if not provided?
2. Or maybe write ncurses install wizard instead of arguments?
3. Python refactor?
