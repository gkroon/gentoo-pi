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
  echo "Gentoo Pi installer, version 0.1"
  echo "Usage: $0 -d DEVICE -H HOSTNAME -t TIMEZONE -u USERNAME -p PASSWORD "
  echo "       -f FULLNAME -r ROOT_PASSWD [option] ..." >&2
  echo
  echo "  -h, --help           display this help and exit"
  echo "  -d, --device         card to write to (e.g. /dev/sde)"  
  echo "  -H, --hostname       set hostname (e.g. gentoo)"
  echo "  -t, --timezone       set timezone (e.g. Europe/Amsterdam)"
  echo "  -u, --username       specify your preferred username (e.g. larry)"
  echo "  -p, --password       specify your preferred password (e.g. "
  echo "                       correcthorsebatterystaple)"
  echo "  -f, --fullname       specify your full name (e.g. \"Larry the Cow\")"
  echo "  -r, --root-password  specify your preferred password for root (e.g. "
  echo "                       correcthorsebatterystaple)"
  echo
  echo "Options:"
  echo "      --tarball-url    optionally set a different stage3 tarball URL "
  echo "                       (e.g. http://distfiles.gentoo.org/releases/\\"
  echo "                             arm/autobuilds/20180831/\\"
  echo "                             stage3-armv7a_hardfp-20180831.tar.bz2)"
  echo "  -s, --ssh            optionally enable SSH"
  echo "      --ssh-port       optionally set a different SSH port (e.g. 2222)"
  echo "      --ssh-pubkey     optionally set your ssh pubkey (e.g. "
  echo "                       ~/.ssh/id_ed25519.pub)"
  echo "      --hardened       optionally switch to a hardened profile "
  echo "                       (experimental)"
  echo
  exit 0
}

get_args() {
  while [[ "$1" ]]; do
    case "$1" in
      -h|--help) print_help ;;
      -d|--device) SDCARD_DEVICE="${2}" ;;
         --tarball-url) TARBALL="${2}" ;;
      -H|--hostname) HOSTNAME="${2}" ;;
      -t|--timezone) TIMEZONE="${2}" ;;
      -u|--username) NEW_USER="${2}" ;;
      -p|--password) NEW_USER_PASSWD="${2}" ;;
      -f|--fullname) NEW_USER_FULL_NAME="${2}" ;;
      -r|--root-password) ROOT_PASSWD="${2}" ;;
      -s|--ssh) SSH="1" ;;
         --ssh-pubkey) SSH_PUBKEY=$(readlink -m ${2}) ;;
         --ssh-port) SSH_PORT="{2}" ;;
         --hardened) HARDENED="1" ;;
    esac
    shift
  done
}

get_vars() {
  # Terminal colours
  GREEN='\033[0;32m'
  BLUE='\033[0;34m'
  MAGENTA='\033[0;35m'
  LGREEN='\033[1;32m'
  LRED='\033[1;31m'
  YELLOW='\033[1;33m'
  NC='\033[0m'

  # Binaries we expect in PATH to run this script in the first place. However,
  # other commands such as "cd", "echo", and "exit" are assumed to be built-in
  # shell commands. In case of any errors, refer to the README.md to verify the
  # dependencies on your system.
  DEPS=(alien awk chroot cat chmod cp curl eject file git gpg grep mkdir \
        mkfs.ext4 mkfs.vfat mkswap modprobe mount parted qemu-arm rm rsync \
        sed sha512sum sync tar umount useradd wget)

  # The following partitions will be created, on "${SDCARD_DEVICE}"
  SDCARD_DEVICE_BOOT="${SDCARD_DEVICE}1"
  SDCARD_DEVICE_SWAP="${SDCARD_DEVICE}2"
  SDCARD_DEVICE_ROOT="${SDCARD_DEVICE}3"

  # Work directory to download archives to and to unpack from
  WORKDIR="/tmp/workdir"

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

  # We'll need the latest qemu-static-user package from Debian to chroot later
  QEMU_DEB="$(curl -s https://packages.debian.org/sid/amd64/qemu-user-static/download | grep -o http://ftp.nl.debian.org/debian/pool/main/q/qemu/qemu-user-static.\*_amd64.deb)"

  # When alien converts the qemu-static-user deb to tgz, this is the new file
  # name. The below variable uses "${QEMU_DEB}", but strips the full URL path
  # so that only the name is left. It then strips the ".deb" extension,
  # replaces underscores to dashes, and appends ".tgz" as the new extension.
  QEMU_DEB_STRIP_PATH="${QEMU_DEB##*/}"
  QEMU_DEB_STRIP_PATH_STRIP_EXT="${QEMU_DEB_STRIP_PATH%-*}"
  QEMU_DEB_STRIP_PATH_STRIP_EXT_REPLACE="${QEMU_DEB_STRIP_PATH_STRIP_EXT//_/-}"
  QEMU_TGZ="${QEMU_DEB_STRIP_PATH_STRIP_EXT_REPLACE}.tgz"

  # Bind mounts that chroot needs
  CHROOT_BIND_MOUNTS=(proc sys dev dev/pts)
}

test_args() {
  if [ ! -n "${SDCARD_DEVICE}" ]; then
    echo "-d|--device no set. Exiting..."
    exit 1
  elif [ ! -b "${SDCARD_DEVICE}" ]; then
    echo "${SDCARD_DEVICE} not found."
    exit 1
  fi

  if [ ! -n "${TARBALL}" ]; then
    LATEST_TARBALL="$(curl -s http://distfiles.gentoo.org/releases/arm/autobuilds/latest-stage3-armv7a_hardfp.txt | tail -n 1 | awk '{print $1}')"
    TARBALL="http://distfiles.gentoo.org/releases/arm/autobuilds/${LATEST_TARBALL}"
    if [[ ! $(curl -Is ${TARBALL}) != *200\ OK ]]; then
      echo -e "Latest stage3 tarball not found - please file a bug? Exiting..."
      exit 1
    fi
  elif [[ ! $(curl -Is ${TARBALL}) != *200\ OK ]]; then
    echo -e "Overridden stage3 tarball not found. Exiting..."
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

  if [ ! -n "${NEW_USER_PASSWD}" ]; then
    echo "-p|--password no set. Exiting..."
    exit 1
  fi

  if [ ! -n "${NEW_USER_FULL_NAME}" ]; then
    echo "-f|--fullname no set. Exiting..."
    exit 1
  fi

  if [ ! -n "${ROOT_PASSWD}" ]; then
    echo "-r|--root-password no set. Exiting..."
    exit 1
  fi

  if [ -n "${SSH_PUBKEY}" ]; then
    if [[ $(file "${SSH_PUBKEY}") != *OpenSSH*public\ key ]]; then
      echo "Invalid SSH public key. Exiting..."
      exit 1
    fi
  fi
}

test_deps() {
  for i in ${DEPS[@]}; do
    if ! which ${i} >/dev/null 2>&1; then
      echo "Did not find \"${i}\". Exiting..."
      exit 1
    fi
  done

  if [ ! -f "files/config.sh" ]; then
    echo "Did not find \"files/config.sh\". Exiting..."
    exit 1
  fi

  if [ ! -f "files/updater.sh" ]; then
    echo "Did not find \"files/updater.sh\". Exiting..."
    exit 1
  fi
}

last_warning() {
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
}

prepare_card() {
  # Unmount if mounted
  for ((i=${#CHROOT_BIND_MOUNTS[@]}; i>=0; i--)); do
    if [ "mount | grep ${MOUNTED_ROOT}/${CHROOT_BIND_MOUNTS[$i]}" ]; then
      umount "${MOUNTED_ROOT}/${CHROOT_BIND_MOUNTS[$i]}" >/dev/null 2>&1
    fi
  done

  for i in {1..10}; do
    if [ "mount | grep ${SDCARD_DEVICE}${i}" ]; then
      umount "${SDCARD_DEVICE}${i}" >/dev/null 2>&1
    fi
  done

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
    wget -q "${TARBALL}" -O "${WORKDIR}/${TARBALL##*/}"
  fi

  if [ ! -f "${WORKDIR}/${TARBALL##*/}.CONTENTS" ]; then
    wget -q "${TARBALL}.CONTENTS" -O "${WORKDIR}/${TARBALL##*/}.CONTENTS"
  fi

  if [ ! -f "${WORKDIR}/${TARBALL##*/}.DIGESTS" ]; then
    wget -q "${TARBALL}.DIGESTS" -O "${WORKDIR}/${TARBALL##*/}.DIGESTS"
  fi

  if [ ! -f "${WORKDIR}/${TARBALL##*/}.DIGESTS.asc" ]; then
    wget -q "${TARBALL}.DIGESTS.asc" -O "${WORKDIR}/${TARBALL##*/}.DIGESTS.asc"
  fi

  return 0
}

verify_stage3() {
  # Validating signatures
  if ! gpg --keyserver hkps.pool.sks-keyservers.net --recv-keys 0xBB572E0E2D182910 >/dev/null 2>&1; then
    echo -e "[${LRED}FAILED${NC}]: could not retrieve Gentoo PGP key. Do we have Interwebz?"
    exit 1
  fi
  if ! gpg --verify ${WORKDIR}/${TARBALL##*/}.DIGESTS.asc >/dev/null 2>&1; then
    echo -e "[${LRED}FAILED${NC}]: tarball PGP signature mismatch - you sure you download an official stage3 tarball?"
    exit 1
  fi

  # We have to omit non-H hashes first to verify integrity using H, where H is the chosen hash function for verification.
  grep SHA512 -A 1 --no-group-separator ${WORKDIR}/${TARBALL##*/}.DIGESTS > ${WORKDIR}/${TARBALL##*/}.DIGESTS.sha512
  cd "${WORKDIR}"
  if ! sha512sum -c ${WORKDIR}/${TARBALL##*/}.DIGESTS.sha512 >/dev/null 2>&1; then
    echo -e "[${LRED}FAILED${NC}]: tarball hash mismatch - did Gentoo mess up their hashes?"
    exit 1
  fi
  cd - >/dev/null 2>&1

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

  # Setting time zone
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

  # Adding your SSH pubkey to authorized_keys, if specified
  if [ -n "${SSH_PUBKEY}" ]; then
    if [ ! -d "${MOUNTED_ROOT}/root/.ssh" ]; then
      mkdir "${MOUNTED_ROOT}/root/.ssh"
    fi
    cat "${SSH_PUBKEY}" > "${MOUNTED_ROOT}/root/.ssh/authorized_keys"
    chmod 0600 "${MOUNTED_ROOT}/root/.ssh/authorized_keys"
  fi
  
  # Permit password authentication when SSH is wanted, but no ${SSH_PUBKEY} is specified
  if [ -n "${SSH}" ] && [ ! -n "${SSH_PUBKEY}" ]; then
    if ! sed "s/^PasswordAuthentication no$/PasswordAuthentication yes/g" -i "${MOUNTED_ROOT}/etc/ssh/sshd_config"; then
      echo -e "[${LRED}FAILED${NC}]: could not write to ${MOUNTED_ROOT}/etc/ssh/sshd_config"
      exit 1
    fi
  fi

  # Setting a different SSH port, if specified
  if [ -n "${SSH_PORT}" ]; then
    if ! sed "s/^#Port 22$/Port ${SSH_PORT}/g" -i "${MOUNTED_ROOT}/etc/ssh/sshd_config"; then
      echo -e "[${LRED}FAILED${NC}]: could not write to ${MOUNTED_ROOT}/etc/ssh/sshd_config"
      exit 1
    fi
  fi

  # Copying updater.sh and writing config.sh
  if [ -f "files/updater.sh" ]; then
    cp files/updater.sh "${MOUNTED_ROOT}/root/updater.sh"
    chmod 0700 "${MOUNTED_ROOT}/root/updater.sh"
  fi
  if [ -f "files/config.sh" ]; then
    awk '
      { print }
      /Collected vars from running the installation script will be hardcoded after this line/ {
      print "  DATE=\"'"${DATE}"'\""
      print "  HOSTNAME=\"'"${HOSTNAME}"'\""
      print "  NEW_USER=\"'"${NEW_USER}"'\""
      print "  NEW_USER_PASSWD=\"'"${NEW_USER_PASSWD}"'\""
      print "  NEW_USER_FULL_NAME=\"'"${NEW_USER_FULL_NAME}"'\""
      print "  ROOT_PASSWD=\"'"${ROOT_PASSWD}"'\""
      print "  SSH=\"'"${SSH}"'\""
      print "  SSH_PUBKEY=\"'"${SSH_PUBKEY}"'\""
      print "  HARDENED=\"'"${HARDENED}"'\""
      }' files/config.sh > "${MOUNTED_ROOT}/root/config.out"
    mv "${MOUNTED_ROOT}/root/config.out" "${MOUNTED_ROOT}/root/config.sh"
    chmod 0700 "${MOUNTED_ROOT}/root/config.sh"
  else
    echo -e "[${LRED}FAILED${NC}]: could not find files/updater.sh or could not write to ${MOUNTED_ROOT}/root/"
    exit 1
  fi

  # Comment out the s0 console (serial) for fix message in dmesg: "INIT: Id" s0 "respawning too fast".
  if ! sed -e '/^s0:.*/ s/^#*/#/' -i "${MOUNTED_ROOT}/etc/inittab"; then
    echo -e "[${LRED}FAILED${NC}]: could not write to ${MOUNTED_ROOT}/etc/inittab"
    exit 1
  fi

  # Adding 1.1.1.1 as a nameserver for chroot env. Will most likely be changed
  # by your local DHCP server upon first boot. Needed temporarily by
  # /root/updater.sh in chroot session.
  echo "nameserver 1.1.1.1" > "${MOUNTED_ROOT}/etc/resolv.conf"
}

install_rpi_firmware() {
  # Pulling and installing Raspberry Pi firmware.
  if ! git clone --depth 1 git://github.com/raspberrypi/firmware/ "${FIRMWARE_DIR}" >/dev/null 2>&1; then
    echo -e "[${LRED}FAILED${NC}]: could not git clone Raspberry Pi firmware to ${FIRMWARE_DIR}"
    exit 1
  fi
  rsync -a "${FIRMWARE_DIR}/boot/" "${MOUNTED_ROOT}/boot/"
  rsync -a "${FIRMWARE_DIR}/modules/" "${MOUNTED_ROOT}/lib/modules/"

  # Boot options
  echo "ipv6.disable=0 selinux=0 plymouth.enable=0 smsc95xx.turbo_mode=N dwc_otg.lpm_enable=0 console=ttyAMA0,115200 kgdboc=ttyAMA0,115200 console=tty1 root=${RPI_DEVICE_ROOT} rootfstype=ext4 elevator=noop rootwait" > "${MOUNTED_BOOT}/cmdline.txt"
}

prep_chroot() {
  # We'll be using Debian's qemu-static-user to chroot later
  if [ ! -f "${WORKDIR}/${QEMU_DEB##*/}" ]; then
    wget -q "${QEMU_DEB}" -O "${WORKDIR}/${QEMU_DEB##*/}"
  fi

  # Using alien to convert deb to tgz
  if [ ! -f "${WORKDIR}/${QEMU_TGZ}" ]; then
    if ! alien -t "${WORKDIR}/${QEMU_DEB##*/}" >/dev/null 2>&1; then
      echo -e "[${LRED}FAILED${NC}]: could not convert qemu-user-static Debian package to tarball using alien. Exiting..."
      exit 1
    fi

    if ! mv "${QEMU_TGZ}" "${WORKDIR}/${QEMU_TGZ}"; then
      echo -e "[${LRED}FAILED${NC}]: could not move ${QEMU_TGZ} to ${WORKDIR}/${QEMU_TGZ}. Exiting..."
      exit 1
    fi
  fi

  if [ ! -d "${WORKDIR}/qemu-user-static" ]; then
    mkdir "${WORKDIR}/qemu-user-static"
  fi

  if ! tar xzpf "${WORKDIR}/${QEMU_TGZ}" -C "${WORKDIR}/qemu-user-static"; then
    echo -e "[${LRED}FAILED${NC}]: could not untar ${QEMU_TGZ}. Exiting..."
    exit 1
  fi

  # Copy qemu-arm-static to card in order to chroot
  if ! cp "${WORKDIR}/qemu-user-static/usr/bin/qemu-arm-static" "${MOUNTED_ROOT}/usr/bin/qemu-arm"; then
    echo -e "[${LRED}FAILED${NC}]: could not copy "${WORKDIR}/qemu-user-static/usr/bin/qemu-arm-static" to "${MOUNTED_ROOT}/usr/bin/qemu-arm". Exiting..."
    exit 1
  fi

  # Loading binfmt_misc kernel module
  if [ ! -d /proc/sys/fs/binfmt_misc ]; then
    if ! modprobe binfmt_misc; then
      echo -e "[${LRED}FAILED${NC}]: could not load kernel module binfmt_misc. Exiting..."
      exit 1
    fi
  fi

  if ! [ -f /proc/sys/fs/binfmt_misc/register ]; then
    mount binfmt_misc -t binfmt_misc /proc/sys/fs/binfmt_misc 
  fi

  # Registering arm handler for qemu-binfmt
  echo ':arm:M::\x7fELF\x01\x01\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x02\x00\x28\x00:\xff\xff\xff\xff\xff\xff\xff\x00\xff\xff\xff\xff\xff\xff\xff\xff\xfe\xff\xff\xff:/qemu-wrapper:' > /proc/sys/fs/binfmt_misc/register >/dev/null 2>&1

  # (Re)starting qemu-binfmt
  if which rc-service >/dev/null 2>&1; then
    rc-service qemu-binfmt restart >/dev/null 2>&1
  elif which systemctl >/dev/null 2>&1; then
    systemctl restart systemd-binfmt >/dev/null 2>&1
  fi

  # Bind mounting for chroot env
  for i in ${CHROOT_BIND_MOUNTS[@]}; do
    mount --bind /${i} "${MOUNTED_ROOT}/${i}"
  done
}

eject_card() {
  sync
  for ((i=${#CHROOT_BIND_MOUNTS[@]}; i>=0; i--)); do
    umount "${MOUNTED_ROOT}/${CHROOT_BIND_MOUNTS[$i]}"
  done
  umount "${MOUNTED_BOOT}"
  umount "${MOUNTED_ROOT}"
  eject "${SDCARD_DEVICE}"
}

get_args "$@"
get_vars
test_args
test_deps
last_warning

echo
echo -n '>>> Partitioning card ..................................... '
if prepare_card ; then
  echo -e "${BLUE}[${NC} ${LGREEN}ok${NC} ${BLUE}]${NC}"
fi

echo -n '>>> Downloading stage3 tarball ............................ '
if download_stage3 ; then
  echo -e "${BLUE}[${NC} ${LGREEN}ok${NC} ${BLUE}]${NC}"
fi

echo -n '>>> Verifying stage3 tarball .............................. '
if verify_stage3 ; then
  echo -e "${BLUE}[${NC} ${LGREEN}ok${NC} ${BLUE}]${NC}"
fi

echo -n '>>> Installing Gentoo ..................................... '
if install_gentoo ; then
  echo -e "${BLUE}[${NC} ${LGREEN}ok${NC} ${BLUE}]${NC}"
fi

echo -n '>>> Installing Portage .................................... '
if install_portage ; then
  echo -e "${BLUE}[${NC} ${LGREEN}ok${NC} ${BLUE}]${NC}"
fi

echo -n '>>> Configuring Gentoo .................................... '
if configure_gentoo ; then
  echo -e "${BLUE}[${NC} ${LGREEN}ok${NC} ${BLUE}]${NC}"
fi

echo -n '>>> Installing the latest binary Raspberry Pi firmware .... '
if install_rpi_firmware ; then
  echo -e "${BLUE}[${NC} ${LGREEN}ok${NC} ${BLUE}]${NC}"
fi

echo -n '>>> Preparing chroot ...................................... '
if prep_chroot ; then
  echo -e "${BLUE}[${NC} ${LGREEN}ok${NC} ${BLUE}]${NC}"
fi

echo
echo '--- Chrooting to card ---'
echo
chroot "${MOUNTED_ROOT}" /root/config.sh
echo
echo '--- Returning to host ---'
echo

echo -n '>>> Synchronising cached writes to card and eject card .... '
if eject_card ; then
  echo -e "${BLUE}[${NC} ${LGREEN}ok${NC} ${BLUE}]${NC}"
fi

echo
echo "Installation complete. Try booting your Raspberry Pi."
