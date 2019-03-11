#!/bin/sh

# This script will be edited and copied to /root of the card by installer.sh.
# Once installer.sh is done, boot the Raspberry Pi with the new card, en then
# launch /root/config.sh, which is this script, to finish the installation.
# After the script is finished it will remove itself.

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
}

passwd_root() {
  if ! echo "root:${ROOT_PASSWD}" | chpasswd >/dev/null 2>&1; then
    echo -e "${LRED}* FAILED${NC}: could not change root's passwd"
    exit 1
  fi
}

new_user() {
  if ! useradd -m -G adm,audio,cdrom,input,users,video,wheel -s /bin/bash -c "${NEW_USER_FULL_NAME}" "${NEW_USER}"; then
    echo -e "[${LRED}FAILED${NC}]: could not add new user"
    exit 1
  fi

  if [ ! -d "/home/${NEW_USER}/.ssh" ]; then
    mkdir /home/${NEW_USER}/.ssh
  fi

  # Adding SSH public key, if specified
  if [ -f "/root/.ssh/authorized_keys" ]; then
    if ! cp "/root/.ssh/authorized_keys" "/home/${NEW_USER}/.ssh/authorized_keys"; then
      echo -e "[${LRED}FAILED${NC}]: could not copy /root/.ssh/authorized_keys to /home/${NEW_USER}/.ssh/authorized_keys"
      exit 1
    fi

    if ! chown ${NEW_USER}:${NEW_USER} "/home/${NEW_USER}/.ssh/authorized_keys"; then
    echo -e "[${LRED}FAILED${NC}]: could not chown /home/${NEW_USER}/.ssh/authorized_keys"
    exit 1
    fi

    if ! chmod 0600 "/home/${NEW_USER}/.ssh/authorized_keys"; then
      echo -e "[${LRED}FAILED${NC}]: could not chmod 0600 /home/${NEW_USER}/.ssh/authorized_keys"
      exit 1
    fi
  fi
}

new_user_passwd() {
  if ! echo "${NEW_USER}:${NEW_USER_PASSWD}" | chpasswd >/dev/null 2>&1; then
    echo -e "${LRED}* FAILED${NC}: could not change new user's passwd"
    exit 1
  fi
}

setting_hostname() {
  if ! echo "hostname=\"${HOSTNAME}\"" > /etc/conf.d/hostname; then
    echo -e "[${LRED}FAILED${NC}]: could not set hostname"
    exit 1
  fi

  if ! echo "127.0.1.1 localhost ${HOSTNAME}" >> /etc/hosts; then
    echo -e "[${LRED}FAILED${NC}]: could not update /etc/hosts"
    exit 1
  fi

  if ! echo "::1 localhost ${HOSTNAME}" >> /etc/hosts; then
    echo -e "[${LRED}FAILED${NC}]: could not update /etc/hosts"
    exit 1
  fi
}

enable_eth0() {
  if ! ln -sv /etc/init.d/net.lo /etc/init.d/net.eth0 >/dev/null 2>&1; then
    echo -e "[${LRED}FAILED${NC}]: could not symlink /etc/init.d/net.lo to /etc/init.d/net.eth0"
    exit 1
  fi

  if ! rc-update add net.eth0 boot >/dev/null 2>&1; then
    echo -e "[${LRED}FAILED${NC}]: could not add service net.eth0 to runlevel boot"
    exit 1
  fi
}

sync_portage() {
  if ! emerge-webrsync >/dev/null 2>&1; then
    echo -e "[${LRED}FAILED${NC}]: emerge-webrsync failed, aborting update for safety"
    exit 1
  fi
}

# As there is no hardened armv7a hardfp stage3 tarball, we have to switch
# profile, rebuild gcc and then world
hardened_profile() {
  if ! eselect profile set hardened/linux/arm/armv7a >/dev/null 2>&1; then
    echo
    echo -e "${LRED}* FAILED${NC}: could not switch to hardened profile"
    exit 1
  fi

  if ! source /etc/profile >/dev/null 2>&1; then
    echo
    echo -e "${LRED}* FAILED${NC}: could not source /etc/profile"
    exit 1
  fi
}

oneshot_depclean() {
  if ! emerge --oneshot sys-devel/gcc >/dev/null 2>&1; then
    echo
    echo -e "${LRED}* FAILED${NC}: could not oneshot sys-devel/gcc"
    exit 1
  fi

  if ! emerge --oneshot binutils virtual/libc >/dev/null 2>&1; then
    echo
    echo -e "[${LRED}* FAILED${NC}]: could not oneshot virtual/libc"
    exit 1
  fi

  if ! source /etc/profile >/dev/null 2>&1; then
    echo
    echo -e "${LRED}* FAILED${NC}: could not source /etc/profile"
    exit 1
  fi

  emerge --depclean prelink >/dev/null 2>&1
  
}
rebuild_world() {
  if ! emerge --emptytree --verbose @world >/dev/null 2>&1; then
    echo -e "${LRED}FAILED${NC}: could not rebuild world"
    exit 1
  fi
}

install_packages() {
  # Emerging a select few packages everybody can benefit from
  if ! emerge app-admin/sudo net-misc/ntp >/dev/null 2>&1; then
      echo -e "[${LRED}FAILED${NC}]: could not install packages"
      exit 1
  fi
}

configure_packages() {
  # Editing sudoers file to grant users in group wheel passwordless sudo privileges
  if ! echo "%wheel ALL=(ALL) NOPASSWD: ALL" >> /etc/sudoers; then
    echo -e "[${LRED}FAILED${NC}]: could not grant group wheel passwordless sudo privileges"
    exit 1
  fi
}

enable_services() {
  if ! rc-update add ntp-client default >/dev/null 2>&1; then
    echo -e "[${LRED}FAILED${NC}]: could not add service ntp-client to runlevel default"
    exit 1
  fi

  if [[ "${SSH}" -eq "1" ]]; then
    if ! rc-update add sshd default >/dev/null 2>&1; then
      echo -e "[${LRED}FAILED${NC}]: could not add service sshd to runlevel default"
      exit 1
    fi
  fi
}

get_vars

echo -n '>>> Changing passwd for root .............................. '
if passwd_root ; then
  echo -e "${BLUE}[${NC} ${LGREEN}ok${NC} ${BLUE}]${NC}"
fi

echo -n '>>> Creating new user ..................................... '
if new_user ; then
  echo -e "${BLUE}[${NC} ${LGREEN}ok${NC} ${BLUE}]${NC}"
fi

echo -n '>>> Changing passwd for new user .......................... '
if new_user_passwd ; then
  echo -e "${BLUE}[${NC} ${LGREEN}ok${NC} ${BLUE}]${NC}"
fi

echo -n '>>> Setting hostname ...................................... '
if setting_hostname ; then
  echo -e "${BLUE}[${NC} ${LGREEN}ok${NC} ${BLUE}]${NC}"
fi

echo -n '>>> Enabling eth0 to start at boot ........................ '
if enable_eth0 ; then
  echo -e "${BLUE}[${NC} ${LGREEN}ok${NC} ${BLUE}]${NC}"
fi

echo -n '>>> Synchronising Portage ................................. '
if sync_portage ; then
  echo -e "${BLUE}[${NC} ${LGREEN}ok${NC} ${BLUE}]${NC}"
fi

echo -n '>>> Updating Gentoo (could take a few hours) .............. '
if /root/updater.sh >/dev/null 2>&1; then
  echo -e "${BLUE}[${NC} ${LGREEN}ok${NC} ${BLUE}]${NC}"
fi

if [[ "${HARDENED}" -eq "1" ]]; then
  echo -n '>>> Setting hardened profile .............................. '
  if hardened_profile ; then
    echo -e "${BLUE}[${NC} ${LGREEN}ok${NC} ${BLUE}]${NC}"
  fi
fi

if [[ "${HARDENED}" -eq "1" ]]; then
  echo -n '>>> Rebuilding GCC (could take a few hours) ............... '
  if oneshot_depclean ; then
    echo -e "${BLUE}[${NC} ${LGREEN}ok${NC} ${BLUE}]${NC}"
  fi
fi

if [[ "${HARDENED}" -eq "1" ]]; then
  echo
  echo '--- Rebuilding world (could take a few days) ---'
  echo
  hardened_profile
  echo
fi

echo -n '>>> Installing packages ................................... '
if install_packages ; then
  echo -e "${BLUE}[${NC} ${LGREEN}ok${NC} ${BLUE}]${NC}"
fi

echo -n '>>> Configuring packages .................................. '
if configure_packages ; then
  echo -e "${BLUE}[${NC} ${LGREEN}ok${NC} ${BLUE}]${NC}"
fi

echo -n '>>> Enabling services ..................................... '
if enable_services ; then
  echo -e "${BLUE}[${NC} ${LGREEN}ok${NC} ${BLUE}]${NC}"
fi

rm -- "$0"
exit 0
