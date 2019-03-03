#!/bin/sh

get_vars() {
	# Collected vars will be hardcoded after this line
	LANIP="$(ifconfig eth0 | grep inet | grep -v inet6 | awk '{print $2}')"
}

configure_gentoo() {
	# Change password of root
	passwd root

	# Configuring new hostname
	echo "hostname=\"${HOSTNAME}\"" > /etc/conf.d/hostname
	echo "127.0.1.1 localhost ${HOSTNAME}" >> /etc/hosts
	echo "::1 localhost ${HOSTNAME}" >> /etc/hosts

	# Disabling hwclock (RPi doesn't have one) and enabling swclock
	rc-update add swclock boot
	rc-update del hwclock boot

	# Settings date to current date of host
	date +%Y-%m-%d -s "${DATE}"

	# Enabling networking on boot
	cd /etc/init.d/
	ln -sv net.lo net.eth0
	rc-service net.eth0 start
	rc-update add net.eth0 boot
	rc-update --update

	# Editing sudoers file to grant users in 'wheel' sudo privs
	echo "%wheel ALL=(ALL) ALL" >> /etc/sudoers

	# Add new user
	useradd -m -G adm,audio,cdrom,input,users,video,wheel -s /bin/bash -c "${NEW_USER_FULL_NAME}" ${NEW_USER}
	passwd ${NEW_USER}

	# Copy authorized_keys to new user
	mkdir /home/${NEW_USER}/.ssh
	cp "/root/.ssh/authorized_keys" "/home/${NEW_USER}/.ssh/authorized_keys"
	chown ${NEW_USER}:${NEW_USER} "/home/${NEW_USER}/.ssh/authorized_keys"
	chmod 0600 "/home/${NEW_USER}/.ssh/authorized_keys"
}

update_gentoo() {
	/root/rpi-gentoo-updater.sh
}

install_packages() {
	# Emerge portage tools
	emerge --ask --verbose \
		app-portage/genlop \
		app-portage/gentoolkit

	# Add global USE flags. Change these to your own desire.
	euse -E zsh-completion

	# Emerging misc packages. Change these to your own desire.
	emerge --ask --verbose \
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
		sys-process/lsof

	# Setting favourite editor. Change this to your own favourite.
	eselect editor set /usr/bin/nvim
	source /etc/profile
}

enabling_services() {
	rc-update add dhcpcd default
	rc-update add ntp-client default
	rc-update add sshd default
	rc-update add unbound default
	rc-service dhcpcd start
	rc-service ntp-client start
	rc-service sshd restart	
	rc-service unbound start
}

get_vars
configure_gentoo
update_gentoo
install_packages
enabling_services
echo "Post deployment finished. You can now SSH from your host using \"${NEW_USER}@${LANIP} -i ${SSH_PUBKEY}\"."