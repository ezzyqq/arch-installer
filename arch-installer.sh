#!/bin/bash

SYS_TEMP_DIR="/new-system"

echo "--- Partitioning ---"
echo "Select target disk"
mapfile -t disklist < <(lsblk -dpno NAME,SIZE,MODEL)
for i in "${!disklist[@]}"; do
    echo "$((i+1))) ${disklist[$i]}"
done
read -p "> " choice
disksel=$(echo "${disklist[$((choice-1))]}" | awk '{print $1}')

# Umounts for no issues when debugging
umount "${disksel}"* 2>/dev/null
swapoff "${disksel}"* 2>/dev/null
echo -e "Selected: ${disksel}\n"

read -p "Start cfdisk utility (y/n): " ans
if [[ "$ans" == "y" ]]; then
    cfdisk "$disksel"
else
    echo "Skipping"
fi

echo -e "\nSelect partition for root (/)"
mapfile -t partlist < <(lsblk -lpno NAME,SIZE,TYPE,FSTYPE "$disksel" | grep " part ")
for i in "${!partlist[@]}"; do
    echo "$((i+1))) ${partlist[$i]}"
done
read -p "> " choice
rootpart=$(echo "${partlist[$((choice-1))]}" | awk '{print $1}')
echo "Selected: ${rootpart}"

read -p "Are you sure you want to format ${rootpart}? (y/n): " ans
if [[ "$ans" == "y" ]]; then
    mkfs.ext4 "$rootpart"
else
    echo "Skipping"
fi

echo "Mounting root partition (${rootpart}) to temporary directory..."
mkdir -p "$SYS_TEMP_DIR"
mount "$rootpart" "$SYS_TEMP_DIR"

echo -e "\nSelect EFI partition (/boot/efi)"
mapfile -t partlist < <(lsblk -lpno NAME,SIZE,TYPE,FSTYPE "$disksel" | grep " part ")
for i in "${!partlist[@]}"; do
    echo "$((i+1))) ${partlist[$i]}"
done
read -p "> " choice
bootpart=$(echo "${partlist[$((choice-1))]}" | awk '{print $1}')
echo "Selected: ${bootpart}"

read -p "Are you sure you want to format ${bootpart}? (y/n): " ans
if [[ "$ans" == "y" ]]; then
    mkfs.fat -F 32 "$bootpart"
else
    echo "Skipping"
fi

echo "Mounting boot partition (${bootpart})..."
mkdir -p "$SYS_TEMP_DIR/boot/efi"
mount "$bootpart" "$SYS_TEMP_DIR/boot/efi"

read -p $'\nDo you have swap partition on '"$disksel"'? (y/n): ' ans
if [[ "$ans" == "y" ]]; then
    echo "Select swap partition"
    mapfile -t partlist < <(lsblk -lpno NAME,SIZE,TYPE,FSTYPE "$disksel" | grep " part ")
    for i in "${!partlist[@]}"; do
        echo "$((i+1))) ${partlist[$i]}"
    done
    read -p "> " choice
    swappart=$(echo "${partlist[$((choice-1))]}" | awk '{print $1}')
    echo "Selected: ${swappart}"

    read -p "Are you sure you want to format ${swappart}? (y/n): " ans
    if [[ "$ans" == "y" ]]; then
        mkswap "$swappart"
    else
        echo "Skipping"
    fi

    echo "Mounting swap partition (${swappart})..."
    swapon "$swappart"
fi

# lsblk for debug
echo ""
lsblk
echo ""
read -p "Press enter..."

echo -e "\n--- Installing system packages ---"
pacstrap "$SYS_TEMP_DIR" base linux-zen linux-zen-headers linux-firmware sof-firmware base-devel grub efibootmgr networkmanager fastfetch git mc bash-completion tree less gamemode xorg-fonts-misc gnu-free-fonts

echo -e "\n--- Finalizing ---"
echo "Generating /etc/fstab"
genfstab -U "$SYS_TEMP_DIR"
read -p "Press enter..."
genfstab -U "$SYS_TEMP_DIR" > "$SYS_TEMP_DIR/etc/fstab"

echo -e "\nEnabling NetworkManager"
arch-chroot "$SYS_TEMP_DIR" systemctl enable NetworkManager


echo "System Clock"
read -p "Your timezone region: " timezone
arch-chroot "$SYS_TEMP_DIR" ln -sf /usr/share/zoneinfo/"$timezone" /etc/localtime
arch-chroot "$SYS_TEMP_DIR" systemctl enable systemd-timesyncd
arch-chroot "$SYS_TEMP_DIR" hwclock --systohc


echo "Generating locales"
arch-chroot "$SYS_TEMP_DIR" mcedit /etc/locale.gen
arch-chroot "$SYS_TEMP_DIR" locale-gen

echo -e "\nSelect system locale"
mapfile -t localelist < <(arch-chroot "$SYS_TEMP_DIR" localectl list-locales)
for i in "${!localelist[@]}"; do
    echo "$((i+1))) ${localelist[$i]}"
done
read -p "> " choice
syslocale=$(echo "${localelist[$((choice-1))]}" | awk '{print $1}')
echo "Selected: ${syslocale}"
arch-chroot "$SYS_TEMP_DIR" localectl set-locale LANG="$syslocale"


echo ""
read -p "Pick a hostname (Like archlinux): " hostname
echo "$hostname" > "$SYS_TEMP_DIR/etc/hostname"

echo "Pick a password for root user"
arch-chroot "$SYS_TEMP_DIR" passwd root

echo ""
read -p "Pick a username for your new user: " username
arch-chroot "$SYS_TEMP_DIR" useradd -m -G wheel,gamemode -s /bin/bash "$username"

echo "Pick a password for $username"
arch-chroot "$SYS_TEMP_DIR" passwd "$username"

echo -e "\nAdding wheel to sudoers"
sed -i 's/^# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' "$SYS_TEMP_DIR/etc/sudoers"

echo -e "\nEditing pacman.conf"
echo 'Uncomment "Color" and add "ILoveCandy" in "# Misc options"'
echo 'Uncomment "#[multilib]" and "#Include = ..."'
read -p "Press enter..."
arch-chroot "$SYS_TEMP_DIR" mcedit /etc/pacman.conf

echo -e "\nInstalling lib32-gamemode"
arch-chroot "$SYS_TEMP_DIR" pacman -S --noconfirm lib32-gamemode

echo -e "\nBootloader installation (grub)"
arch-chroot "$SYS_TEMP_DIR" grub-install "$disksel"
arch-chroot "$SYS_TEMP_DIR" grub-mkconfig -o /boot/grub/grub.cfg

echo -e "\nAUR"
PKG_DIR="/home/$username/yay"

arch-chroot "$SYS_TEMP_DIR" su - "$username" -c "git clone https://aur.archlinux.org/yay.git $PKG_DIR"

arch-chroot "$SYS_TEMP_DIR" pacman -Syu --noconfirm

arch-chroot "$SYS_TEMP_DIR" pacman -S --noconfirm --asdeps go

arch-chroot "$SYS_TEMP_DIR" su - "$username" -c "cd $PKG_DIR && makepkg --noconfirm"
arch-chroot "$SYS_TEMP_DIR" bash -c "pacman -U --noconfirm $PKG_DIR/*.pkg.tar.zst"

rm -rf "$SYS_TEMP_DIR""$PKG_DIR"
