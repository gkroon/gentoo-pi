# A script to install Gentoo on a Raspberry Pi 2/3
The aim of this project is to create a minimal, vanilla Gentoo installation for the Raspberry Pi 2/3, plus necessary configurations to properly boot. It achieves this by fetching the latest official armv7a hardfp stage3 tarball from Gentoo, and installs it on your card. It then proceeds with some necessary configurations of your own choosing, partly by chrooting using qemu-binfmt.

Among those necessary configurations, these are the most important to note:
1. Compiled Raspberry Pi kernel, using `sys-kernel/raspberrypi-sources`, its default kernel configuration (with added `CONFIG_CRYPTO_XTS=y` for if you wish to use LUKS);
2. Necessary packages, namely `app-admin/sudo`, `dev-vcs/git`, `net-misc/ntp`, and `sys-kernel/genkernel`.
3. Some extra necessary packages, which are strictly installed only if required due to your specified arguments. For example, this means that when using the `--encrypt-root`, or `--encrypt-swap` arguments, it will install and configure `sys-fs/cryptsetup` as well. At the moment this is the only extra package exception.

Note that the total installation time depends on a couple of factors (e.g. download speed, clock speed, write speed, etc.), but as a rough guideline, it takes around 24 hours, where around 18 hours is spent on compiling the kernel, on my Gentoo VM in VirtualBox with 4 vCPUs, on my Intel i5-6300U @ 2.4 GHz. Yes, it takes me that long. I suspect qemu-arm is also emulating the actual clock speed of the Raspberry Pi, for all I know...

## Full disclosure
I'm not a developer by any means, and you may find this repository a comical attempt to automate installing Gentoo on a Raspberry Pi 2/3. And you're probably right, so feel free to:

1. Not use it;
2. Show me how to make it better (you are encouraged!).

## Usage
```
$ ./installer.sh -h
Gentoo Pi installer, version 0.1
Usage: ./installer.sh [-d DEVICE|-i IMAGE] [option] ...

  -h, --help           display this help and exit
  -d, --device         card to write to (e.g. /dev/sde)
  -i, --image-file     specify an image file name to write to, instead 
                       of a block device (e.g. ~/image.bin)

Options:
  -p, --password       specify your preferred password (e.g. 
                       correcthorsebatterystaple)
  -r, --root-password  specify your preferred password for root (e.g. 
                       correcthorsebatterystaple)
  -H, --hostname       specify a different hostname (e.g. gentoo)
  -t, --timezone       Specify a different timezone (e.g. 
                       Europe/Amsterdam)
  -u, --username       specify your preferred username (e.g. larry)
  -f, --fullname       specify your full name (e.g. "Larry the Cow")
  -T, --tarball-url    optionally set a different stage3 tarball URL 
                       (e.g. http://distfiles.gentoo.org/releases/\
                       arm/autobuilds/20180831/\
                       stage3-armv7a_hardfp-20180831.tar.bz2)
  -s, --ssh            optionally enable SSH
      --ssh-port       optionally set a different SSH port (e.g. 2222)
      --ssh-pubkey     optionally set your ssh pubkey (e.g. 
                       ~/.ssh/id_ed25519.pub)
      --hardened       optionally switch to a hardened profile 
                       (experimental)
  -R, --encrypt-root   optionally specify your preferred password to 
                       encrypt the root partition with (e.g. correcthorsebatterystaple)
  -S, --encrypt-swap   optionally encrypt the swap partition with a 
                       random IV each time the system boots

```

Note: the `--hardened` argument is not yet stable and has not been extensively tested by me. To be honest, it took too long for my patience and I chose to focus on other useful features instead (e.g. encrypted root, encrypted swap, compiling kernel from source). The `--hardened` argument is therefore still experimental and needs to be properly end-to-end tested. I will review this feature again in the future and properly test it then, but until then: HERE BE DRAGONS.

## Example
`installer.sh` needs to be run as root, and also expects the `files` directory, with its underlying scripts, within its working directory. The following output shows a successful installation using my own Gentoo desktop:
```
# ./installer.sh -d /dev/sdd -s --ssh-pubkey ~/.ssh/id_ed25519.pub

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

>>> Partitioning device                                      [ ok ]
>>> Downloading stage3 tarball                               [ ok ]
>>> Verifying stage3 tarball                                 [ ok ]
>>> Installing Gentoo                                        [ ok ]
>>> Installing Portage                                       [ ok ]
>>> Configuring Gentoo                                       [ ok ]
>>> Installing the latest binary Raspberry Pi firmware       [ ok ]
>>> Preparing chroot                                         [ ok ]

--- Chrooting to device ---

>>> Changing passwd for root                                 [ ok ]
>>> Creating new user                                        [ ok ]
>>> Changing passwd for new user                             [ ok ]
>>> Setting hostname                                         [ ok ]
>>> Enabling eth0 to start at boot                           [ ok ]
>>> Synchronising Portage                                    [ ok ]
>>> Updating needed packages (could take a few hours)        [ ok ]
>>> Installing needed packages (could take a few hours)      [ ok ]
>>> Configuring packages                                     [ ok ]
>>> Compiling kernel (could take a few hours )               [ ok ]
>>> Enabling services                                        [ ok ]

--- Returning to host ---

>>> Synchronising all pending writes and dismounting         [ ok ]

Installation complete. You can try to boot your Gentoo Pi and login
with the following credentials:
* pi:SXGTR6_-921UheFd
* root:QLviGnB8l21K1-L0

```

Then, after the Gentoo Pi is successfully booted, you should be able to login as your new user.

## Dependencies
This script assumes any amd64 Linux host, using either OpenRC or systemd (to start the qemu-binfmt service to use qemu/chroot), with the following packages:

1. alien (app-arch/alien);
2. awk (virtual/awk);
3. coreutils (sys-apps/coreutils);
4. cryptsetup (sys-fs/cryptsetup);
5. curl (net-misc/curl);
6. dosfstools (sys-fs/dosfstools);
7. e2fsprogs (sys-fs/e2fsprogs);
8. file (sys-apps/file);
9. git (dev-vcs/git);
10. gpg (app-crypt/gnupg);
11. grep (sys-apps/grep);
12. kmod (sys-apps/kmod);
13. parted (sys-block/parted);
14. qemu (app-emulation/qemu);
15. rsync (net-misc/rsync);
16. sed (sys-apps/sed);
17. tar (app-arch/tar);
18. util-linux (sys-apps/util-linux);
19. wget (net-misc/wget).

## How to contribute
If you wish to contribute (you are encouraged!), feel free to create issues, or fork and create pull requests.

## To do list
If you wish to contribute, the following items are identified as useful additions that haven't been "claimed" by anyone yet.

1. Simplify the installation experience (ncurses?);
2. Add argument to build arm64, instead of default armv7;
3. Add arguments to specify boot, swap, root partition sizes;
4. Create non-boot partitions inside LVM.

N.b.: This check list will be moved to separate issues, or another convenient tracking solution when multiple people start to contribute. At the moment this list is only for my own convenience.

## Raw ideas
1. Ansible/Python refactor?
2. If building arm64, maybe use stage4 instead of stage3?
3. Maybe add an argument for increased verbosity, to keep track of each installation phase?
