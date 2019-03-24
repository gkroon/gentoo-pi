#!/bin/sh

# Forked from https://github.com/pentoo/pentoo-overlay/blob/master/scripts/pentoo-updater.sh to be compatible with the Raspberry Pi.

if [ -n "$(command -v id 2> /dev/null)" ]; then
  USERID="$(id -u 2> /dev/null)"
fi

if [ -z "${USERID}" ] && [ -n "$(id -ru)" ]; then
  USERID="$(id -ru)"
fi

if [ -n "${USERID}" ] && [ "${USERID}" != "0" ]; then
  printf "Run it as root\n" ; exit 1;
elif [ -z "${USERID}" ]; then
  printf "Unable to determine user id, permission errors may occur.\n"
fi

. /etc/profile
env-update

check_profile () {
  if [ -L "/etc/portage/make.profile" ] && [ ! -e "/etc/portage/make.profile" ]; then
    failure="0"
    #profile is broken, read the symlink then try to reset it back to what it should be
    printf "Your profile is broken, attempting repair...\n"
    desired="$(readlink /etc/portage/make.profile | cut -d'/' -f 6-)"
    if ! eselect profile set "${desired}"; then
      #profile failed to set, try hard to set the right one
      #first set arch
      arch=$(uname -m)
      if [ "${arch}" = "armv7*" ]; then
        ARCH="arm"
        ARCH_VER="armv7a"
      else
        failure=1
      fi
      #then check if we are hard
      if gcc -v 2>&1 | grep -q Hardened; then
        hardening="hardened"
      else
        hardening="default"
      fi
      if [ "${failure}" = "0" ]; then
        if [ "${hardening}" = "hardened" ]; then
    if ! eselect profile set ${hardening}/linux/${ARCH}/${ARCH_VER}; then
            failure="1"
          fi
        elif [ "${hardening}" = "default" ]; then
          if ! eselect profile set ${hardening}/linux/${ARCH}/13.0/${ARCH_VER}; then
            failure="1"
          fi
        else
    failure="1"
        fi
      fi
    fi
    if [ "${failure}" = "1" ]; then
      printf "Your profile is invalid, and we failed to automatically fix it.\n"
      printf "Please select a profile that works with \"eselect profile list\" and \"eselect profile set ##\"\n"
      exit 1
    else
      printf "Profile repaired.\n"
    fi
  fi
}

update_kernel() {
  arch=$(uname -m)
  if ! { [ "${arch}" = "arm" ] || [ "${arch}" = "armv7l" ]; }; then
    printf "Arch ${arch} isn't supported for automatic kernel updating, skipping...\n."
    return 1
  fi

  bestkern="$(qlist $(portageq best_version / raspberrypi-sources) | grep 'init/Kconfig' | awk -F'/' '{print $4}' | cut -d'-' -f 2-)"
  if [ -z "${bestkern}" ]; then
    printf "Failed to find raspberrypi-sources installed, is this a Raspberry Pi system?\n"
    return 1
  fi

  #next we fix the symlink
  if [ "$(readlink /usr/src/linux)" != "linux-${bestkern}" ]; then
    unlink /usr/src/linux
    ln -s "linux-${bestkern}" /usr/src/linux
  fi
  currkern="$(uname -r)"
  if [ "${currkern}" != "${bestkern}" ]; then
    printf "Currently running kernel ${currkern} is out of date.\n"
    if [ -x "/usr/src/linux-${bestkern}/vmlinux" ] && [ -r "/lib/modules/${bestkern}-v7+/modules.dep" ]; then
      if [ ! -e /usr/src/linux/.raspberrypi-updater-running ]; then
        printf "Kernel ${bestkern} appears ready to go, please reboot when convenient.\n"
        return 1
      else
        printf "Updated kernel ${bestkern} available, building...\n"
      fi
    else
      printf "Updated kernel ${bestkern} available, building...\n"
    fi
  else
    printf "Found an updated config for ${bestkern}, rebuilding...\n"
  fi

  #then we set genkernel options as needed
  genkernelopts="--no-mrproper --disklabel --microcode --compress-initramfs-type=gzip"
  if grep -q btrfs /etc/fstab || grep -q btrfs /proc/cmdline; then
    genkernelopts="${genkernelopts} --btrfs"
  fi
  if grep -q zfs /etc/fstab || grep -q zfs /proc/cmdline; then
    genkernelopts="${genkernelopts} --zfs"
  fi
  if grep -q 'ext[234]' /etc/fstab; then
    genkernelopts="${genkernelopts} --e2fsprogs"
  fi
  if grep -q gpg /proc/cmdline; then
    genkernelopts="${genkernelopts} --luks --gpg"
  elif grep -q luks /etc/crypttab || grep -E '^swap|^source' /etc/conf.d/dmcrypt; then
    genkernelopts="${genkernelopts} --luks"
  fi
  #then we go nuts
  touch /usr/src/linux/.raspberrypi-updater-running
  if genkernel ${genkernelopts} --callback="emerge @module-rebuild" all; then
    mv /boot/kernel-genkernel-* /boot/kernel7.img
    mv /boot/initramfs-genkernel-* /boot/initramfs.gz
    cp /usr/src/linux-${bestkern}/arch/arm/boot/dts/*.dtb /boot/
    cp /usr/src/linux-${bestkern}/arch/arm/boot/dts/overlays/* /boot/overlays/
    wget https://github.com/raspberrypi/firmware/raw/master/boot/bootcode.bin -O /boot/bootcode.bin
    wget https://github.com/raspberrypi/firmware/raw/master/boot/fixup.dat -O /boot/fixup.dat
    wget https://github.com/raspberrypi/firmware/raw/master/boot/start.elf -O /boot/start.elf
    printf "Kernel ${bestkern} built successfully, please reboot when convenient.\n"
    rm -f /usr/src/linux/.raspberrypi-updater-running
    return 0
  else
    printf "Kernel ${bestkern} failed to build, please see logs above.\n"
    return 1
  fi
}

safe_exit() {
  exit 0
}

check_profile
eselect python update
PORTAGE_MANIFEST=/usr/portage/Manifest
if ! emerge --sync; then
  printf "emerge --sync failed, aborting update for safety\n"
  exit 1
fi
check_profile

RESET_PYTHON=0
#first we set the python interpreters to match PYTHON_TARGETS (and ensure the versions we set are actually built)
PYTHON2=$(emerge --info | grep -oE 'PYTHON_TARGETS\="(python[23]_[0-9]\s*)+"' | head -n1 | cut -d\" -f2 | cut -d" " -f 1 |sed 's#_#.#')
PYTHON3=$(emerge --info | grep -oE 'PYTHON_TARGETS\="(python[23]_[0-9]\s*)+"' | head -n1 | cut -d\" -f2 | cut -d" " -f 2 |sed 's#_#.#')
if [ -z "${PYTHON2}" ] || [ -z "${PYTHON3}" ]; then
  printf "Failed to autodetect PYTHON_TARGETS\n"
  printf "Detected Python 2: ${PYTHON2:-none}\n"
  printf "Detected Python 3: ${PYTHON3:-none}\n"
  printf "From PYTHON_TARGETS: $(emerge --info | grep '^PYTHON TARGETS')\n"
  exit 1
fi
if eselect python list --python2 | grep -q "${PYTHON2}"; then
  eselect python set --python2 "${PYTHON2}" || safe_exit
else
  printf "System wants ${PYTHON2} as default python2 version but it isn't installed yet.\n"
  RESET_PYTHON=1
fi
if eselect python list --python3 | grep -q "${PYTHON3}"; then
  eselect python set --python3 "${PYTHON3}" || safe_exit
else
  printf "System wants ${PYTHON3} as default python3 version but it isn't installed yet.\n"
  RESET_PYTHON=1
fi
"${PYTHON2}" -c "from _multiprocessing import SemLock" || emerge -1 python:"${PYTHON2#python}"
"${PYTHON3}" -c "from _multiprocessing import SemLock" || emerge -1 python:"${PYTHON3#python}"
emerge --update --newuse --oneshot --changed-use --newrepo portage || safe_exit

#modified from news item "Python ABIFLAGS rebuild needed"
if [ -n "$(find /usr/lib*/python3* -name '*cpython-3[3-5].so')" ]; then
  emerge -1v --usepkg=n --buildpkg=y $(find /usr/lib*/python3* -name '*cpython-3[3-5].so')
fi
if [ -n "$(find /usr/include/python3.[3-5] -type f 2> /dev/null)" ]; then
  emerge -1v --usepkg=n --buildpkg=y /usr/include/python3.[3-5]
fi

#modified from news item gcc-5-new-c++11-abi
#gcc_target="x86_64-pc-linux-gnu-5.4.0"
#if [ "$(gcc-config -c)" != "${gcc_target}" ]; then
#  if gcc-config -l | grep -q "${gcc_target}"; then
#    gcc-config "${gcc_target}"
#    . /etc/profile
#    revdep-rebuild --library 'libstdc++.so.6' -- --buildpkg=y --usepkg=n --exclude gcc
#  fi
#fi

emerge @changed-deps || safe_exit

emerge --deep --update --newuse -kb --changed-use --newrepo @world || safe_exit

perl-cleaner --ph-clean --modules -- --buildpkg=y || safe_exit

emerge --deep --update --newuse -kb --changed-use --newrepo @world || safe_exit

if [ ${RESET_PYTHON} = 1 ]; then
  eselect python set --python2 "${PYTHON2}" || safe_exit
  eselect python set --python3 "${PYTHON3}" || safe_exit
  "${PYTHON2}" -c "from _multiprocessing import SemLock" || emerge -1 python:"${PYTHON2#python}"
  "${PYTHON3}" -c "from _multiprocessing import SemLock" || emerge -1 python:"${PYTHON3#python}"
fi

if portageq list_preserved_libs /; then
  emerge @preserved-rebuild --buildpkg=y || safe_exit
fi
smart-live-rebuild 2>&1 || safe_exit
revdep-rebuild -i -- --rebuild-exclude dev-java/swt --exclude dev-java/swt --buildpkg=y || safe_exit
emerge --deep --update --newuse -kb --changed-use --newrepo @world || safe_exit
#we need to do the clean BEFORE we drop the extra flags otherwise all the packages we just built are removed
emerge --depclean || safe_exit
if portageq list_preserved_libs /; then
  emerge @preserved-rebuild --buildpkg=y || safe_exit
fi

update_kernel
