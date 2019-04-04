#!/usr/bin/env bash

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
  echo "  -a, --architecture   optionally specify the desired architecture "
  echo "                       (e.g. 64)"
  echo "  -s, --stage          optionally specify the desired stage (e.g. 4)"
  echo "  -T, --tarball-url    optionally set a different stage3 tarball URL "
  echo "                       (e.g. http://distfiles.gentoo.org/releases/\\"
  echo "                       arm/autobuilds/20180831/\\"
  echo "                       stage3-armv7a_hardfp-20180831.tar.bz2). Please "
  echo "                       update --arch and --stage accordingly"
  echo "      --ssh            optionally enable SSH"
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
  echo "  -V, --verify         specify whether to verify tarball before "
  echo "                       installing with a boolean (e.g. 0)"
  echo
  exit 0
}

get_args() {
  while [[ "$1" ]]; do
    case "$1" in
      -h|--help) print_help ;;
      -d|--device) SDCARD_DEVICE="${2}" ;;
      -i|--image) IMAGE_FILE=$(readlink -m "${2}") ;;
      -a|--architecture) ARCH="${2}" ;;
      -s|--stage) STAGE="${2}" ;;
      -T|--tarball-url) TARBALL="${2}" ;;
      -H|--hostname) HOSTNAME="${2}" ;;
      -t|--timezone) TIMEZONE="${2}" ;;
      -u|--username) NEW_USER="${2}" ;;
      -p|--password) NEW_USER_PASSWD="${2}" ;;
      -f|--fullname) NEW_USER_FULL_NAME="${2}" ;;
      -r|--root-password) ROOT_PASSWD="${2}" ;;
         --ssh) SSH="1" ;;
         --ssh-pubkey) SSH_PUBKEY=$(readlink -m "${2}") ;;
         --ssh-port) SSH_PORT="{2}" ;;
         --hardened) HARDENED="1" ;;
      -R|--encrypt-root) LUKS_PASSPHRASE="${2}" ;;
      -S|--encrypt-swap) CRYPT_SWAP="1" ;;
      -V|--verify) VERIFY="${2}"
    esac
    shift
  done
}

get_vars() {
  # Terminal colours
  # GREEN=$'\033[0;32m'
  BLUE=$'\033[0;34m'
  # MAGENTA=$'\033[0;35m'
  LGREEN=$'\033[1;32m'
  LRED=$'\033[1;31m'
  YELLOW=$'\033[1;33m'
  NC=$'\033[0m'

  # Print "[ !! ]" or "[ OK ]" in colour
  FAILED="${BLUE}[${NC} ${LRED}!!${NC} ${BLUE}]${NC}"
  OK="${BLUE}[${NC} ${LGREEN}ok${NC} ${BLUE}]${NC}"

  # Binaries we expect in PATH to run this script in the first place. However,
  # other commands such as "cd", "echo", and "exit" are assumed to be built-in
  # shell commands. In case of any errors, refer to the README.md to verify the
  # dependencies on your system.
  DEPS=(
    awk bash chroot cat chmod cp cryptsetup curl eject file git gpg grep \
    mkdir mkfs.ext4 mkfs.vfat mkswap modprobe mount parted qemu-x86_64 rm \
    rsync sed sha512sum sync tar tput umount useradd wget
  )

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

  # Bind mounts that chroot needs
  CHROOT_BIND_MOUNTS=(proc sys dev dev/pts)
}

# Offset to print "[ OK ]" or "[ !! ]"
expand_width() {
  expand -t "$(($(tput cols) + 4))"
}

randpw() {
  head /dev/urandom | tr -dc A-Za-z0-9 | head -c 16
  echo
}

test_args() {
  if [ -z "${SDCARD_DEVICE}" ] && [ -z "${IMAGE_FILE}" ]; then
    printf "-d|--device, xor -i|--image-file not set. Exiting...\n"
    exit 1
  elif [ -n "${SDCARD_DEVICE}" ] && [ -n "${IMAGE_FILE}" ]; then
    printf "-d|--device, and -i|--image-file are both set. Specify only one! Exiting...\n"
    exit 1
  elif [ -n "${SDCARD_DEVICE}" ]; then
    if [ ! -b "${SDCARD_DEVICE}" ]; then
      printf "%s not found. Exiting...\n" "${SDCARD_DEVICE}"
      exit 1
    fi
  fi

  if [ -z "${ARCH}" ]; then
    ARCH="32"
  fi

  if [ -z "${STAGE}" ]; then
    STAGE="3"
  fi

  if [ -z "${TARBALL}" ]; then
    if [ "${ARCH}" -eq "32" ] && [ "${STAGE}" -eq "3" ]; then
      LATEST_TARBALL="$(curl -s http://distfiles.gentoo.org/releases/arm/autobuilds/latest-stage3-armv7a_hardfp.txt | tail -n 1 | awk '{print $1}')"
      TARBALL="http://distfiles.gentoo.org/releases/arm/autobuilds/${LATEST_TARBALL}"
    elif [ "${ARCH}" -eq "64" ] && [ "${STAGE}" -eq "3" ]; then
      LATEST_TARBALL="$(curl -s http://distfiles.gentoo.org/experimental/arm64/ | grep -o "stage3-arm64.[\d]{8}.tar.bz2" | head -n 1)"
      TARBALL="http://distfiles.gentoo.org/experimental/arm64/${LATEST_TARBALL}"
    elif [ "${ARCH}" -eq "64" ] && [ "${STAGE}" -eq "4" ]; then
      LATEST_TARBALL="$(curl -s http://distfiles.gentoo.org/experimental/arm64/ | grep -Po 'stage4-arm64-minimal-[\d]{8}.tar.bz2' | head -n 1)"
      TARBALL="http://distfiles.gentoo.org/experimental/arm64/${LATEST_TARBALL}"
    else
      printf "Incompatible ARCH and STAGE specified. Exiting...\n"
      exit 1
    fi
    if ! curl -Ifs "${TARBALL}" >/dev/null 2>&1; then
      printf "Latest tarball not found - please file a bug? Exiting...\n"
      exit 1
    fi
  elif ! curl -Ifs "${TARBALL}" >/dev/null 2>&1; then
    printf "Overridden tarball not found. Exiting...\n"
    exit 1
  fi

  if [ -z "${HOSTNAME}" ]; then
    HOSTNAME="gentoopi"
  fi

  if [ -z "${TIMEZONE}" ]; then
    TIMEZONE="Europe/London"
  elif [ ! -f "/usr/share/zoneinfo/${TIMEZONE}" ]; then
    printf "Invalid time zone. Exiting...\n"
    exit 1
  fi

  if [ -z "${NEW_USER}" ]; then
    NEW_USER="pi"
  fi

  if [ -z "${NEW_USER_PASSWD}" ]; then
    NEW_USER_PASSWD=$(randpw)
  fi

  if [ -z "${NEW_USER_FULL_NAME}" ]; then
    NEW_USER_FULL_NAME="Gentoo Pi user"
  fi

  if [ -z "${ROOT_PASSWD}" ]; then
    ROOT_PASSWD=$(randpw)
  fi

  if [ -n "${SSH_PUBKEY}" ]; then
    if [[ $(file "${SSH_PUBKEY}") != *OpenSSH*public\ key ]]; then
      printf "Invalid SSH public key. Exiting...\n"
      exit 1
    fi
  fi

  if [ -z "${VERIFY}" ]; then
    VERIFY="1"
  fi
}

test_deps() {
  for i in "${DEPS[@]}"; do
    if ! command -v "${i}" >/dev/null 2>&1; then
      printf "Did not find \"%s\". Exiting...\n" "${i}"
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

  if [ "${ARCH}" -eq "32" ]; then
    if [ ! -f "files/qemu-arm" ]; then
      printf "Did not find \"files/qemu-arm\". Exiting...\n"
      exit 1
    fi
  elif [ "${ARCH}" -eq "64" ]; then
    if [ ! -f "files/qemu-aarch64" ]; then
      printf "Did not find \"files/qemu-aarch64\". Exiting...\n"
      exit 1
    fi
  fi
}

last_warning() {
  # Last warning before formatting ${SDCARD_DEVICE} or ${IMAGE_FILE}
  if [ -b "${SDCARD_DEVICE}" ]; then
    printf "\n%s* WARNING:%s This will format %s:\n\n" "${YELLOW}" "${NC}" "${SDCARD_DEVICE}"
    parted "${SDCARD_DEVICE}" print
  elif [ -f "${IMAGE_FILE}" ]; then
    printf "\n%s* WARNING:%s This will format %s:\n\n" "${YELLOW}" "${NC}" "${IMAGE_FILE}"
    parted "${IMAGE_FILE}" print
  fi
  if [ -f "${IMAGE_FILE}" ] || [ -b "${SDCARD_DEVICE}" ]; then
    while true; do
      read -rp "Do you wish to continue formatting this device? [yes|no] " yn
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

  for i in "{1..10}"; do
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
        printf "Cannot write to %s - check your permissions / free disk space. Exiting...\n" "${IMAGE_FILE}"
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
      printf "%s\n\nPartitioning failed. Exiting...\n" "${FAILED}"
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
    printf "%s" "${LUKS_PASSPHRASE}" | cryptsetup -h sha512 -c aes-xts-plain64 -s 512 luksFormat --align-payload=8192 "${SDCARD_DEVICE_ROOT}" || exit 1
    printf "%s" "${LUKS_PASSPHRASE}" | cryptsetup open --type luks "${SDCARD_DEVICE_ROOT}" "${LUKS_ROOT_NAME}" || exit 1

    # We will no longer use the raw partition, but rather the unlocked, named
    # LUKS partition
    SDCARD_DEVICE_ROOT="/dev/mapper/${LUKS_ROOT_NAME}"
  fi

  # Formatting new partitions
  if ! yes | mkfs.vfat -F 32 "${SDCARD_DEVICE_BOOT}" >/dev/null 2>&1; then
    printf "%s\n\nFormatting %s failed. Exiting...\n" "${FAILED}" "${SDCARD_DEVICE_BOOT}"
    exit 1
  fi
  if [ -z "${CRYPT_SWAP}" ]; then
    if ! yes | mkswap "${SDCARD_DEVICE_SWAP}" >/dev/null 2>&1; then
      printf "%s\n\nFormatting %s failed. Exiting...\n" "${FAILED}" "${SDCARD_DEVICE_SWAP}"
      exit 1
    fi
  fi
  if ! yes | mkfs.ext4 "${SDCARD_DEVICE_ROOT}" >/dev/null 2>&1; then
    printf "%s\n\nFormatting %s failed. Exiting...\n" "${FAILED}" "${SDCARD_DEVICE_ROOT}"
    exit 1
  fi

  # Mount root and boot partitions for installation
  rm -rf "${MOUNTED_ROOT}"
  mkdir "${MOUNTED_ROOT}"

  if ! mount "${SDCARD_DEVICE_ROOT}" "${MOUNTED_ROOT}"; then
    printf "%s\n\nMounting %s on %s failed. Exiting...\n" "${FAILED}" "${SDCARD_DEVICE_ROOT}" "${MOUNTED_ROOT}"
    exit 1
  fi
  mkdir "${MOUNTED_BOOT}"
  if ! mount "${SDCARD_DEVICE_BOOT}" "${MOUNTED_BOOT}"; then
    printf "%s\n\nMounting %s on %s failed. Exiting...\n" "${FAILED}" "${SDCARD_DEVICE_BOOT}" "${MOUNTED_BOOT}"
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
      printf "%s\n\nCould not retrieve Gentoo PGP key. Do we have Interwebz? Exiting...\n" "${FAILED}"
      exit 1
    fi
  fi

  # I realised not all tarball hashes are signed
  if [ -f "${WORKDIR}/${TARBALL##*/}.DIGESTS.asc" ]; then
    if ! gpg --verify "${WORKDIR}/${TARBALL##*/}.DIGESTS.asc" >/dev/null 2>&1; then
      printf "%s\n\nTarball PGP signature mismatch - you sure you download an official tarball? Exiting...\n" "${FAILED}"
      exit 1
    fi
  fi

  # We have to omit non-H hashes first to verify integrity using H, where H is
  # the chosen hash function for verification.
  grep SHA512 -A 1 --no-group-separator "${WORKDIR}/${TARBALL##*/}.DIGESTS" > "${WORKDIR}/${TARBALL##*/}.DIGESTS.sha512"
  if ! cd "${WORKDIR}"; then
    printf "%s\n\nCannot cd to %s" "${FAILED}" "${WORKDIR}"
    exit 1
  fi
  if ! sha512sum -c "${WORKDIR}/${TARBALL##*/}.DIGESTS.sha512" >/dev/null 2>&1; then
    printf "%s\n\nTarball hash mismatch - did Gentoo mess up their hashes? Exiting...\n" "${FAILED}"
    exit 1
  fi
  if ! cd - >/dev/null 2>&1; then
    printf "%s\n\nCannot cd back to working directory" "${FAILED}"
    exit 1
  fi

  return 0
}

install_gentoo() {
  if ! tar xfpj "${WORKDIR}/${TARBALL##*/}" -C "${MOUNTED_ROOT}" >/dev/null 2>&1; then
    printf "%s\n\nCould not untar %s to %s/usr/. Exiting...\n" "${FAILED}" "${WORKDIR}/${TARBALL##*/}" "${MOUNTED_ROOT}"
    exit 1
  fi

  return 0
}

install_portage() {
  if [ ! -f "${WORKDIR}/portage-latest.tar.bz2" ]; then
    wget -q "http://distfiles.gentoo.org/snapshots/portage-latest.tar.bz2" -O "${WORKDIR}/portage-latest.tar.bz2"
  fi

  if ! tar xfpj "${WORKDIR}/portage-latest.tar.bz2" -C "${MOUNTED_ROOT}/usr/" >/dev/null 2>&1; then
    printf "%s\n\nCould not untar %s/portage-latest.tar.bz2 to %s/usr/. Exiting...\n" "${FAILED}" "${WORKDIR}" "${MOUNTED_ROOT}"
    exit 1
  fi

  return 0
}

configure_gentoo() {
  # Editing "${MOUNTED_ROOT}/etc/portage/make.conf"
  if [ -f "${MOUNTED_ROOT}/etc/portage/make.conf" ]; then
    if [ "${ARCH}" -eq "32" ]; then
      sed -i 's/^CFLAGS.*/CFLAGS="-O2 -pipe -march=armv7-a -mfpu=neon-vfpv4 -mfloat-abi=hard"/' "${MOUNTED_ROOT}/etc/portage/make.conf"
    elif [ "${ARCH}" -eq "64" ]; then
      sed -i 's/^CFLAGS.*/CFLAGS="-march=armv8-a+crc -mtune=cortex-a53 -ftree-vectorize -O2 -pipe -fomit-frame-pointer"/' "${MOUNTED_ROOT}/etc/portage/make.conf"
      #echo "ACCEPT_KEYWORDS=\"~arm64\"" >> "${MOUNTED_ROOT}/etc/portage/make.conf" # A lot of packages need ~arm64, but I'd like to avoid this on a global scale
    fi
    echo 'EMERGE_DEFAULT_OPTS="${EMERGE_DEFAULT_OPTS} --jobs=4 --load-average=4"' >> "${MOUNTED_ROOT}/etc/portage/make.conf"
  else
    printf "%s\n\nCould not find %s/etc/portage/make.conf. Exiting...\n" "${FAILED}" "${MOUNTED_ROOT}"
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
    printf "%s\n\nCould not find %s/etc/fstab. Exiting...\n" "${FAILED}" "${MOUNTED_ROOT}"
    exit 1
  fi

  # Setting time zone
  if [ -f "${MOUNTED_ROOT}/usr/share/zoneinfo/${TIMEZONE}" ]; then
    cp "${MOUNTED_ROOT}/usr/share/zoneinfo/${TIMEZONE}" "${MOUNTED_ROOT}/etc/localtime"
    echo "${TIMEZONE}" > "${MOUNTED_ROOT}/etc/timezone"
  else
    printf "%s\n\nCould not find %s/usr/share/zoneinfo/%s. Exiting...\n" "${FAILED}" "${MOUNTED_ROOT}" "${TIMEZONE}"
    exit 1
  fi

  # Clearing root passwd
  if [ -f "${MOUNTED_ROOT}/etc/shadow" ]; then
    sed -i 's/^root:.*/root::::::::/' "${MOUNTED_ROOT}/etc/shadow"
  else
    printf "%s\n\nCould not find %s/etc/shadow. Exiting...\n" "${FAILED}" "${MOUNTED_ROOT}"
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
  if [ -n "${SSH}" ] && [ -z "${SSH_PUBKEY}" ]; then
    if ! sed "s/^PasswordAuthentication no$/PasswordAuthentication yes/g" -i "${MOUNTED_ROOT}/etc/ssh/sshd_config"; then
      printf "%s\n\nCould not write to %s/etc/ssh/sshd_config. Exiting...\n" "${FAILED}" "${MOUNTED_ROOT}"
      exit 1
    fi
  fi

  # Setting a different SSH port, if specified
  if [ -n "${SSH_PORT}" ]; then
    if ! sed "s/^#Port 22$/Port ${SSH_PORT}/g" -i "${MOUNTED_ROOT}/etc/ssh/sshd_config"; then
      printf "%s\n\nCould not write to %s/etc/ssh/sshd_config. Exiting...\n" "${FAILED}" "${MOUNTED_ROOT}"
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
      print "  ARCH=\"'"${ARCH}"'\""
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
    printf "%s\n\nCould not find files/updater.sh or could not write to %s/root/. Exiting...\n" "${FAILED}" "${MOUNTED_ROOT}"
    exit 1
  fi

  # Comment out the s0 console (serial) to fix message in dmesg which is
  # otherwise spammed on-screen: "INIT: Id" s0 "respawning too fast".
  if ! sed -e '/^s0:.*/ s/^#*/#/' -i "${MOUNTED_ROOT}/etc/inittab"; then
    printf "%s\n\nCould not write to %s/etc/inittab. Exiting...\n" "${FAILED}" "${MOUNTED_ROOT}"
    exit 1
  fi

  # Adding 1.1.1.1 as a nameserver for chroot env. Will most likely be changed
  # by your local DHCP server upon first boot. Needed temporarily in chroot.
  echo "nameserver 1.1.1.1" > "${MOUNTED_ROOT}/etc/resolv.conf"
}

prep_chroot() {
  # Copy qemu-arm-/ qemu-aarch64 to card in order to chroot. Please use your own binaries if you don't trust mine.
  if [ "${ARCH}" -eq "32" ]; then
    if ! cp "files/qemu-arm" "${MOUNTED_ROOT}/usr/bin/qemu-arm"; then
      printf "%s\n\nCould not copy \"files/qemu-arm\" to \"%s/usr/bin/qemu-arm\". Exiting...\n" "${FAILED}" "${MOUNTED_ROOT}"
      exit 1
    fi
  elif [ "${ARCH}" -eq "64" ]; then
    if ! cp "files/qemu-aarch64" "${MOUNTED_ROOT}/usr/bin/qemu-aarch64"; then
      printf "%s\n\nCould not copy \"files/qemu-aarch64\" to \"%s/usr/bin/qemu-aarch64\". Exiting...\n" "${FAILED}" "${MOUNTED_ROOT}"
      exit 1
    fi
  fi

  # Loading binfmt_misc kernel module
  if [ ! -d /proc/sys/fs/binfmt_misc ]; then
    if ! modprobe binfmt_misc; then
      printf "%s\n\nCould not load kernel module binfmt_misc. Exiting...\n" "${FAILED}"
      exit 1
    fi
  fi

  if ! [ -f /proc/sys/fs/binfmt_misc/register ]; then
    mount binfmt_misc -t binfmt_misc /proc/sys/fs/binfmt_misc 
  fi

  # Registering arm handler for qemu-binfmt
  if [ "${ARCH}" -eq "32" ]; then
    echo ':arm:M::\x7fELF\x01\x01\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x02\x00\x28\x00:\xff\xff\xff\xff\xff\xff\xff\x00\xff\xff\xff\xff\xff\xff\xff\xff\xfe\xff\xff\xff:/qemu-wrapper:' > /proc/sys/fs/binfmt_misc/register >/dev/null 2>&1
  elif [ "${ARCH}" -eq "64" ]; then
    echo ':aarch64:M::\x7fELF\x02\x01\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x03\x00\xb7\x00:\xff\xff\xff\xff\xff\xff\xff\x00\xff\xff\xff\xff\xff\xff\xff\xff\xfe\xff\xff\xff:/usr/bin/qemu-aarch64:' > /proc/sys/fs/binfmt_misc/register >/dev/null 2>&1
  fi

  # (Re)starting qemu-binfmt
  if command -v rc-service >/dev/null 2>&1; then
    rc-service qemu-binfmt restart >/dev/null 2>&1
  elif command -v systemctl >/dev/null 2>&1; then
    systemctl restart systemd-binfmt >/dev/null 2>&1
  fi

  # Bind mounting for chroot env
  for i in "${CHROOT_BIND_MOUNTS[@]}"; do
    mount --bind /"${i}" "${MOUNTED_ROOT}/${i}"
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
  elif [ -z "${IMAGE_FILE}" ]; then
    eject "${SDCARD_DEVICE}"
  fi
}

get_args "$@"
get_vars
test_args
test_deps
last_warning

printf '\n %s*%s Partitioning device ... \t' "${LGREEN}" "${NC}" | expand_width
if prepare_card ; then
  printf "%s\n" "${OK}"
fi

printf ' %s*%s Downloading tarball ... \t' "${LGREEN}" "${NC}" | expand_width
if download_tarball ; then
  printf "%s\n" "${OK}"
fi

if [ "${VERIFY}" -eq "1" ]; then
  printf ' %s*%s Verifying tarball ... \t' "${LGREEN}" "${NC}" | expand_width
  if verify_tarball ; then
    printf "%s\n" "${OK}"
  fi
fi

printf ' %s*%s Installing Gentoo ... \t' "${LGREEN}" "${NC}" | expand_width
if install_gentoo ; then
  printf "%s\n" "${OK}"
fi

if [ "${STAGE}" -eq "3" ]; then
  printf ' %s*%s Installing Portage ... \t' "${LGREEN}" "${NC}" | expand_width
  if install_portage ; then
    printf "%s\n" "${OK}"
  fi
fi

printf ' %s*%s Configuring Gentoo ... \t' "${LGREEN}" "${NC}" | expand_width
if configure_gentoo ; then
  printf "%s\n" "${OK}"
fi

printf ' %s*%s Preparing chroot ... \t' "${LGREEN}" "${NC}" | expand_width
if prep_chroot ; then
  printf "%s\n" "${OK}"
fi

printf '\n--- Chrooting to device ---\n\n'
chroot "${MOUNTED_ROOT}" /root/config.sh || exit 1
printf '\n--- Returning to host ---\n\n'

printf ' %s*%s Synchronising all pending writes and dismounting ... \t' "${LGREEN}" "${NC}" | expand -t 60
if eject_card ; then
  printf "%s\n" "${OK}"
fi

printf "\nInstallation complete. You can try to boot your Gentoo Pi and login\n"
printf "with the following credentials:\n"
printf "%s*%s %s:%s\n" "${LGREEN}" "${NC}" "${NEW_USER}" "${NEW_USER_PASSWD}"
printf "%s*%s root:%s\n" "${LGREEN}" "${NC}" "${ROOT_PASSWD}\n"
