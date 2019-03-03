#!/bin/sh

# WARNING: DO NOT BLINDLY RUN. THIS IS A WORK IN PROGRESS SCRIPT FOR MY OWN
# REFERENCE TO CONFIGURE A WORKING GENTOO INSTALLATION ON A RASPBERRY PI. IT'S
# NOT READY FOR PRODUCTION YET. HERE BE DRAGONS.

# Installing Gentoo base system on a Raspberry Pi. This guide assumes a Linux
# workstation to prepare the SD card. No manual kernel compilation, but instead
# uses the precompiled firmware of github.com/raspberrypi/firmware/. I would
# like to automate the kernel compilation from source, but it remains future
# work for now.

# Help function
print_help() {
  echo "Gentoo Raspberry Pi installer, version 0.1"
  echo "Usage: $0 [option] ..." >&2
  echo
  echo "  -h, --help         display this help and exit"
  echo "  -d, --device       raw device to write to (e.g. /dev/sde)"
  echo "  -t, --tarball-url  specify the stage3 tarball url (e.g. "
  echo "                     http://distfiles.gentoo.org/releases/arm/autobuilds/20180831/stage3-armv7a_hardfp-20180831.tar.bz2)"
  echo "  -H, --hostname     set hostname (e.g. gentoo)"
  echo "  -T, --timezone     set timezone (e.g. Europe/Amsterdam)"
  echo "  -u, --username     specify your preferred username (e.g. larry)"
  echo "  -f, --fullname     specify your full name (e.g. \"Larry the Cow\")"
  echo "  -s, --ssh-pubkey   set your ssh pubkey (e.g. ~/.ssh/id_ed25519.pub)"
  echo
  exit 0
}

get_args() {
  while [[ "$1" ]]; do
    case "$1" in
      -h|--help) print_help ;;
      -d|--device) SDCARD_DEVICE="${2}" ;;
      -t|--tarball-url) TARBALL="${2}" ;;
      -H|--hostname) HOSTNAME="${2}" ;;
      -T|--timezone) TIMEZONE="${2}" ;;
      -u|--username) NEW_USER="${2}" ;;
      -f|--fullname) NEW_USER_FULL_NAME="${2}" ;;
      -s|--ssh-pubkey) SSH_PUBKEY=$(readlink -m ${2}) ;;
    esac
    shift
  done
}

get_vars() {
  # The following partitions will be created, on "${SDCARD_DEVICE}"
  SDCARD_DEVICE_BOOT="${SDCARD_DEVICE}1"
  SDCARD_DEVICE_SWAP="${SDCARD_DEVICE}2"
  SDCARD_DEVICE_ROOT="${SDCARD_DEVICE}3"

  # Work directory to download archives to and to unpack from
  WORKDIR="/tmp/stage3"

  # The following path will be used on your workstation to mount the newly
  # formatted "${SDCARD_DEVICE_ROOT}". Then, "${SDCARD_DEVICE_BOOT}" is mounted
  # on its /boot directory.
  MOUNTED_ROOT="/mnt/gentoo"
  MOUNTED_BOOT="${MOUNTED_ROOT}/boot"

  # The official Raspberry Pi firmware will be git pulled to "${FIRMWARE_DIR}",
  # and will then be installed on the system. You can also compile your own
  # kernel, but I have not yet found/written a solid Raspberry Pi kernel config.
  FIRMWARE_DIR="${MOUNTED_ROOT}/opt/firmware"

  # The following entries will be inserted in fstab on the SD card
  RPI_DEVICE="/dev/mmcblk0"
  RPI_DEVICE_BOOT="${RPI_DEVICE}p1"
  RPI_DEVICE_SWAP="${RPI_DEVICE}p2"
  RPI_DEVICE_ROOT="${RPI_DEVICE}p3"

  # Get current date from host. We will use NTP later on
  DATE=$(date --rfc-3339=date)

  # Terminal colours
  GREEN='\033[0;32m'
  BLUE='\033[0;34m'
  PURPLE='\033[0;35m'
  LGREEN='\033[1;32m'
  LRED='\033[1;31m'
  YELLOW='\033[1;33m'
  NC='\033[0m'
}

test_args() {
  if [ ! -n "${SDCARD_DEVICE}" ]; then
    echo "-d|--device no set. Exiting..."
    exit 1
  elif [ ! -b "${SDCARD_DEVICE}" ]; then
    echo "${SDCARD_DEVICE} not found."
    exit 1
  else
    # Last warning before formatting ${SDCARD_DEVICE}
    echo
    echo -e "${YELLOW}* WARNING: This will format ${SDCARD_DEVICE}:${NC}"
    echo
    parted ${SDCARD_DEVICE} print
    while true; do
      read -p "Do you wish to continue formatting this device? [yes|no] " yn
      case $yn in
        [Yy]* ) break ;;
        [Nn]* ) exit 0 ;;
        * ) echo "Please answer yes or no." ;;
      esac
    done
  fi

  if [ ! -n "${TARBALL}" ]; then
    echo "-t|--tarball no set. Exiting..."
    exit 1
  elif [ ! "curl -Is ${TARBALL}" ]; then
    echo -e "${TARBALL} not found. Exiting..."
    exit 1
  fi

  if [ ! -n "${HOSTNAME}" ]; then
    echo "-H|--hostname no set. Exiting..".
    exit 1
  fi

  if [ ! -n "${TIMEZONE}" ]; then
    echo "-T|--timezone no set. Exiting..."
    exit 1
  elif [ ! -f "/usr/share/zoneinfo/${TIMEZONE}" ]; then
    echo "Invalid timezone. Exiting..."
    exit 1
  fi

  if [ ! -n "${NEW_USER}" ]; then
    echo "-u|--username no set. Exiting..."
    exit 1
  fi

  if [ ! -n "${NEW_USER_FULL_NAME}" ]; then
    echo "-f|--fullname no set. Exiting..."
    exit 1
  fi

  if [ ! -n "${SSH_PUBKEY}" ]; then
    echo "-s|--ssh-pubkey no set. Exiting..."
    exit 1
  elif [[ $(file "${SSH_PUBKEY}") != *OpenSSH*public\ key ]]; then
    echo "Invalid SSH public key. Exiting..."
    exit 1
  fi
}

prepare_card() {
  # Unmount if mounted
  if [ "mount | grep ${SDCARD_DEVICE}1" ]; then
    umount "${SDCARD_DEVICE}1" > /dev/null 2>&1
  fi
  if [ "mount | grep ${SDCARD_DEVICE}2" ]; then
    umount "${SDCARD_DEVICE}2" > /dev/null 2>&1
  fi
  if [ "mount | grep ${SDCARD_DEVICE}3" ]; then
    umount "${SDCARD_DEVICE}3" > /dev/null 2>&1
  fi

  # Partition card (tweak sizes if required)
  if ! parted --script "${SDCARD_DEVICE}" \
    mklabel msdos \
    mkpart primary fat32 1MiB 64MiB \
    set 1 lba on \
    set 1 boot on \
    mkpart primary linux-swap 64MiB 8256MiB \
    mkpart primary 8256MiB 95% \
    print >/dev/null 2>&1; then
      echo -e "[${LRED}FAILED${NC}]: partitioning failed"
      exit 1
  fi

  # Formatting new partitions
  if ! yes | mkfs.vfat -F 32 "${SDCARD_DEVICE_BOOT}" >/dev/null 2>&1; then
    echo -e "[${LRED}FAILED${NC}]: formatting ${SDCARD_DEVICE_BOOT} failed"
    exit 1
  fi
  if ! yes | mkswap "${SDCARD_DEVICE_SWAP}" >/dev/null 2>&1; then
    echo -e "[${LRED}FAILED${NC}]: formatting ${SDCARD_DEVICE_SWAP} failed"
    exit 1
  fi
  if ! yes | mkfs.ext4 "${SDCARD_DEVICE_ROOT}" >/dev/null 2>&1; then
    echo -e "[${LRED}FAILED${NC}]: formatting ${SDCARD_DEVICE_ROOT} failed"
    exit 1
  fi

  # Mount root and boot partitions for installation
  rm -rf "${MOUNTED_ROOT}"
  mkdir "${MOUNTED_ROOT}"
  if ! mount "${SDCARD_DEVICE_ROOT}" "${MOUNTED_ROOT}"; then
    echo -e "[${LRED}FAILED${NC}]: mounting ${SDCARD_DEVICE_ROOT} on ${MOUNTED_ROOT} failed"
    exit 1
  fi
  mkdir "${MOUNTED_BOOT}"
  if ! mount "${SDCARD_DEVICE_BOOT}" "${MOUNTED_BOOT}"; then
    echo -e "[${LRED}FAILED${NC}]: mounting ${SDCARD_DEVICE_BOOT} on ${MOUNTED_BOOT} failed"
    exit 1
  fi
}

download_stage3() {
  # Creating work dir
  if [ ! -d "${WORKDIR}" ]; then
    mkdir "${WORKDIR}"
  fi

  # Downloading stage3 tarball and signatures
  if [ ! -f "${WORKDIR}/${TARBALL##*/}" ]; then
      wget -q "${TARBALL}" -O ${WORKDIR}/${TARBALL##*/}
  fi

  if [ ! -f "${WORKDIR}/${TARBALL##*/}.CONTENTS" ]; then
    wget -q "${TARBALL}.CONTENTS" -O "${WORKDIR}/${TARBALL##*/}.CONTENTS"
  fi

  if [ ! -f "${WORKDIR}/${TARBALL##*/}.DIGESTS" ]; then
    wget -q "${TARBALL}.DIGESTS" -O "${WORKDIR}/${TARBALL##*/}.DIGESTS"
  fi

  if [ ! -f "${WORKDIR}/${TARBALL##*/}.DIGESTS.asc" ]; then
    wget -q "${TARBALL}.DIGESTS.asc" -O "${WORKDIR}/${TARBALL##*/}DIGESTS.asc"
  fi

  return 0
}

verify_stage3() {
  # Validating signatures
  if [ ! "gpg --keyserver hkps.pool.sks-keyservers.net --recv-keys 0xBB572E0E2D182910 " ]; then
    echo -e "[${LRED}FAILED${NC}]: could not retrieve Gentoo PGP key. Do we have Interwebz?"
    exit 1
  fi
  if [ ! "gpg --verify ${WORKDIR}/${TARBALL##*/}.DIGESTS.asc" ]; then
    echo -e "[${LRED}FAILED${NC}]: tarball PGP signature mismatch - you sure you download an official stage3 tarball?"
    exit 1
  fi
  if [ ! "sha512sum -c ${WORKDIR}/${TARBALL##*/}.DIGESTS.asc" ]; then
    echo -e "[${LRED}FAILED${NC}]: tarball hash mismatch - did Gentoo mess up their hashes?"
    exit 1
  fi

  return 0
}

install_gentoo() {
  if ! tar xfpj "${WORKDIR}/${TARBALL##*/}" -C "${MOUNTED_ROOT}"; then
    echo -e "[${LRED}FAILED${NC}]: could not untar ${WORKDIR}/${TARBALL##*/} to ${MOUNTED_ROOT}/usr/"
    exit 1
  fi

  return 0
}

install_portage() {
  # Installing Gentoo
  if [ ! -f "${WORKDIR}/portage-latest.tar.bz2" ]; then
    wget -q "http://distfiles.gentoo.org/snapshots/portage-latest.tar.bz2" -O "${WORKDIR}/portage-latest.tar.bz2"
  fi

  if ! tar xfpj ${WORKDIR}/portage-latest.tar.bz2 -C "${MOUNTED_ROOT}/usr/"; then
    echo -e "[${LRED}FAILED${NC}]: could not untar ${WORKDIR}/portage-latest.tar.bz2 to ${MOUNTED_ROOT}/usr/"
    exit 1
  fi

  return 0
}

configure_gentoo() {
  # Editing "${MOUNTED_ROOT}/etc/portage/make.conf" (tweak if desired)
  if [ -f "${MOUNTED_ROOT}/etc/portage/make.conf" ]; then
    sed -i 's/^CFLAGS.*/CFLAGS="-O2 -pipe -march=armv7-a -mfpu=neon-vfpv4 -mfloat-abi=hard"/' "${MOUNTED_ROOT}/etc/portage/make.conf"
    echo 'EMERGE_DEFAULT_OPTS="${EMERGE_DEFAULT_OPTS} --jobs=4 --load-average=4"' >> "${MOUNTED_ROOT}/etc/portage/make.conf"
  else
    echo -e "[${LRED}FAILED${NC}]: could not find ${MOUNTED_ROOT}/etc/portage/make.conf"
    exit 1
  fi

  # Configuring /etc/fstab
  if [ -f "${MOUNTED_ROOT}/etc/fstab" ]; then
    sed -e '/\/dev/ s/^#*/#/' -i "${MOUNTED_ROOT}/etc/fstab" # uncomments existing entries
    echo "proc           /proc proc defaults         0 0" >> "${MOUNTED_ROOT}/etc/fstab"
    echo "${RPI_DEVICE_BOOT} /boot vfat defaults         0 2" >> "${MOUNTED_ROOT}/etc/fstab"
    echo "${RPI_DEVICE_SWAP} none  swap sw               0 0" >> "${MOUNTED_ROOT}/etc/fstab"
    echo "${RPI_DEVICE_ROOT} /     ext4 defaults,noatime 0 1" >> "${MOUNTED_ROOT}/etc/fstab"
  else
    echo -e "[${LRED}FAILED${NC}]: could not find ${MOUNTED_ROOT}/etc/fstab"
    exit 1
  fi

  # Setting date and time zone
  if [ -f "${MOUNTED_ROOT}/usr/share/zoneinfo/${TIMEZONE}" ]; then
    cp "${MOUNTED_ROOT}/usr/share/zoneinfo/${TIMEZONE}" "${MOUNTED_ROOT}/etc/localtime"
    echo "${TIMEZONE}" > "${MOUNTED_ROOT}/etc/timezone"
  else
    echo -e "[${LRED}FAILED${NC}]: could not find ${MOUNTED_ROOT}/usr/share/zoneinfo/${TIMEZONE}"
    exit 1
  fi

  # Clearing root passwd
  if [ -f "${MOUNTED_ROOT}/etc/shadow" ]; then
    sed -i 's/^root:.*/root::::::::/' "${MOUNTED_ROOT}/etc/shadow"
  else
    echo -e "[${LRED}FAILED${NC}]: could not find ${MOUNTED_ROOT}/etc/shadow"
    exit 1
  fi

  # Adding your SSH pubkey to authorized_keys:
  if [ ! -d "${MOUNTED_ROOT}/root/.ssh" ]; then
    mkdir "${MOUNTED_ROOT}/root/.ssh"
  fi

  if [ -f "${SSH_PUBKEY}" ]; then
    cat "${SSH_PUBKEY}" > "${MOUNTED_ROOT}/root/.ssh/authorized_keys"
    chmod 0600 "${MOUNTED_ROOT}/root/.ssh/authorized_keys"
  else
    echo -e "[${LRED}FAILED${NC}]: could not find ${SSH_PUBKEY}"
    exit 1
  fi

  # Copying over rpi-gentoo-updater.sh and writing rpi-gentoo-config.sh
  if [ -f "rpi-gentoo-updater.sh" ]; then
    cp rpi-gentoo-updater.sh "${MOUNTED_ROOT}/root/rpi-gentoo-updater.sh"
    chmod 0700 "${MOUNTED_ROOT}/root/rpi-gentoo-updater.sh"
  else
    echo -e "[${LRED}FAILED${NC}]: could not find local rpi-gentoo-updater.sh"
    exit 1
  fi
  if [ -f "rpi-gentoo-config.sh" ]; then
    awk '
      { print }
      /Collected vars will be hardcoded after this line/ {
      print "\tDATE=\"'"${DATE}"'\""
      print "\tHOSTNAME=\"'"${HOSTNAME}"'\""
      print "\tNEW_USER=\"'"${NEW_USER}"'\""
      print "\tNEW_USER_FULL_NAME=\"'"${NEW_USER_FULL_NAME}"'\""
      print "\tSSH_PUBKEY=\"'"${SSH_PUBKEY}"'\""
      }' rpi-gentoo-config.sh > "${MOUNTED_ROOT}/root/rpi-gentoo-config.out"
    mv "${MOUNTED_ROOT}/root/rpi-gentoo-config.out" "${MOUNTED_ROOT}/root/rpi-gentoo-config.sh"
    chmod 0700 "${MOUNTED_ROOT}/root/rpi-gentoo-config.sh"
  else
    echo -e "[${LRED}FAILED${NC}]: could not find local rpi-gentoo-config.sh"
    exit 1
  fi
}

install_rpi_kernel() {
  # Pulling and installing Raspberry Pi kernel and modules.
  if ! git clone --depth 1 git://github.com/raspberrypi/firmware/ "${FIRMWARE_DIR}" >/dev/null 2>&1; then
    echo -e "[${LRED}FAILED${NC}]: could not git clone Raspberry Pi firmware to ${FIRMWARE_DIR}"
    exit 1
  fi
  rsync -a "${FIRMWARE_DIR}/boot/" "${MOUNTED_ROOT}/boot/"
  rsync -a "${FIRMWARE_DIR}/modules/" "${MOUNTED_ROOT}/lib/modules/"

  # Boot options
  echo "ipv6.disable=0 selinux=0 plymouth.enable=0 smsc95xx.turbo_mode=N dwc_otg.lpm_enable=0 console=ttyAMA0,115200 kgdboc=ttyAMA0,115200 console=tty1 root=${RPI_DEVICE_ROOT} rootfstype=ext4 elevator=noop rootwait" > "${MOUNTED_BOOT}/cmdline.txt"
}

eject_card() {
  umount "${MOUNTED_BOOT}"
  umount "${MOUNTED_ROOT}"
  sync
  eject "${SDCARD_DEVICE}"
}

get_args "$@"
get_vars
test_args

echo
echo -en '>>> Partitioning card ..................................... '
if prepare_card ; then
  echo -e "[${LGREEN}OK${NC}]"
fi

echo -en '>>> Downloading stage3 tarball ............................ '
if download_stage3 ; then
  echo -e "[${LGREEN}OK${NC}]"
fi

echo -en '>>> Verifying stage3 tarball .............................. '
if verify_stage3 ; then
  echo -e "[${LGREEN}OK${NC}]"
fi

echo -en '>>> Installing Gentoo ..................................... '
if install_gentoo ; then
  echo -e "[${LGREEN}OK${NC}]"
fi

echo -en '>>> Installing Portage .................................... '
if install_portage ; then
  echo -e "[${LGREEN}OK${NC}]"
fi

echo -en '>>> Configuring Gentoo .................................... '
if configure_gentoo ; then
  echo -e "[${LGREEN}OK${NC}]"
fi

echo -en '>>> Installing the latest binary Raspberry Pi kernel ...... '
if install_rpi_kernel ; then
  echo -e "[${LGREEN}OK${NC}]"
fi

echo -en '>>> Synchronising cached writes to card and eject card .... '
if eject_card ; then
  echo -e "[${LGREEN}OK${NC}]"
fi

echo
echo "Installation succeeded. Try booting your Raspberry Pi and login as root. Then proceed with the final configuration by launching \"/root/rpi-gentoo-config.sh\"."