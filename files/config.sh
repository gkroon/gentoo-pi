#!/bin/sh

get_vars() {
  # Collected vars will be hardcoded after this line
  LANIP="$(ifconfig eth0 | grep inet | grep -v inet6 | awk '{print $2}')"
}

passwd_root() {
  if ! passwd root; then
  	echo -e "${LRED}* FAILED${NC}: could not change root's passwd"
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

setting_date() {
  # Disabling hwclock (RPi doesn't have one) and enabling swclock
  if ! rc-update add swclock boot >/dev/null 2>&1; then
  	echo -e "[${LRED}FAILED${NC}]: could not add service swclock to runlevel boot"
    exit 1
  fi

  if ! rc-update del hwclock boot >/dev/null 2>&1; then
  	echo -e "[${LRED}FAILED${NC}]: could not remove service hwclock from runlevel boot"
    exit 1
  fi

  # Settings date to current date of host
  if ! date +%Y-%m-%d -s "${DATE}" >/dev/null 2>&1; then
  	echo -e "[${LRED}FAILED${NC}]: could not set date"
    exit 1
  fi
}

enable_eth0() {
  if ! ln -sv /etc/init.d/net.lo /etc/init.d/net.eth0 >/dev/null 2>&1; then
  	echo -e "[${LRED}FAILED${NC}]: could not symlink /etc/init.d/net.lo to /etc/init.d/net.eth0"
    exit 1
  fi

  if ! rc-service net.eth0 start >/dev/null 2>&1; then
  	echo -e "[${LRED}FAILED${NC}]: could not start service net.eth0"
    exit 1
  fi

  if ! rc-update add net.eth0 boot >/dev/null 2>&1; then
  	echo -e "[${LRED}FAILED${NC}]: could not add service net.eth0 to runlevel boot"
    exit 1
  fi

  if ! rc-update --update >/dev/null 2>&1; then
  	echo -e "[${LRED}FAILED${NC}]: could not update dependency tree cache"
    exit 1
  fi
}

new_user() {
  if ! useradd -m -G adm,audio,cdrom,input,users,video,wheel -s /bin/bash -c "${NEW_USER_FULL_NAME}" ${NEW_USER}; then
  	echo -e "[${LRED}FAILED${NC}]: could not add new user"
    exit 1
  fi

  if [ ! -d "/home/${NEW_USER}/.ssh" ]; then
  	mkdir /home/${NEW_USER}/.ssh
  fi

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
}

new_user_passwd() {
  if ! passwd ${NEW_USER}; then
  	echo -e "${LRED}* FAILED${NC}: could not change new user's passwd"
    exit 1
  fi
}

update_gentoo() {
  if ! /root/updater.sh; then
  	echo -e "[${LRED}FAILED${NC}]: could not update Gentoo"
    exit 1
  fi
}

install_packages() {
  # Emerge portage tools
  if ! emerge --ask --verbose \
    app-portage/genlop \
    app-portage/gentoolkit; then
    	echo -e "[${LRED}FAILED${NC}]: could not install Portage tools"
    	exit 1
  fi

  # Add global USE flags. Change these to your own desire.
  if ! euse -E zsh-completion; then
  	echo -e "[${LRED}FAILED${NC}]: could not add global USE flags"
    exit 1
  fi

  # Emerging misc packages. Change these to your own desire.
  if ! emerge --ask --verbose \
    app-admin/eclean-kernel \
    app-admin/pass \
    app-admin/sudo \
    app-editors/neovim \
    app-misc/neofetch \
    app-misc/screen \
    app-portage/eix \
    app-shells/zsh \
    app-shells/zsh-completions \
    dev-vcs/git \
    mail-client/neomutt \
    net-analyzer/fail2ban \
    net-dns/ldns-utils \
    net-dns/unbound \
    net-misc/dhcpcd \
    net-misc/ntp \
    sys-apps/mlocate \
    sys-process/htop \
    sys-process/lsof; then
    	echo -e "[${LRED}FAILED${NC}]: could not install packages"
    	exit 1
  fi
}

configure_packages() {
  # Setting favourite editor. Change this to your own favourite.
  if ! eselect editor set /usr/bin/nvim; then
  	echo -e "[${LRED}FAILED${NC}]: could not change favourite editor"
    exit 1
  fi

  if ! source /etc/profile; then
  	echo -e "[${LRED}FAILED${NC}]: could not source /etc/profile"
    exit 1
  fi

  # Editing sudoers file to grant users in 'wheel' sudo privileges
  if ! echo "%wheel ALL=(ALL) ALL" >> /etc/sudoers; then
  	echo -e "[${LRED}FAILED${NC}]: could not grant group wheel sudo privileges"
    exit 1
  fi
}

enable_services() {
  if ! rc-update add dhcpcd default; then
  	echo -e "[${LRED}FAILED${NC}]: could not add service dhcpcd to runlevel default"
    exit 1
  fi

  if ! rc-update add ntp-client default; then
  	echo -e "[${LRED}FAILED${NC}]: could not add service ntp-client to runlevel default"
    exit 1
  fi

  if ! rc-update add sshd default; then
  	echo -e "[${LRED}FAILED${NC}]: could not add service sshd to runlevel default"
    exit 1
  fi

  if ! rc-update add unbound default; then
  	echo -e "[${LRED}FAILED${NC}]: could not add service unbound to runlevel default"
    exit 1
  fi

  if ! rc-service dhcpcd start; then
  	echo -e "[${LRED}FAILED${NC}]: could not start service dhcpcd"
    exit 1
  fi

  if ! rc-service ntp-client start; then
  	echo -e "[${LRED}FAILED${NC}]: could not start service ntp-client"
    exit 1
  fi

  if ! rc-service sshd start; then
  	echo -e "[${LRED}FAILED${NC}]: could not start service sshd"
    exit 1
  fi

  if ! rc-service unbound start; then
  	echo -e "[${LRED}FAILED${NC}]: could not start service unbound"
    exit 1
  fi
}

get_vars

echo -e '--- Changing passwd for root ---'
echo
passwd_root
echo

echo -en '>>> Setting hostname .............................................. '
if setting_hostname ; then
  echo -e "[${LGREEN}OK${NC}]"
fi

echo -en '>>> Setting date .................................................. '
if setting_date ; then
	echo -e "[${LGREEN}OK${NC}]"
fi

echo -en '>>> Enabling eth0 ................................................. '
if enable_eth0 ; then
	echo -e "[${LGREEN}OK${NC}]"
fi

echo -en '>>> Creating new user ............................................. '
if new_user ; then
	echo -e "[${LGREEN}OK${NC}]"
fi

echo
echo -e '--- Changing passwd for new user ---'
echo
new_user_passwd
echo

echo -e '--- Updating Gentoo ---'
echo
if update_gentoo ; then
	echo
	echo -e '--- Finished updating Gentoo ---'
	echo
fi

echo -en '>>> Installing packages ........................................... '
if install_packages ; then
	echo -e "[${LGREEN}OK${NC}]"
fi

echo -en '>>> Enabling services ............................................. '
if enable_services ; then
	echo -e "[${LGREEN}OK${NC}]"
fi

echo
echo "Configuration finished. You can now SSH from your host using \"${NEW_USER}@${LANIP} -i ${SSH_PUBKEY}\"."
rm -- "$0"
exit 0