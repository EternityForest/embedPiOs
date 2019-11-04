#!/bin/bash


# Based on the readonly script from:
# https://github.com/adafruit/Raspberry-Pi-Installer-Scripts/issues

#Plus an earlier script I wrote from a bunch of tutorials.

# CREDIT TO THESE TUTORIALS:
# petr.io/en/blog/2015/11/09/read-only-raspberry-pi-with-jessie
# hallard.me/raspberry-pi-read-only
# k3a.me/how-to-make-raspberrypi-truly-read-only-reliable-and-trouble-free



replace() {
	grep $2 $1 >/dev/null
	if [ $? -eq 0 ]; then
		# Pattern found; replace in file
		sed -i "s/$2/$3/g" $1 >/dev/null
	fi
}

# Given a filename, a regex pattern to match and a replacement string:
# If found, perform replacement, else append file w/replacement on new line.
replaceAppend() {
	grep $2 $1 >/dev/null
	if [ $? -eq 0 ]; then
		# Pattern found; replace in file
		sed -i "s/$2/$3/g" $1 >/dev/null
	else
		# Not found; append on new line (silently)
		echo $3 | sudo tee -a $1 >/dev/null
	fi
}

# Given a filename, a regex pattern to match and a string:
# If found, no change, else append file with string on new line.
append1() {
	grep $2 $1 >/dev/null
	if [ $? -ne 0 ]; then
		# Not found; append on new line (silently)
		echo $3 | sudo tee -a $1 >/dev/null
	fi
}

# Given a filename, a regex pattern to match and a string:
# If found, no change, else append space + string to last line --
# this is used for the single-line /boot/cmdline.txt file.
append2() {
	grep $2 $1 >/dev/null
	if [ $? -ne 0 ]; then
		# Not found; insert in file before EOF
		sed -i "s/\'/ $3/g" $1 >/dev/null
	fi
}

echo
echo "Starting installation..."
echo "Updating package index files..."
apt-get update

echo "Removing unwanted packages..."
#apt-get remove -y --force-yes --purge triggerhappy dbus \
# dphys-swapfile xserver-common lightdm fake-hwclock
# Let's keep dbus...that includes avahi-daemon, a la 'raspberrypi.local',
# also keeping xserver & lightdm for GUI login (WIP, not working yet)

#Also keeping logrotate, I'm just going to give it's config dir a tmpfs.
apt-get remove -y --force-yes --purge triggerhappy \
 dphys-swapfile fake-hwclock
apt-get -y --force-yes autoremove --purge








#--------------------------------------------Make random numbers stay random
if [ ! -h /var/lib/systemd/random-seed ] ; then
#This one is actually kind of important for security, so we have a special service just for faking it.
rm -f /var/lib/systemd/random-seed
ln -s /run/random-seed /var/lib/systemd/random-seed
fi

if [ ! -h /var/lib/urandom/random-seed ] ; then
rm -fr /var/lib/urandom/random-seed
ln -s  /run/random-seed /var/lib/urandom/random-seed
fi

#This is a pregenerated block of randomness used to enhance the security of the randomness we generate at boot.
#This is really not needed, we generate enough at boot, but since we don't save any randomness at shutdown anymore,
#we might as well.
touch /etc/unique-random-supplement
chmod 700  /etc/unique-random-supplement
echo "Generating random numbers, this might be a while."

#Use hwrng if possible. If that exists, generate 128 bytes just because we can
if [ -e /dev/hwrng ] ; then
dd bs=1 count=256 if=/dev/hwrng  of=/etc/unique-random-supplement >/dev/null
else
dd bs=1 count=32 if=/dev/random  of=/etc/unique-random-supplement >/dev/null
fi
echo "Generated random numbers"

systemctl disable systemd-random-seed.service




####---------------------------Install boot script. This is our new entropy source-------------------

#Installl the readonly-random-seed service in systemd
unpack /filesystem/embedtools_service.sh /usr/bin/ root
unpack /filesystem/embedtools.service /etc/systemd/system root

chmod 744 /usr/bin/embedtools_service.sh
chmod 744 /etc/systemd/system/embedtools.service

systemctl enable embedtools.service



###-----------------------------------------No systemd profiling storage stuff-----------------------
#Disable systemd services. We can keep the random seed one because we get there first and shim it.
systemctl disable systemd-readahead-collect.service
systemctl disable systemd-readahead-replay.service



# Add fastboot, noswap and/or ro to end of /boot/cmdline.txt
append2 /boot/cmdline.txt fastboot fastboot
append2 /boot/cmdline.txt noswap noswap

if [ $ACTUALLY_RO -eq 1 ]; then
append2 /boot/cmdline.txt ro^o^t ro
fi

# Move /var/spool to /tmp
rm -rf /var/spool
ln -s /tmp /var/spool

# Move /var/lib/lightdm and /var/cache/lightdm to /tmp
rm -rf /var/lib/lightdm
rm -rf /var/cache/lightdm
ln -s /tmp /var/lib/lightdm
ln -s /tmp /var/cache/lightdm

# Make SSH work
replaceAppend /etc/ssh/sshd_config "^.*UsePrivilegeSeparation.*$" "UsePrivilegeSeparation no"
# bbro method (not working in Jessie?):
#rmdir /var/run/sshd
#ln -s /tmp /var/run/sshd

# Change spool permissions in var.conf (rondie/Margaret fix)
replace /usr/lib/tmpfiles.d/var.conf "spool\s*0755" "spool 1777"

# Move dhcpd.resolv.conf to tmpfs
touch /tmp/dhcpcd.resolv.conf
rm /etc/resolv.conf
ln -s /tmp/dhcpcd.resolv.conf /etc/resolv.conf

#Set up symlinks in case we have dhcpcd5
if [ ! -h /var/lib/dhcpcd5 ] ; then
rm -r /var/lib/dhcpcd5
ln -s /var/lib/dhcp /var/lib/dhcpcd5
fi


# Make edits to fstab

##They should already have /run and /var/lock covered

# make / ro
# tmpfs /var/log tmpfs nodev,nosuid 0 0
# tmpfs /var/tmp tmpfs nodev,nosuid 0 0
# tmpfs /tmp     tmpfs nodev,nosuid 0 0

# and "just a few" a few others....


append1 /etc/fstab "/var/log" "tmpfs /var/log tmpfs nodev,nosuid,size=32M 0 0"
append1 /etc/fstab "/var/tmp" "tmpfs /var/tmp tmpfs nodev,nosuid,size=256M 0 0"
append1 /etc/fstab "\s/tmp"   "tmpfs /tmp    tmpfs nodev,nosuid,size=256M 0 0"


#NTP and Chrony are both valid choices. Can't really make people pick one....
mkdir -p /var/lib/ntp
append1 /etc/fstab "/var/lib/ntp" "tmpfs /var/lib/ntp tmpfs defaults,noatime,nosuid,nodev,noexec,size=1M 0 0"
mkdir -p /var/lib/chrony
append1 /etc/fstab "/var/lib/chrony" "tmpfs /var/lib/ntp tmpfs defaults,noatime,nosuid,nodev,noexec,size=1M 0 0"


#We mayve don't need this anymore on systemD????
append1 /etc/fstab "/var/lib/urandom" "tmpfs /var/lib/urandom tmpfs defaults,noatime,nosuid,nodev,noexec,mode=700,size=1M 0 0"

#Keep logrotate. We want to clear old logs out of RAM
append1 /etc/fstab "/var/lib/logrotate" "tmpfs /var/lib/logrotate tmpfs defaults,noatime,nosuid,nodev,noexec,size=2M 0 0"

append1 /etc/fstab "/var/lib/sudo" "tmpfs /var/lib/sudo tmpfs defaults,noatime,nosuid,nodev,noexec,mode=700,size=2M 0 0"

mkdir -p /var/lib/pulse
append1 /etc/fstab "/var/lib/pulse" "tmpfs /var/lib/pulse tmpfs defaults,noatime,nosuid,nodev,noexec,mode=700,size=2M 0 0"


