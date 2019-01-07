#!/bin/bash
# vhdutil: the Virtual Hard Disk UTILity
# Copyright 2019 Sahibdeep Nann, licensed under BSD-3-Clause

if [[ "$1" == "help" || "$#" -eq 0 ]]; then
	echo "vhdutil v2.0 [build 1 @ november 5, 2017]"
	echo
	echo "help / no subcommand: shows this list"
	echo "create [name] [capacity in MB]: creates a virtual disk with the given capacity"
	echo "lsdisk: lists virtual disks"
	echo "attach [name]: attachs a virtual disk to a loop device"
	echo "lsattach: lists attached virtual disks"
	echo "encrypt [name] [partition #]: encrypts a virtual partition"
	echo "format [name] [partition #] [filesystem]: formats a virtual partition"
	echo "mount [name] [partition #] [target]: mounts a virtual partition"
	echo "umount [name]: unmounts all partitions of a virtual disk"
	echo "detach [name]: detaches a virtual disk from its loop device"
	echo "rm [name]: deletes a virtual disk"
	exit 0
fi

[ "$UID" -ne 0 ] && echo "This program must be run as root." >&2 && exit 1

[ ! -d "/var/vhdutil" ] && echo "Creating working directory" && mkdir /var/vhdutil

case "$1" in
	"create")
		[ "$#" -lt 3 ] && echo "Insufficient arguments passed." >&2 && exit 1
		NAME="$2"
		CAPACITY="$3"
		echo "Creating virtual disk ${NAME}, ${CAPACITY} MB"
		fallocate -l "${CAPACITY}M" "/var/vhdutil/${NAME}.vdsk"
		exit "$?";;
	"lsdisk")
		find "/var/vhdutil" -type f -name "*.vdsk" > /var/vhdutil/existing.disks
		COUNT="$(cat /var/vhdutil/existing.disks | wc -l)"
		if [ "$COUNT" -eq 0 ]; then
			echo "0 disks existing"
			rm /var/vhdutil/existing.disks
			exit 0
		fi
		echo "${COUNT} disks existing:"
		while IFS="" read -r DISKFILE; do
			DISKFILETRIMMED="${DISKFILE%?????}"
			DISKNAME="$(echo ${DISKFILETRIMMED} | cut -c 14-)"
			echo "${DISKNAME}"
		done < "/var/vhdutil/existing.disks" && rm /var/vhdutil/existing.disks
		exit "$?";;
	"attach")
		[ "$#" -lt 2 ] && echo "Insufficient arguments passed." >&2 && exit 1
		NAME="$2"
		[ ! -e "/var/vhdutil/${NAME}.vdsk" ] && echo "Invalid virtual disk." >&2 && exit 1
		DEVICE="$(losetup -f)"
		echo "Attaching virtual disk ${NAME} to loopback device ${DEVICE}"
		losetup -P "${DEVICE}" "/var/vhdutil/${NAME}.vdsk" && echo "${DEVICE}" > "/var/vhdutil/${NAME}.attached"
		exit "$?";;
	"lsattach")
		find "/var/vhdutil" -type f -name "*.attached" > /var/vhdutil/attached.disks
		COUNT="$(cat /var/vhdutil/attached.disks | wc -l)"	
		if [ "$COUNT" -eq 0 ]; then
			echo "0 disks attached"
			rm /var/vhdutil/attached.disks
			exit 0
		fi
		echo "${COUNT} disks attached:"
		while IFS="" read -r DISKFILE; do
			DISKFILETRIMMED="${DISKFILE%?????????}"
			DISKNAME="$(echo ${DISKFILETRIMMED} | cut -c 14-)"
			DISKDEVICE="$(cat /var/vhdutil/${DISKNAME}.attached)"
			echo "${DISKNAME}: ${DISKDEVICE}"
		done < "/var/vhdutil/attached.disks" && rm /var/vhdutil/attached.disks
		exit "$?";;
	"encrypt")
		[ "$#" -lt 3 ] && echo "Insufficient arguments passed." >&2 && exit 1
		NAME="$2"
		PARTITION="$3"
		[ ! -e "/var/vhdutil/${NAME}.vdsk" ] && echo "Invalid virtual disk." >&2 && exit 1
		[ ! -e "/var/vhdutil/${NAME}.attached" ] && echo "The specified disk is not attached." >&2 && exit 1
		ORIGIN="$(cat /var/vhdutil/${NAME}.attached)"
		DEVICE="${ORIGIN}p${PARTITION}"
		[ ! -e "${DEVICE}" ] && echo "Invalid virtual partition." >&2 && exit 1
		which cryptsetup > /dev/null 2>&1
		[ "$?" -ne 0 ] && echo "cryptsetup is not installed." >&2 && exit 1
		echo "Encrypting partition ${PARTITION} of disk ${NAME} at ${DEVICE}"
		cryptsetup -y -v luksFormat "${DEVICE}" && touch "/var/vhdutil/${NAME}.${PARTITION}.encrypted"
		exit "$?";;
	"format")
		[ "$#" -lt 4 ] && echo "Insufficient arguments passed." >&2 && exit 1
		NAME="$2"
		PARTITION="$3"
		FILESYSTEM="$4"
		[ ! -e "/var/vhdutil/${NAME}.vdsk" ] && echo "Invalid virtual disk." >&2 && exit 1
		[ ! -e "/var/vhdutil/${NAME}.attached" ] && echo "The specified virtual disk is not attached." >&2 && exit 1
		ORIGIN="$(cat /var/vhdutil/${NAME}.attached)"
		DEVICE="${ORIGIN}p${PARTITION}"
		[ ! -e "${DEVICE}" ] && echo "Invalid virtual partition." >&2 && exit 1
		which "mkfs.${FILESYSTEM}" > /dev/null 2>&1
		[ "$?" -ne 0 ] && echo "The specified filesystem is missing formatting tools." >&2 && exit 1
		if [ -e "/var/vhdutil/${NAME}.${PARTITION}.encrypted" ]; then
			which cryptsetup > /dev/null 2>&1
			[ "$?" -ne 0 ] && echo "cryptsetup is not installed." >&2 && exit 1 
			cryptsetup luksOpen "${DEVICE}" "${NAME}${PARTITION}"
			[ "$?" -ne 0 ] && echo "cryptsetup failed." >&2 && exit 1
			DEVICE="/dev/mapper/${NAME}${PARTITION}"
		fi
		echo "Formatting partition ${PARTITION} of disk ${NAME} at ${DEVICE} using ${FILESYSTEM}"
		if [[ "${FILESYSTEM}" == "ntfs" ]]; then
			echo "Detected NTFS, quick-formatting"
			mkfs.ntfs -Q "${DEVICE}"
		fi
		"mkfs.${FILESYSTEM}" "${DEVICE}"
		if [ -e "/var/vhdutil/${NAME}.${PARTITION}.encrypted" ]; then
			umount "${DEVICE}" > /dev/null 2>&1 # cryptsetup might give us an ioctl error
			cryptsetup luksClose "${NAME}${PARTITION}"
		fi
		exit "$?";;
	"mount")
		[ "$#" -lt 4 ] && echo "Insufficient arguments passed." >&2 && exit 1
		NAME="$2"
		PARTITION="$3"
		TARGET="$4"
		[ ! -e "/var/vhdutil/${NAME}.vdsk" ] && echo "Invalid virtual disk." >&2 && exit 1
		[ ! -e "/var/vhdutil/${NAME}.attached" ] && echo "The specified virtual disk is not attached." >&2 && exit 1
		ORIGIN="$(cat /var/vhdutil/${NAME}.attached)"
		DEVICE="${ORIGIN}p${PARTITION}"
		[ ! -e "${DEVICE}" ] && echo "Invalid virtual partition." >&2 && exit 1
		[ ! -d "${TARGET}" ] && echo "Target directory does not exist, automatically creating" && mkdir "${TARGET}"
		if [ -e "/var/vhdutil/${NAME}.${PARTITION}.encrypted" ]; then
			which cryptsetup > /dev/null 2>&1
			[ "$?" -ne 0 ] && echo "cryptsetup is not installed." >&2 && exit 1
			cryptsetup luksOpen "${DEVICE}" "${NAME}${PARTITION}"
			[ "$?" -ne 0 ] && echo "cryptsetup failed." >&2 && exit 1
			DEVICE="/dev/mapper/${NAME}${PARTITION}"
		fi
		echo "Mounting partition ${PARTITION} of disk ${NAME} at ${DEVICE} to ${TARGET}"
		mount "${DEVICE}" "${TARGET}" > /dev/null 2>&1
		if [ "$?" -ne 0 ]; then
			echo "Mounting failed." >&2
			if [[ "${DEVICE}" == "/dev/mapper/${NAME}${PARTITION}" ]]; then
				which cryptsetup > /dev/null 2>&1
				[ "$?" -ne 0 ] && echo "cryptsetup is not installed." >&2 && exit 1
				cryptsetup luksClose "${NAME}${PARTITION}"
				[ "$?" -ne 0 ] && echo "cryptsetup failed." >&2 && exit 1
			fi
			exit 1
		fi
		echo "${TARGET}" >> "/var/vhdutil/${NAME}.mountpoints"
		if [[ "${DEVICE}" == "/dev/mapper/${NAME}${PARTITION}" ]]; then
			echo "${NAME}${PARTITION}" >> "/var/vhdutil/${NAME}.mountedencrypted"
		fi
		exit "$?";;
	"umount")
		[ "$#" -lt 2 ] && echo "Insufficient arguments passed." >&2 && exit 1
		NAME="$2"
		[ ! -e "/var/vhdutil/${NAME}.vdsk" ] && echo "Invalid virtual disk." >&2 && exit 1
		[ ! -e "/var/vhdutil/${NAME}.attached" ] && echo "Disk not attached, no partitions mounted" && exit 0
		if [ -e "/var/vhdutil/${NAME}.mountpoints" ]; then
			echo "Unmounting standard mountpoints of disk ${NAME}"
			tac "/var/vhdutil/${NAME}.mountpoints" | xargs umount
			rm "/var/vhdutil/${NAME}.mountpoints"
		fi
		if [ -e "/var/vhdutil/${NAME}.mountedencrypted" ]; then
			which cryptsetup > /dev/null 2>&1
			[ "$?" -ne 0 ] && echo "cryptsetup is not installed." >&2 && exit 1
			echo "Closing all encrypted partitions of disk ${NAME}"
			cat "/var/vhdutil/${NAME}.mountedencrypted" | xargs cryptsetup luksClose
			[ "$?" -ne 0 ] && echo "cryptsetup failed." >&2 && exit 1
			rm "/var/vhdutil/${NAME}.mountedencrypted"
		fi
		exit 0;;
	"detach")
		[ "$#" -lt 2 ] && echo "Insufficient arguments passed." >&2 && exit 1
		NAME="$2"
		[ ! -e "/var/vhdutil/${NAME}.vdsk" ] && echo "Invalid virtual disk." >&2 && exit 1
		[ ! -e "/var/vhdutil/${NAME}.attached" ] && echo "Disk not attached, no need to detach" && exit 0
		[ -e "/var/vhdutil/${NAME}.mountpoints" ] && echo "The disk has mounted partitions." >&2 && exit 1
		[ -e "/var/vhdutil/${NAME}.mountedencrypted" ] && echo "The disk has open encrypted mapper devices." >&2 && exit 1
		DEVICE="$(cat /var/vhdutil/${NAME}.attached)"
		echo "Detaching virtual disk ${NAME} from loopback device ${DEVICE}"
		losetup -d "${DEVICE}" && rm "/var/vhdutil/${NAME}.attached"
		exit "$?";;
	"rm")
		[ "$#" -lt 2 ] && echo "Insufficient arguments passed." >&2 && exit 1
		NAME="$2"
		[ ! -e "/var/vhdutil/${NAME}.vdsk" ] && echo "Virtual disk does not exist, no need to delete" && exit 0
		[ -e "/var/vhdutil/${NAME}.attached" ] && echo "The specified virtual disk is currently attached." >&2 && exit 1
		[ -e "/var/vhdutil/${NAME}.mountpoints" ] && echo "The disk has mounted partitions." >&2 && exit 1
		[ -e "/var/vhdutil/${NAME}.mountedencrypted" ] && echo "The disk has open encrypted mapper devices." >&2 && exit 1
		echo "Removing virtual disk ${NAME}"
		rm "/var/vhdutil/${NAME}.vdsk"
		exit "$?";;
	*)
		echo "Invalid subcommand given." >&2 && exit 1;;
esac

