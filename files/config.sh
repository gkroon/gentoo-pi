#!/bin/sh

# This script will be edited and copied to /root of the card by installer.sh.
# When the installer.sh enters chroot, this script will run to finish the
# installation. After the script is finished it will remove itself.

get_vars() {
  # Collected vars from running the installation script will be hardcoded after this line

  # Terminal colours
  GREEN='\033[0;32m'
  BLUE='\033[0;34m'
  MAGENTA='\033[0;35m'
  LGREEN='\033[1;32m'
  LRED='\033[1;31m'
  YELLOW='\033[1;33m'
  NC='\033[0m'

  # Print "failed" or "ok" in colour
  FAILED="${BLUE}[${NC} ${LRED}failed${NC} ${BLUE}]${NC}"
  OK="${BLUE}[${NC} ${LGREEN}ok${NC} ${BLUE}]${NC}"
}

passwd_root() {
  if ! echo "root:${ROOT_PASSWD}" | chpasswd >/dev/null 2>&1; then
    printf "${FAILED}: could not change root's passwd. Exiting...\n"
    exit 1
  fi
}

new_user() {
  if ! useradd -m -G adm,audio,cdrom,input,users,video,wheel -s /bin/bash -c "${NEW_USER_FULL_NAME}" "${NEW_USER}"; then
    printf "${FAILED}: could not add new user. Exiting...\n"
    exit 1
  fi

  if [ ! -d "/home/${NEW_USER}/.ssh" ]; then
    mkdir /home/${NEW_USER}/.ssh
  fi

  # Adding SSH public key, if specified
  if [ -f "/root/.ssh/authorized_keys" ]; then
    if ! cp "/root/.ssh/authorized_keys" "/home/${NEW_USER}/.ssh/authorized_keys"; then
      printf "${FAILED}: could not copy /root/.ssh/authorized_keys to /home/${NEW_USER}/.ssh/authorized_keys. Exiting...\n"
      exit 1
    fi

    if ! chown ${NEW_USER}:${NEW_USER} "/home/${NEW_USER}/.ssh/authorized_keys"; then
    printf "${FAILED}: could not chown /home/${NEW_USER}/.ssh/authorized_keys. Exiting...\n"
    exit 1
    fi

    if ! chmod 0600 "/home/${NEW_USER}/.ssh/authorized_keys"; then
      printf "${FAILED}: could not chmod 0600 /home/${NEW_USER}/.ssh/authorized_keys. Exiting...\n"
      exit 1
    fi
  fi
}

new_user_passwd() {
  if ! echo "${NEW_USER}:${NEW_USER_PASSWD}" | chpasswd >/dev/null 2>&1; then
    printf "${FAILED}: could not change new user's passwd. Exiting...\n"
    exit 1
  fi
}

setting_hostname() {
  if ! echo "hostname=\"${HOSTNAME}\"" > /etc/conf.d/hostname; then
    printf "${FAILED}: could not set hostname. Exiting...\n"
    exit 1
  fi

  if ! echo "127.0.1.1 localhost ${HOSTNAME}" >> /etc/hosts; then
    printf "${FAILED}: could not update /etc/hosts. Exiting...\n"
    exit 1
  fi

  if ! echo "::1 localhost ${HOSTNAME}" >> /etc/hosts; then
    printf "${FAILED}: could not update /etc/hosts. Exiting...\n"
    exit 1
  fi
}

enable_eth0() {
  if ! ln -sv /etc/init.d/net.lo /etc/init.d/net.eth0 >/dev/null 2>&1; then
    printf "${FAILED}: could not symlink /etc/init.d/net.lo to /etc/init.d/net.eth0. Exiting...\n"
    exit 1
  fi

  if ! rc-update add net.eth0 boot >/dev/null 2>&1; then
    printf "${FAILED}: could not add service net.eth0 to runlevel boot. Exiting...\n"
    exit 1
  fi
}

sync_portage() {
  if ! emerge-webrsync >/dev/null 2>&1; then
    printf "${FAILED}: emerge-webrsync failed, aborting update for safety. Exiting...\n"
    exit 1
  fi
}

hardened_profile() {
  # As there is no hardened armv7a hardfp stage3 tarball, we have to switch
  # profile, rebuild gcc and then world
  if ! eselect profile set hardened/linux/arm/armv7a >/dev/null 2>&1; then
    echo
    printf "${FAILED}: could not switch to hardened profile. Exiting...\n"
    exit 1
  fi

  if ! source /etc/profile >/dev/null 2>&1; then
    echo
    printf "${FAILED}: could not source /etc/profile. Exiting...\n"
    exit 1
  fi
}

oneshot_depclean() {
  if ! FEATURES="-pid-sandbox" emerge --oneshot sys-devel/gcc >/dev/null 2>&1; then
    echo
    printf "${FAILED}: could not oneshot sys-devel/gcc. Exiting...\n"
    exit 1
  fi

  if ! FEATURES="-pid-sandbox" emerge --oneshot binutils virtual/libc >/dev/null 2>&1; then
    echo
    printf "${FAILED}: could not oneshot virtual/libc. Exiting...\n"
    exit 1
  fi

  if ! source /etc/profile >/dev/null 2>&1; then
    echo
    printf "${FAILED}: could not source /etc/profile. Exiting...\n"
    exit 1
  fi

  FEATURES="-pid-sandbox" emerge --depclean prelink >/dev/null 2>&1  
}
rebuild_world() {
  if ! FEATURES="-pid-sandbox" emerge --keep-going --emptytree --verbose @world >/dev/null 2>&1; then
    printf "${FAILED}: could not rebuild world. Exiting...\n"
    exit 1
  fi
}

update_packages() {
  # raspberrypi-sources needs updated perl packages for some reason. glibc might fail in qemu chroot.
  if ! FEATURES="-pid-sandbox" emerge --oneshot --keep-going --deep --update --newuse -kb --changed-use --newrepo dev-lang/perl $(qlist -I | grep dev-perl) >/dev/null 2>&1; then
    printf "${FAILED}: could not update needed packages. Exiting...\n"
    exit 1
  fi

  # This fails to install app-text/po4a?
  # if ! FEATURES="-pid-sandbox" perl-cleaner --ph-clean --modules -- --buildpkg=y >/dev/null 2>&1; then
  #   printf "${FAILED}: could not run perl-cleaner"
  #   exit 1
  # fi
}

install_packages() {
  # Emerging a select few packages we need
  mkdir "/etc/portage/package.unmask/"
  echo "sys-apps/util-linux static-libs" >> "/etc/portage/package.use/kernel"
  echo "sys-kernel/genkernel cryptsetup" >> "/etc/portage/package.use/kernel"
  echo "sys-kernel/raspberrypi-sources **" >> "/etc/portage/package.accept_keywords/kernel"
  if [ -n "${LUKS_PASSPHRASE}" ]; then
    if ! FEATURES="-pid-sandbox" emerge sys-fs/cryptsetup  >/dev/null 2>&1; then
      printf "${FAILED}: could not install sys-fs/cryptsetup needed for LUKS. Exiting...\n"
      exit 1
    fi
  fi

  if ! FEATURES="-pid-sandbox" emerge \
         app-admin/sudo \
         dev-vcs/git \
         net-misc/ntp \
         sys-kernel/genkernel \
         sys-kernel/raspberrypi-sources >/dev/null 2>&1; then
    printf "${FAILED}: could not install packages. Exiting...\n"
    exit 1
  fi
}

configure_packages() {
  # Editing sudoers file to grant users in group wheel passwordless sudo privileges
  if ! echo "%wheel ALL=(ALL) NOPASSWD: ALL" >> /etc/sudoers; then
    printf "${FAILED}: could not grant group wheel passwordless sudo privileges. Exiting...\n"
    exit 1
  fi
}

compile_kernel() {
  bestkern="$(qlist $(portageq best_version / raspberrypi-sources) | grep 'init/Kconfig' | awk -F'/' '{print $4}' | cut -d'-' -f 2-)"
  mkdir /etc/kernels
  sed 's/CONFIG_CRYPTO_XTS=m/CONFIG_CRYPTO_XTS=y/' /usr/src/linux/arch/arm/configs/bcm2709_defconfig > /etc/kernels/config.arm
  if ! KERNEL=kernel7 genkernel --clean --mrproper --mountboot --save-config --color --makeopts=-j4 --luks --gpg --kernel-config=/etc/kernels/config.arm all >/dev/null 2>&1; then
    prnitf "${FAILED}: could not compile kernel. Exiting...\n"
    exit 1
  fi
  mv /boot/kernel-genkernel-* /boot/kernel7.img
  mv /boot/initramfs-genkernel-* /boot/initramfs.gz
  cp /usr/src/linux-${bestkern}/arch/arm/boot/dts/*.dtb /boot/
  if [ ! -d /boot/overlays ]; then
    mkdir /boot/overlays
  fi
  cp /usr/src/linux-${bestkern}/arch/arm/boot/dts/overlays/* /boot/overlays/

  # Don't know how to generate these locally, so I'm cheating a bit here:
  wget https://github.com/raspberrypi/firmware/raw/master/boot/bootcode.bin -O /boot/bootcode.bin
  wget https://github.com/raspberrypi/firmware/raw/master/boot/fixup.dat -O /boot/fixup.dat
  wget https://github.com/raspberrypi/firmware/raw/master/boot/start.elf -O /boot/start.elf

  # Boot options
  if [ -n "${LUKS_PASSPHRASE}" ]; then
    echo "ipv6.disable=0 selinux=0 plymouth.enable=0 smsc95xx.turbo_mode=N dwc_otg.lpm_enable=0 console=ttyAMA0,115200 kgdboc=ttyAMA0,115200 console=tty1 crypt_root=${RPI_DEVICE_ROOT_RAW} cryptdevice=${RPI_DEVICE_ROOT_RAW}:root root=/dev/mapper/root rootfstype=ext4 elevator=noop rootwait" > "/boot/cmdline.txt"
    echo "initramfs initramfs.gz followkernel" > "/boot/config.txt"
  else
    echo "ipv6.disable=0 selinux=0 plymouth.enable=0 smsc95xx.turbo_mode=N dwc_otg.lpm_enable=0 console=ttyAMA0,115200 kgdboc=ttyAMA0,115200 console=tty1 root=${RPI_DEVICE_ROOT} rootfstype=ext4 elevator=noop rootwait" > "/boot/cmdline.txt"
  fi
  if [ -n "${CRYPT_SWAP}" ]; then
    echo -e "swap=swap\nsource='/dev/mmcblk0p2'" >> "/etc/conf.d/dmcrypt"
  fi
}

enable_services() {
  if ! rc-update add ntp-client default >/dev/null 2>&1; then
    printf "${FAILED}: could not add service ntp-client to runlevel default. Exiting...\n"
    exit 1
  fi

  if [[ "${SSH}" -eq "1" ]]; then
    if ! rc-update add sshd default >/dev/null 2>&1; then
      printf "${FAILED}: could not add service sshd to runlevel default. Exiting...\n"
      exit 1
    fi
  fi

  if [ -n "${CRYPT_SWAP}" ]; then
    if ! rc-update add dmcrypt boot >/dev/null 2>&1; then
      printf "${FAILED}: could not add service dmcrypt to runlevel boot. Exiting...\n"
      exit 1
    fi
  fi
}

get_vars

printf '>>> Changing passwd for root ............................... '
if passwd_root ; then
  printf "${OK}\n"
fi

printf '>>> Creating new user ...................................... '
if new_user ; then
  printf "${OK}\n"
fi

printf '>>> Changing passwd for new user ........................... '
if new_user_passwd ; then
  printf "${OK}\n"
fi

printf '>>> Setting hostname ....................................... '
if setting_hostname ; then
  printf "${OK}\n"
fi

printf '>>> Enabling eth0 to start at boot ......................... '
if enable_eth0 ; then
  printf "${OK}\n"
fi

printf '>>> Synchronising Portage .................................. '
if sync_portage ; then
  printf "${OK}\n"
fi

if [[ "${HARDENED}" -eq "1" ]]; then
  printf '>>> Setting hardened profile ............................... '
  if hardened_profile ; then
    printf "${OK}\n"
  fi
fi

if [[ "${HARDENED}" -eq "1" ]]; then
  printf '>>> Rebuilding GCC (could take a few hours) ................ '
  if oneshot_depclean ; then
    printf "${OK}\n"
  fi
fi

if [[ "${HARDENED}" -eq "1" ]]; then
  printf '\n--- Rebuilding world (could take a few days) ---\n\n'
  hardened_profile
  print
fi

printf '>>> Updating needed packages (could take a few hours) ...... '
if update_packages ; then
  printf "${OK}\n"
fi

printf '>>> Installing needed packages (could take a few hours) .... '
if install_packages ; then
  printf "${OK}\n"
fi

printf '>>> Configuring packages ................................... '
if configure_packages ; then
  printf "${OK}\n"
fi

printf '>>> Compiling kernel (could take a few hours ) ............. '
if compile_kernel ; then
  printf "${OK}\n"
fi

printf '>>> Enabling services ...................................... '
if enable_services ; then
  printf "${OK}\n"
fi

rm -- "$0"
exit 0
