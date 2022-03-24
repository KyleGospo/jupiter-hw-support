#!/bin/bash

set -e

MOUNT_LOCK="/var/run/sdcard-mount.lock"
SDCARD_DEVICE="/dev/mmcblk0"
SDCARD_PARTITION="/dev/mmcblk0p1"

if [[ ! -e "$SDCARD_DEVICE" ]]; then
    exit 19 #ENODEV
fi

systemctl stop sdcard-mount@mmcblk0p1.service

# lock file prevents the mount service from re-mounting as it gets triggered by udev rules
on_exit() { rm -f -- "$MOUNT_LOCK"; }
trap on_exit EXIT
echo $$ > "$MOUNT_LOCK"

# Test the sdcard
# Some fake cards advertise a larger size than their actual capacity,
# which can result in data loss or other unexpected behaviour. It is
# best to try to detect these issues as early as possible.
echo "stage=testing"
if ! f3probe --destructive "$SDCARD_DEVICE"; then
    # Fake sdcards tend to only behave correctly when formatted as exfat
    # The tricks they try to pull fall apart with any other filesystem and
    # it renders the card unusuable.
    #
    # Here we restore the card to exfat so that it can be used with other devices.
    # It won't be usable with the deck, and usage of the card will most likely
    # result in data loss. We return a special error code so we can surface
    # a specific error to the user.
    echo "stage=rescuing"
    echo "Bad sdcard - rescuing"
    for i in {1..3}; do # Give this a couple of tries since it fails sometimes
        echo "Create partition table: $i"
        if ! parted --script "$SDCARD_DEVICE" mklabel msdos mkpart primary 0% 100% ; then
            echo "Failed to create partition table: $i"
            continue # try again
        fi

        echo "Create exfat filesystem: $i"
        sync
        if ! mkfs.exfat "$SDCARD_PARTITION"; then
            echo "Failed to exfat filesystem: $i"
            continue # try again
        fi

        echo "Successfully restored device"
        break
    done

    # Return a specific error code so the UI can warn the user about this bad device
    exit 14 # EFAULT
fi

# Format as EXT4 with casefolding for proton compatibility
echo "stage=formatting"
sync
parted --script "$SDCARD_DEVICE" mklabel gpt mkpart primary 0% 100%
sync
mkfs.ext4 -m 0 -O casefold -F "$SDCARD_PARTITION"
sync

rm "$MOUNT_LOCK"
systemctl start sdcard-mount@mmcblk0p1.service

exit 0
