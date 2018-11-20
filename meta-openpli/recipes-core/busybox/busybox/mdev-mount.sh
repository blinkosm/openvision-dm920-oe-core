#!/bin/sh

notify() {
	# we don't really depend on the hotplug_e2_helper, but when it exists, call it
	if [ -x /usr/bin/hotplug_e2_helper ] ; then
		/usr/bin/hotplug_e2_helper $ACTION /block/$MDEV $PHYSDEVPATH
	fi
}

samba_share() {
    # process the parameters
	local COMMAND=$1
	local MOUNTPOINT=`basename $2`
	local MODEL=$3

	# some mountpointn name exceptions
	if [ "$MOUNTPOINT" == "hdd" ]; then
		MOUNTPOINT="Harddisk"
	fi

	# do we have samba installed and have a share template?
	if [ -f /etc/samba/smb.conf -a -f /etc/samba/shares/share.template ]; then
		# process the add/remove request
		if [ "$COMMAND" == "ADD" ]; then
			# generate a share config for this mountpoint
			echo "[$MOUNTPOINT]" > /etc/samba/shares/$MOUNTPOINT.conf
			echo "  comment = $MODEL" >> /etc/samba/shares/$MOUNTPOINT.conf
			echo "  path = $2" >> /etc/samba/shares/$MOUNTPOINT.conf
			cat /etc/samba/shares/share.template >> /etc/samba/shares/$MOUNTPOINT.conf
		elif [ "$COMMAND" == "REMOVE" ]; then
			if [ -f /etc/samba/shares/$MOUNTPOINT.conf ]; then
				rm /etc/samba/shares/$MOUNTPOINT.conf
			fi
		else
			# unknown command, bail out
			return
		fi

		# do we have samba running?
		pidof -s smbd
		if [ $? -eq 0 ]; then
			# restart samba
			/etc/init.d/samba.sh restart &
		fi
	fi
}


case "$ACTION" in
	add|"")
		ACTION="add"
		# check if already mounted
		if grep -q "^/dev/${MDEV} " /proc/mounts ; then
			# Already mounted
			exit 0
		fi
		# blacklist boot device
		BOOTDEV=$(cat /proc/cmdline | sed -e 's/^.*root=\/dev\///' -e 's/ .*$//')
		if [ "$MDEV" == "$BOOTDEV" ] ; then
			exit 0
		fi
		# blacklist partitions on the same device as the boot device
		DEVBASE=${MDEV:0:7}
		if [[ $BOOTDEV == $DEVBASE* ]]; then
			exit 0
		fi
		# get the device base (f.e. sd[a-z] or mmcblk[0-9])
		if [ ! -d /sys/block/${DEVBASE} ]; then
			DEVBASE=${MDEV:0:3}
		else
			# if MDEV is a partion on the boot device, skip it
			if [ "$DEVBASE" == "${BOOTDEV:0:7}" ]; then
				exit 0
			fi
		fi
		# check for "please don't mount it" file
		if [ -f "/dev/nomount.${DEVBASE}" ] ; then
			# blocked
			exit 0
		fi
		# run the result of blkid as a shell command
		eval `blkid /dev/${MDEV} | grep ${MDEV} | cut -d ':' -f 2`
		if [ -z "$TYPE" ] ; then
			notify
			exit 0
		fi
		# activate swap space
		if [ $TYPE == swap ] ; then
			if ! grep -q "^/dev/${MDEV} " /proc/swaps ; then
				swapon /dev/${MDEV}
			fi
			exit 0
		fi
		# check for full-disk partition
		if [ "${DEVBASE}" == "${MDEV}" ] ; then
			if [ -d /sys/block/${DEVBASE}/${DEVBASE}*1 ] ; then
				# Partition detected, just tell and quit
				notify
				exit 0
			fi
			if [ ! -f /sys/block/${DEVBASE}/size ] ; then
				# No size at all
				exit 0
			fi
			if [ `cat /sys/block/${DEVBASE}/size` == 0 ] ; then
				# empty device, bail out
				exit 0
			fi
		fi
		# first allow fstab to determine the mountpoint
		if ! mount /dev/$MDEV > /dev/null 2>&1 ; then
			# no fstab entry, use automatic mountpoint
			if [ -z "${LABEL}" ] ; then
				REMOVABLE=`cat /sys/block/$DEVBASE/removable`
				readlink -fn /sys/block/$DEVBASE/device | grep -qs 'pci\|ahci\|sata'
				EXTERNAL=$?
				if [ "${REMOVABLE}" -eq "0" -a $EXTERNAL -eq 0 ] ; then
					# mount the first non-removable internal device on /media/hdd
					DEVICETYPE="hdd"
				else
					# mount mmc block devices on /media/mcc
					if [ ${DEVBASE:0:6} = "mmcblk" ]; then
						DEVICETYPE="mmc"
					else
						MODEL=`cat /sys/block/$DEVBASE/device/model`
						if [ "$MODEL" == "USB CF Reader   " ]; then
							DEVICETYPE="cf"
						elif [ "$MODEL" == "Compact Flash   " ]; then
							DEVICETYPE="cf"
						elif [ "$MODEL" == "USB SD Reader   " ]; then
							DEVICETYPE="mmc"
						elif [ "$MODEL" == "USB SD  Reader  " ]; then
							DEVICETYPE="mmc"
						elif [ "$MODEL" == "SD/MMC          " ]; then
							DEVICETYPE="mmc"
						elif [ "$MODEL" == "USB MS Reader   " ]; then
							DEVICETYPE="mmc"
						elif [ "$MODEL" == "SM/xD-Picture   " ]; then
							DEVICETYPE="mmc"
						elif [ "$MODEL" == "USB SM Reader   " ]; then
							DEVICETYPE="mmc"
						elif [ "$MODEL" == "MS/MS-Pro       " ]; then
							DEVICETYPE="mmc"
						else
							DEVICETYPE="usb"
						fi
					fi
				fi
			else
				DEVICETYPE="${LABEL}"
			fi
			# Use mkdir as 'atomic' action, failure means someone beat us to the punch
			MOUNTPOINT="/media/$DEVICETYPE"
			if ! mkdir "${MOUNTPOINT}" ; then
				MOUNTPOINT="/media/$MDEV"
				mkdir -p "${MOUNTPOINT}"
			fi
			if [ $TYPE == exfat ] && [ -f /usr/sbin/mount.exfat ] && mount.exfat -o noatime /dev/$MDEV "${MOUNTPOINT}" ; then
				exit 0
			fi
			if ! mount -t auto -o noatime /dev/$MDEV "${MOUNTPOINT}" ; then
				rmdir "${MOUNTPOINT}"
			else
				samba_share ADD "${MOUNTPOINT}" "$MODEL"
			fi
		fi
		;;
	remove)
		MOUNTPOINT=`grep "^/dev/$MDEV\s" /proc/mounts | cut -d' ' -f 2 | sed 's/\\\\040/ /g'`
		if [ -z "${MOUNTPOINT}" ] ; then
			MOUNTPOINT="/media/$MDEV"
		fi
		umount "${MOUNTPOINT}" || umount "/dev/${MDEV}"
		rmdir "${MOUNTPOINT}"
		samba_share REMOVE "${MOUNTPOINT}" "$MODEL"
		;;
	*)
		# Unexpected keyword
		exit 1
		;;
esac
