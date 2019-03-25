#!/bin/sh

# WARNING: THIS SCRIPT IS NOT READY FOR PRODUCTION YET. HERE BE DRAGONS.

# Installing Gentoo using stage3 on a Raspberry Pi. This guide assumes a Linux
# amd64 workstation to prepare the SD card and to finish it using qemu/chroot.

# Help function
print_help() {
  echo "Gentoo Pi installer, version 0.1"
  echo "Usage: $0 [-d DEVICE|-i IMAGE] [option] ..." >&2
  echo
  echo "  -h, --help           display this help and exit"
  echo "  -d, --device         card to write to (e.g. /dev/sde)"
  echo "  -i, --image-file     specify an image file name to write to, instead "
  echo "                       of a block device (e.g. ~/image.bin)"
  echo
  echo "Options:"
  echo "  -p, --password       specify your preferred password (e.g. "
  echo "                       correcthorsebatterystaple)"
  echo "  -r, --root-password  specify your preferred password for root (e.g. "
  echo "                       correcthorsebatterystaple)"
  echo "  -H, --hostname       specify a different hostname (e.g. gentoo)"
  echo "  -t, --timezone       Specify a different timezone (e.g. "
  echo "                       Europe/Amsterdam)"
  echo "  -u, --username       specify your preferred username (e.g. larry)"
  echo "  -f, --fullname       specify your full name (e.g. \"Larry the Cow\")"
  echo "  -T, --tarball-url    optionally set a different stage3 tarball URL "
  echo "                       (e.g. http://distfiles.gentoo.org/releases/\\"
  echo "                       arm/autobuilds/20180831/\\"
  echo "                       stage3-armv7a_hardfp-20180831.tar.bz2)"
  echo "  -s, --ssh            optionally enable SSH"
  echo "      --ssh-port       optionally set a different SSH port (e.g. 2222)"
  echo "      --ssh-pubkey     optionally set your ssh pubkey (e.g. "
  echo "                       ~/.ssh/id_ed25519.pub)"
  echo "      --hardened       optionally switch to a hardened profile "
  echo "                       (experimental)"
  echo "  -R, --encrypt-root   optionally specify your preferred password to "
  echo "                       encrypt the root partition with (e.g. "
  echo "                       correcthorsebatterystaple"
  echo "  -S, --encrypt-swap   optionally encrypt the swap partition with a "
  echo "                       random IV each time the system boots"
  echo
  exit 0
}

get_args() {
  while [[ "$1" ]]; do
    case "$1" in
      -h|--help) print_help ;;
      -d|--device) SDCARD_DEVICE="${2}" ;;
      -i|--image) IMAGE_FILE=$(readlink -m "${2}") ;;
      -T|--tarball-url) TARBALL="${2}" ;;
      -H|--hostname) HOSTNAME="${2}" ;;
      -t|--timezone) TIMEZONE="${2}" ;;
      -u|--username) NEW_USER="${2}" ;;
      -p|--password) NEW_USER_PASSWD="${2}" ;;
      -f|--fullname) NEW_USER_FULL_NAME="${2}" ;;
      -r|--root-password) ROOT_PASSWD="${2}" ;;
      -s|--ssh) SSH="1" ;;
         --ssh-pubkey) SSH_PUBKEY=$(readlink -m "${2}") ;;
         --ssh-port) SSH_PORT="{2}" ;;
         --hardened) HARDENED="1" ;;
      -R|--encrypt-root) LUKS_PASSPHRASE="${2}" ;;
      -S|--encrypt-swap) CRYPT_SWAP="1" ;;
    esac
    shift
  done
}

get_vars() {
  # Terminal colours
  #GREEN='\033[0;32m'
  BLUE='\033[0;34m'
  #MAGENTA='\033[0;35m'
  LGREEN='\033[1;32m'
  LRED='\033[1;31m'
  YELLOW='\033[1;33m'
  NC='\033[0m'

  # Print "failed" or "ok" in colour
  FAILED="${BLUE}[${NC} ${LRED}!!${NC} ${BLUE}]${NC}"
  OK="${BLUE}[${NC} ${LGREEN}ok${NC} ${BLUE}]${NC}"

  # Binaries we expect in PATH to run this script in the first place. However,
  # other commands such as "cd", "echo", and "exit" are assumed to be built-in
  # shell commands. In case of any errors, refer to the README.md to verify the
  # dependencies on your system.
  DEPS=(alien awk chroot cat chmod cp cryptsetup curl eject file git gpg grep \
        mkdir mkfs.ext4 mkfs.vfat mkswap modprobe mount parted qemu-arm rm \
        rsync sed sha512sum sync tar umount useradd wget)

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

  # The following entries will be inserted in fstab on the SD card
  RPI_DEVICE="/dev/mmcblk0"
  RPI_DEVICE_BOOT="${RPI_DEVICE}p1"
  RPI_DEVICE_SWAP="${RPI_DEVICE}p2"
  if [ -n "${LUKS_PASSPHRASE}" ]; then
    LUKS_ROOT_NAME="gentoopi-root"
    RPI_DEVICE_ROOT_RAW="${RPI_DEVICE}p3"
    RPI_DEVICE_ROOT="/dev/mapper/${LUKS_ROOT_NAME}"
  else
    RPI_DEVICE_ROOT="${RPI_DEVICE}p3"
  fi

  # We'll use the latest qemu-static-user package from Debian to easily chroot
  # later. We will download this package from a random mirror.
  QEMU_SHUF=$(curl -s https://packages.debian.org/sid/amd64/qemu-user-static/download | grep -o "ftp\...\.debian.org/debian" | sort | uniq | shuf -n 1)
  QEMU_DEB=$(curl -s https://packages.debian.org/sid/amd64/qemu-user-static/download | grep -o http://${QEMU_SHUF}/pool/main/q/qemu/qemu-user-static.\*_amd64.deb)

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

randpw() {
  < /dev/urandom tr -dc _A-Z-a-z-0-9 | head -c${1:-16}
  echo
}

test_args() {
  if [ ! -n "${SDCARD_DEVICE}" ] && [ ! -n "${IMAGE_FILE}" ]; then
    printf "-d|--device, xor -i|--image-file not set. Exiting...\n"
    exit 1
  elif [ -n "${SDCARD_DEVICE}" ] && [ -n "${IMAGE_FILE}" ]; then
    printf "-d|--device, and -i|--image-file are both set. Specify only one! Exiting...\n"
    exit 1
  elif [ -n "${SDCARD_DEVICE}" ]; then
    if [ ! -b "${SDCARD_DEVICE}" ]; then
      printf "${SDCARD_DEVICE} not found. Exiting...\n"
      exit 1
    fi
  fi

  if [ ! -n "${TARBALL}" ]; then
    LATEST_TARBALL="$(curl -s http://distfiles.gentoo.org/releases/arm/autobuilds/latest-stage3-armv7a_hardfp.txt | tail -n 1 | awk '{print $1}')"
    TARBALL="http://distfiles.gentoo.org/releases/arm/autobuilds/${LATEST_TARBALL}"
    if ! curl -Ifs ${TARBALL} >/dev/null 2>&1; then
      printf "Latest tarball not found - please file a bug? Exiting...\n"
      exit 1
    fi
  elif ! curl -Ifs ${TARBALL} >/dev/null 2>&1; then
    printf "Overridden tarball not found. Exiting...\n"
    exit 1
  fi

  if [ ! -n "${HOSTNAME}" ]; then
    HOSTNAME="gentoopi"
  fi

  if [ ! -n "${TIMEZONE}" ]; then
    TIMEZONE="Europe/London"
  elif [ ! -f "/usr/share/zoneinfo/${TIMEZONE}" ]; then
    printf "Invalid time zone. Exiting...\n"
    exit 1
  fi

  if [ ! -n "${NEW_USER}" ]; then
    NEW_USER="pi"
  fi

  if [ ! -n "${NEW_USER_PASSWD}" ]; then
    NEW_USER_PASSWD=$(randpw)
  fi

  if [ ! -n "${NEW_USER_FULL_NAME}" ]; then
    NEW_USER_FULL_NAME="Gentoo Pi user"
  fi

  if [ ! -n "${ROOT_PASSWD}" ]; then
    ROOT_PASSWD=$(randpw)
  fi

  if [ -n "${SSH_PUBKEY}" ]; then
    if [[ $(file "${SSH_PUBKEY}") != *OpenSSH*public\ key ]]; then
      printf "Invalid SSH public key. Exiting...\n"
      exit 1
    fi
  fi
}

test_deps() {
  for i in "${DEPS[@]}"; do
    if ! which ${i} >/dev/null 2>&1; then
      printf "Did not find \"${i}\". Exiting...\n"
      exit 1
    fi
  done

  if [ ! -f "files/config.sh" ]; then
    printf "Did not find \"files/config.sh\". Exiting...\n"
    exit 1
  fi

  if [ ! -f "files/updater.sh" ]; then
    printf "Did not find \"files/updater.sh\". Exiting...\n"
    exit 1
  fi
}

last_warning() {
  # Last warning before formatting ${SDCARD_DEVICE} or ${IMAGE_FILE}
  if [ -b "${SDCARD_DEVICE}" ]; then
    printf "\n${YELLOW}* WARNING: This will format ${SDCARD_DEVICE}:${NC}\n\n"
    parted "${SDCARD_DEVICE}" print
  elif [ -f "${IMAGE_FILE}" ]; then
    printf "\n${YELLOW}* WARNING: This will format ${IMAGE_FILE}:${NC}\n\n"
    parted "${IMAGE_FILE}" print
  fi
  if [ -f "${IMAGE_FILE}" ] || [ -b "${SDCARD_DEVICE}" ]; then
    while true; do
      read -p "Do you wish to continue formatting this device? [yes|no] " yn
      case $yn in
        [Yy]* ) break ;;
        [Nn]* ) exit 0 ;;
        * ) echo "Please answer yes or no." ;;
      esac
    done
  fi
}

prepare_card() {
  # Creating work dir
  if [ ! -d "${WORKDIR}" ]; then
    mkdir "${WORKDIR}"
  fi

  sync
  # Unmounting CHROOT_BIND_MOUNTS in reverse order, if needed
  for ((i=${#CHROOT_BIND_MOUNTS[@]}; i>=0; i--)); do
    if mount | grep "${MOUNTED_ROOT}/${CHROOT_BIND_MOUNTS[$i]}" >/dev/null 2>&1; then
      umount "${MOUNTED_ROOT}/${CHROOT_BIND_MOUNTS[$i]}" >/dev/null 2>&1
    fi
  done

  # Unmounting all other card partitions, if needed
  if mount | grep "${MOUNTED_BOOT}" >/dev/null 2>&1; then
    umount "${MOUNTED_BOOT}" >/dev/null 2>&1
  fi

  if mount | grep "${MOUNTED_ROOT}" >/dev/null 2>&1; then
    umount "${MOUNTED_ROOT}" >/dev/null 2>&1
  fi

  if [ -b "/dev/mapper/${LUKS_ROOT_NAME}" ]; then
    cryptsetup luksClose "${LUKS_ROOT_NAME}"
  fi

  for i in {1..10}; do
    if mount | grep "${SDCARD_DEVICE}${i}" >/dev/null 2>&1; then
      umount "${SDCARD_DEVICE}${i}" >/dev/null 2>&1
    fi
  done

  if [ -n "${IMAGE_FILE}" ]; then
    losetup -D
    if [ -n "${IMAGE_FILE}" ]; then
      if [ -f "${IMAGE_FILE}" ]; then
        rm "${IMAGE_FILE}"
      fi
      if fallocate -l 16G "${IMAGE_FILE}"; then
        SDCARD_DEVICE=/dev/loop0
        SDCARD_DEVICE_BOOT="${SDCARD_DEVICE}p1"
        SDCARD_DEVICE_SWAP="${SDCARD_DEVICE}p2"
        SDCARD_DEVICE_ROOT="${SDCARD_DEVICE}p3"
      elif ! fallocate -l 16G "${IMAGE_FILE}"; then
        printf "Cannot write to ${IMAGE_FILE} - check your permissions / free disk space. Exiting...\n"
        exit 1
      fi
    fi
  fi

  # Partition card (tweak sizes if required) Huge swap of 8 GiB, because some
  # packages require an insane amount of memory. Chromium, I'm looking at you!
  # Also, last partition (root) intentionally 95%, to make sure one can always
  # create a full dd image, and then restore on a different card, with a
  # slightly different total size.
  if [ -n "${IMAGE_FILE}" ]; then
    losetup -Pf "${IMAGE_FILE}" 
  fi

  if ! parted --script "${SDCARD_DEVICE}" \
    mklabel msdos \
    mkpart primary fat32 1MiB 64MiB \
    set 1 lba on \
    set 1 boot on \
    mkpart primary linux-swap 64MiB 8256MiB \
    mkpart primary 8256MiB 95% \
    print >/dev/null 2>&1; then
      printf "${FAILED}\n\nPartitioning failed. Exiting...\n"
      exit 1
  fi

  if [ -n "${LUKS_PASSPHRASE}" ]; then
    # WIP: use password-protected GPG key to unlock LUKS
    # Generate a random secret to encrypt with ${LUKS_PASSPHRASE}
    # LUKS_SECRET="$(head -c60 /dev/urandom | base64 | head -n1 | tr -d '\n')"
    # echo "${LUKS_SECRET}" | gpg --batch --passphrase "${LUKS_PASSPHRASE}" --symmetric --cipher-algo aes256 > "${WORKDIR}/root.gpg"

    # Use random secret to encrypt root partition with, and then open it
    # gpg --quiet --batch --passphrase "${LUKS_PASSPHRASE}" --decrypt "${WORKDIR}/root.gpg" | cryptsetup -h sha512 -c aes-xts-plain64 -s 512 luksFormat --align-payload=8192 "${SDCARD_DEVICE_ROOT}" || return $?
    # gpg --quiet --batch --passphrase "${LUKS_PASSPHRASE}" --decrypt "${WORKDIR}/root.gpg" | cryptsetup open --type luks "${SDCARD_DEVICE_ROOT}" "${LUKS_ROOT_NAME}" || return $?

    # USe passphrase to encrypt root partition with, and then open it
    printf "${LUKS_PASSPHRASE}" | cryptsetup -h sha512 -c aes-xts-plain64 -s 512 luksFormat --align-payload=8192 "${SDCARD_DEVICE_ROOT}" || exit 1
    printf "${LUKS_PASSPHRASE}" | cryptsetup open --type luks "${SDCARD_DEVICE_ROOT}" "${LUKS_ROOT_NAME}" || exit 1

    # We will no longer use the raw partition, but rather the unlocked, named
    # LUKS partition
    SDCARD_DEVICE_ROOT="/dev/mapper/${LUKS_ROOT_NAME}"
  fi

  # Formatting new partitions
  if ! yes | mkfs.vfat -F 32 "${SDCARD_DEVICE_BOOT}" >/dev/null 2>&1; then
    printf "${FAILED}\n\nFormatting ${SDCARD_DEVICE_BOOT} failed. Exiting...\n"
    exit 1
  fi
  if [ ! -n "${CRYPT_SWAP}" ]; then
    if ! yes | mkswap "${SDCARD_DEVICE_SWAP}" >/dev/null 2>&1; then
      printf "${FAILED}\n\nFormatting ${SDCARD_DEVICE_SWAP} failed. Exiting...\n"
      exit 1
    fi
  fi
  if ! yes | mkfs.ext4 "${SDCARD_DEVICE_ROOT}" >/dev/null 2>&1; then
    printf "${FAILED}\n\nFormatting ${SDCARD_DEVICE_ROOT} failed. Exiting...\n"
    exit 1
  fi

  # Mount root and boot partitions for installation
  rm -rf "${MOUNTED_ROOT}"
  mkdir "${MOUNTED_ROOT}"

  if ! mount "${SDCARD_DEVICE_ROOT}" "${MOUNTED_ROOT}"; then
    printf "${FAILED}\n\nMounting ${SDCARD_DEVICE_ROOT} on ${MOUNTED_ROOT} failed. Exiting...\n"
    exit 1
  fi
  mkdir "${MOUNTED_BOOT}"
  if ! mount "${SDCARD_DEVICE_BOOT}" "${MOUNTED_BOOT}"; then
    printf "${FAILED}\n\nMounting ${SDCARD_DEVICE_BOOT} on ${MOUNTED_BOOT} failed. Exiting...\n"
    exit 1
  fi

  # WIP: use password-protected GPG key to unlock LUKS
  # Copy root.gpg if needed
  # if [ -n "${LUKS_PASSPHRASE}" ]; then
  #   mv "${WORKDIR}/root.gpg" "${MOUNTED_BOOT}/root.gpg"
  # fi
}

download_tarball() {
  # Downloading tarball and signatures
  if [ ! -f "${WORKDIR}/${TARBALL##*/}" ]; then
    wget -q "${TARBALL}" -O "${WORKDIR}/${TARBALL##*/}"
  fi

  if [ ! -f "${WORKDIR}/${TARBALL##*/}.CONTENTS" ]; then
    wget -q "${TARBALL}.CONTENTS" -O "${WORKDIR}/${TARBALL##*/}.CONTENTS"
  fi

  if [ ! -f "${WORKDIR}/${TARBALL##*/}.DIGESTS" ]; then
    wget -q "${TARBALL}.DIGESTS" -O "${WORKDIR}/${TARBALL##*/}.DIGESTS"
  fi

  # I realised not all tarball hashes are signed
  if [ ! -f "${WORKDIR}/${TARBALL##*/}.DIGESTS.asc" ]; then
    if curl -Ifs "${TARBALL}.DIGESTS.asc" >/dev/null 2>&1; then
      wget -q "${TARBALL}.DIGESTS.asc" -O "${WORKDIR}/${TARBALL##*/}.DIGESTS.asc"
    fi
  fi

  return 0
}

verify_tarball() {
  # Validating signatures
  if ! gpg --keyserver hkps.pool.sks-keyservers.net --recv-keys 0xBB572E0E2D182910 >/dev/null 2>&1; then
    if ! gpg --keyserver hkp://keyserver.ubuntu.com --recv-keys 0xBB572E0E2D182910 >/dev/null 2>&1; then
      printf "${FAILED}\n\nCould not retrieve Gentoo PGP key. Do we have Interwebz? Exiting...\n"
      exit 1
    fi
  fi

  # I realised not all tarball hashes are signed
  if [ -f "${WORKDIR}/${TARBALL##*/}.DIGESTS.asc" ]; then
    if ! gpg --verify "${WORKDIR}/${TARBALL##*/}.DIGESTS.asc" >/dev/null 2>&1; then
      printf "${FAILED}\n\nTarball PGP signature mismatch - you sure you download an official tarball? Exiting...\n"
      exit 1
    fi
  fi

  # We have to omit non-H hashes first to verify integrity using H, where H is
  # the chosen hash function for verification.
  grep SHA512 -A 1 --no-group-separator "${WORKDIR}/${TARBALL##*/}.DIGESTS" > "${WORKDIR}/${TARBALL##*/}.DIGESTS.sha512"
  cd "${WORKDIR}" || $(printf "${FAILED}\n\nCannot cd to ${WORKDIR}" ; exit 1)
  if ! sha512sum -c ${WORKDIR}/${TARBALL##*/}.DIGESTS.sha512 >/dev/null 2>&1; then
    printf "${FAILED}\n\nTarball hash mismatch - did Gentoo mess up their hashes? Exiting...\n"
    exit 1
  fi
  cd - >/dev/null 2>&1 || $(printf "${FAILED}\n\nCannot cd back to working directory" ; exit 1)

  return 0
}

install_gentoo() {
  if ! tar xfpj "${WORKDIR}/${TARBALL##*/}" -C "${MOUNTED_ROOT}" >/dev/null 2>&1; then
    printf "${FAILED}\n\nCould not untar ${WORKDIR}/${TARBALL##*/} to ${MOUNTED_ROOT}/usr/. Exiting...\n"
    exit 1
  fi

  return 0
}

install_portage() {
  # Installing Gentoo
  if [ ! -f "${WORKDIR}/portage-latest.tar.bz2" ]; then
    wget -q "http://distfiles.gentoo.org/snapshots/portage-latest.tar.bz2" -O "${WORKDIR}/portage-latest.tar.bz2"
  fi

  if ! tar xfpj "${WORKDIR}/portage-latest.tar.bz2" -C "${MOUNTED_ROOT}/usr/" >/dev/null 2>&1; then
    printf "${FAILED}\n\nCould not untar ${WORKDIR}/portage-latest.tar.bz2 to ${MOUNTED_ROOT}/usr/. Exiting...\n"
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
    printf "${FAILED}\n\nCould not find ${MOUNTED_ROOT}/etc/portage/make.conf. Exiting...\n"
    exit 1
  fi

  # Configuring /etc/fstab
  if [ -f "${MOUNTED_ROOT}/etc/fstab" ]; then
    sed -e '/\/dev/ s/^#*/#/' -i "${MOUNTED_ROOT}/etc/fstab" # uncomments existing entries
    echo "proc           /proc proc defaults         0 0" >> "${MOUNTED_ROOT}/etc/fstab"
    if [ -n "${CRYPT_SWAP}" ]; then
      echo "/dev/mapper/swap /boot vfat defaults         0 2" >> "${MOUNTED_ROOT}/etc/fstab"
    else
      echo "${RPI_DEVICE_BOOT} /boot vfat defaults         0 2" >> "${MOUNTED_ROOT}/etc/fstab"
    fi
    echo "${RPI_DEVICE_SWAP} none  swap sw               0 0" >> "${MOUNTED_ROOT}/etc/fstab"
    if [ -n "${LUKS_PASSPHRASE}" ]; then
      echo "/dev/mapper/root /     ext4 defaults,noatime 0 1" >> "${MOUNTED_ROOT}/etc/fstab"
    else
      echo "${RPI_DEVICE_ROOT} /     ext4 defaults,noatime 0 1" >> "${MOUNTED_ROOT}/etc/fstab"
    fi
  else
    printf "${FAILED}\n\nCould not find ${MOUNTED_ROOT}/etc/fstab. Exiting...\n"
    exit 1
  fi

  # Setting time zone
  if [ -f "${MOUNTED_ROOT}/usr/share/zoneinfo/${TIMEZONE}" ]; then
    cp "${MOUNTED_ROOT}/usr/share/zoneinfo/${TIMEZONE}" "${MOUNTED_ROOT}/etc/localtime"
    echo "${TIMEZONE}" > "${MOUNTED_ROOT}/etc/timezone"
  else
    printf "${FAILED}\n\nCould not find ${MOUNTED_ROOT}/usr/share/zoneinfo/${TIMEZONE}. Exiting...\n"
    exit 1
  fi

  # Clearing root passwd
  if [ -f "${MOUNTED_ROOT}/etc/shadow" ]; then
    sed -i 's/^root:.*/root::::::::/' "${MOUNTED_ROOT}/etc/shadow"
  else
    printf "${FAILED}\n\nCould not find ${MOUNTED_ROOT}/etc/shadow. Exiting...\n"
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
  
  # Permit password authentication when SSH is wanted, but no ${SSH_PUBKEY} is
  # specified
  if [ -n "${SSH}" ] && [ ! -n "${SSH_PUBKEY}" ]; then
    if ! sed "s/^PasswordAuthentication no$/PasswordAuthentication yes/g" -i "${MOUNTED_ROOT}/etc/ssh/sshd_config"; then
      printf "${FAILED}\n\nCould not write to ${MOUNTED_ROOT}/etc/ssh/sshd_config. Exiting...\n"
      exit 1
    fi
  fi

  # Setting a different SSH port, if specified
  if [ -n "${SSH_PORT}" ]; then
    if ! sed "s/^#Port 22$/Port ${SSH_PORT}/g" -i "${MOUNTED_ROOT}/etc/ssh/sshd_config"; then
      printf "${FAILED}\n\nCould not write to ${MOUNTED_ROOT}/etc/ssh/sshd_config. Exiting...\n"
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
      print "  LUKS_PASSPHRASE=\"'"${LUKS_PASSPHRASE}"'\""
      print "  CRYPT_SWAP=\"'"${CRYPT_SWAP}"'\""
      print "  RPI_DEVICE_ROOT=\"'"${RPI_DEVICE_ROOT}"'\""
      print "  RPI_DEVICE_ROOT_RAW=\"'"${RPI_DEVICE_ROOT_RAW}"'\""
      }' files/config.sh > "${MOUNTED_ROOT}/root/config.out"
    mv "${MOUNTED_ROOT}/root/config.out" "${MOUNTED_ROOT}/root/config.sh"
    chmod 0700 "${MOUNTED_ROOT}/root/config.sh"
  else
    printf "${FAILED}\n\nCould not find files/updater.sh or could not write to ${MOUNTED_ROOT}/root/. Exiting...\n"
    exit 1
  fi

  # Comment out the s0 console (serial) to fix message in dmesg which is
  # otherwise spammed on-screen: "INIT: Id" s0 "respawning too fast".
  if ! sed -e '/^s0:.*/ s/^#*/#/' -i "${MOUNTED_ROOT}/etc/inittab"; then
    printf "${FAILED}\n\nCould not write to ${MOUNTED_ROOT}/etc/inittab. Exiting...\n"
    exit 1
  fi

  # Adding 1.1.1.1 as a nameserver for chroot env. Will most likely be changed
  # by your local DHCP server upon first boot. Needed temporarily in chroot.
  echo "nameserver 1.1.1.1" > "${MOUNTED_ROOT}/etc/resolv.conf"
}

prep_chroot() {
  # We'll be using Debian's qemu-static-user to chroot later
  if [ ! -f "${WORKDIR}/${QEMU_DEB##*/}" ]; then
    wget -q "${QEMU_DEB}" -O "${WORKDIR}/${QEMU_DEB##*/}"
  fi

  # Using alien to convert deb to tgz
  if [ ! -f "${WORKDIR}/${QEMU_TGZ}" ]; then
    if ! alien -t "${WORKDIR}/${QEMU_DEB##*/}" >/dev/null 2>&1; then
      printf "${FAILED}\n\nCould not convert qemu-user-static Debian package to tarball using alien. Exiting...\n"
      exit 1
    fi

    if ! mv "${QEMU_TGZ}" "${WORKDIR}/${QEMU_TGZ}"; then
      printf "${FAILED}\n\nCould not move ${QEMU_TGZ} to ${WORKDIR}/${QEMU_TGZ}. Exiting...\n"
      exit 1
    fi
  fi

  if [ ! -d "${WORKDIR}/qemu-user-static" ]; then
    mkdir "${WORKDIR}/qemu-user-static"
  fi

  if ! tar xzpf "${WORKDIR}/${QEMU_TGZ}" -C "${WORKDIR}/qemu-user-static"; then
    printf "${FAILED}\n\nCould not untar ${QEMU_TGZ}. Exiting...\n"
    exit 1
  fi

  # Copy qemu-arm-static to card in order to chroot
  if ! cp "${WORKDIR}/qemu-user-static/usr/bin/qemu-arm-static" "${MOUNTED_ROOT}/usr/bin/qemu-arm"; then
    printf "${FAILED}\n\nCould not copy "${WORKDIR}/qemu-user-static/usr/bin/qemu-arm-static" to "${MOUNTED_ROOT}/usr/bin/qemu-arm". Exiting...\n"
    exit 1
  fi

  # Loading binfmt_misc kernel module
  if [ ! -d /proc/sys/fs/binfmt_misc ]; then
    if ! modprobe binfmt_misc; then
      printf "${FAILED}\n\nCould not load kernel module binfmt_misc. Exiting...\n"
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
  for i in "${CHROOT_BIND_MOUNTS[@]}"; do
    mount --bind /${i} "${MOUNTED_ROOT}/${i}"
  done
}

eject_card() {
  sync
  for ((i=${#CHROOT_BIND_MOUNTS[@]}; i>=0; i--)); do
    umount "${MOUNTED_ROOT}/${CHROOT_BIND_MOUNTS[$i]}"
  done
  umount "${MOUNTED_ROOT}"
  if [ -n "${LUKS_PASSPHRASE}" ]; then
    cryptsetup luksClose "${LUKS_ROOT_NAME}"
  fi
  if [ -n "${IMAGE_FILE}" ]; then
    losetup -D
  elif [ ! -n "${IMAGE_FILE}" ]; then
    eject "${SDCARD_DEVICE}"
  fi
}

get_args "$@"
get_vars
test_args
test_deps
last_warning

printf '\n>>> Partitioning device\t' | expand -t 60
if prepare_card ; then
  printf "${OK}\n"
fi

printf '>>> Downloading tarball\t' | expand -t 60
if download_tarball ; then
  printf "${OK}\n"
fi

printf '>>> Verifying tarball\t' | expand -t 60
if verify_tarball ; then
  printf "${OK}\n"
fi

printf '>>> Installing Gentoo\t' | expand -t 60
if install_gentoo ; then
  printf "${OK}\n"
fi

printf '>>> Installing Portage\t' | expand -t 60
if install_portage ; then
  printf "${OK}\n"
fi

printf '>>> Configuring Gentoo\t' | expand -t 60
if configure_gentoo ; then
  printf "${OK}\n"
fi

printf '>>> Preparing chroot\t' | expand -t 60
if prep_chroot ; then
  printf "${OK}\n"
fi

printf '\n--- Chrooting to device ---\n\n'
chroot "${MOUNTED_ROOT}" /root/config.sh
printf '\n--- Returning to host ---\n\n'

printf '>>> Synchronising all pending writes and dismounting\t' | expand -t 60
if eject_card ; then
  printf "${OK}\n"
fi

printf "\nInstallation complete. You can try to boot your Gentoo Pi and login\n"
printf "with the following credentials:\n"
printf "* ${NEW_USER}:${NEW_USER_PASSWD}\n"
printf "* root:${ROOT_PASSWD}\n"