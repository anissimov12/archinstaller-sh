#!/bin/bash

set -e

DISK=""
HOSTNAME=""
USERNAME=""
PASSWORD=""
FILESYSTEM=""
SEPARATE_HOME=false
ENABLE_SWAP=false
SWAP_SIZE="4G"
EFI_SIZE="512M"
ROOT_SIZE=""
HOME_SIZE=""

check_root() {
    [[ $EUID -ne 0 ]] && { echo "Run as root"; exit 1; }
}

check_uefi() {
    [[ ! -d /sys/firmware/efi ]] && { echo "UEFI mode required"; exit 1; }
}

menu() {
    local title="$1"
    shift
    local options=("$@")
    
    dialog --clear --title "$title" --menu "Use arrow keys to navigate" 15 60 8 "${options[@]}" 3>&1 1>&2 2>&3
}

yesno() {
    dialog --clear --title "$1" --yesno "$2" 8 60
}

inputbox() {
    dialog --clear --title "$1" --inputbox "$2" 10 60 3>&1 1>&2 2>&3
}

passwordbox() {
    dialog --clear --title "$1" --passwordbox "$2" 10 60 3>&1 1>&2 2>&3
}

msgbox() {
    dialog --clear --title "$1" --msgbox "$2" 10 60
}

gauge() {
    dialog --clear --title "$1" --gauge "$2" 8 60 0
}

select_disk() {
    local disks=()
    while IFS= read -r line; do
        local name=$(echo "$line" | awk '{print $1}')
        local size=$(echo "$line" | awk '{print $2}')
        disks+=("$name" "$size")
    done < <(lsblk -dpnoNAME,SIZE | grep -v "loop\|rom")
    
    DISK=$(menu "Disk Selection" "${disks[@]}")
    [[ -z "$DISK" ]] && exit 1
    
    local disk_info=$(lsblk -o NAME,SIZE,TYPE,MOUNTPOINT "$DISK" | tail -n +2)
    yesno "Confirm Disk" "Selected: $DISK\n\n$disk_info\n\nWARNING: All data will be destroyed!" || exit 1
}

select_filesystem() {
    FILESYSTEM=$(menu "Filesystem Type" \
        "ext4" "Stable, widely supported" \
        "btrfs" "Modern, snapshots, compression" \
        "xfs" "High performance, large files" \
        "f2fs" "Flash-optimized (SSD)")
    [[ -z "$FILESYSTEM" ]] && exit 1
}

configure_partitions() {
    yesno "Separate /home" "Create separate /home partition?" && SEPARATE_HOME=true
    
    yesno "Enable Swap" "Create swap partition?" && {
        ENABLE_SWAP=true
        SWAP_SIZE=$(inputbox "Swap Size" "Enter swap size (e.g., 4G, 8G):" || echo "4G")
    }
    
    if $SEPARATE_HOME; then
        ROOT_SIZE=$(inputbox "Root Size" "Enter root partition size (e.g., 50G):" || echo "50G")
    fi
}

wipe_disk() {
    echo "0" | gauge "Wiping Disk" "Securely wiping partition table..."
    wipefs -af "$DISK" >/dev/null 2>&1
    sgdisk -Z "$DISK" >/dev/null 2>&1
    echo "100" | gauge "Wiping Disk" "Complete"
    sleep 1
}

create_partitions() {
    local current=1
    local efi_end=$((1 + ${EFI_SIZE%M}))
    local swap_end=$efi_end
    local root_end=$swap_end
    local home_end=$root_end
    
    echo "10" | gauge "Partitioning" "Creating GPT table..."
    parted -s "$DISK" mklabel gpt
    
    echo "20" | gauge "Partitioning" "Creating EFI partition..."
    parted -s "$DISK" mkpart ESP fat32 1MiB ${EFI_SIZE}
    parted -s "$DISK" set 1 esp on
    
    if $ENABLE_SWAP; then
        echo "40" | gauge "Partitioning" "Creating swap partition..."
        swap_end=$((efi_end + ${SWAP_SIZE%G} * 1024))
        parted -s "$DISK" mkpart primary linux-swap ${efi_end}MiB ${swap_end}MiB
        current=$((current + 1))
    fi
    
    echo "60" | gauge "Partitioning" "Creating root partition..."
    if $SEPARATE_HOME && [[ -n "$ROOT_SIZE" ]]; then
        root_end=$((swap_end + ${ROOT_SIZE%G} * 1024))
        parted -s "$DISK" mkpart primary $FILESYSTEM ${swap_end}MiB ${root_end}MiB
        current=$((current + 1))
        
        echo "80" | gauge "Partitioning" "Creating home partition..."
        parted -s "$DISK" mkpart primary $FILESYSTEM ${root_end}MiB 100%
    else
        parted -s "$DISK" mkpart primary $FILESYSTEM ${swap_end}MiB 100%
    fi
    
    echo "100" | gauge "Partitioning" "Complete"
    sleep 1
    
    partprobe "$DISK"
    sleep 2
}

format_partitions() {
    local part_num=1
    
    echo "10" | gauge "Formatting" "Formatting EFI partition..."
    mkfs.fat -F32 "${DISK}${part_num}" >/dev/null 2>&1
    part_num=$((part_num + 1))
    
    if $ENABLE_SWAP; then
        echo "30" | gauge "Formatting" "Creating swap..."
        mkswap "${DISK}${part_num}" >/dev/null 2>&1
        swapon "${DISK}${part_num}"
        part_num=$((part_num + 1))
    fi
    
    echo "50" | gauge "Formatting" "Formatting root partition..."
    case $FILESYSTEM in
        ext4) mkfs.ext4 -F "${DISK}${part_num}" >/dev/null 2>&1 ;;
        btrfs) mkfs.btrfs -f "${DISK}${part_num}" >/dev/null 2>&1 ;;
        xfs) mkfs.xfs -f "${DISK}${part_num}" >/dev/null 2>&1 ;;
        f2fs) mkfs.f2fs -f "${DISK}${part_num}" >/dev/null 2>&1 ;;
    esac
    part_num=$((part_num + 1))
    
    if $SEPARATE_HOME; then
        echo "80" | gauge "Formatting" "Formatting home partition..."
        case $FILESYSTEM in
            ext4) mkfs.ext4 -F "${DISK}${part_num}" >/dev/null 2>&1 ;;
            btrfs) mkfs.btrfs -f "${DISK}${part_num}" >/dev/null 2>&1 ;;
            xfs) mkfs.xfs -f "${DISK}${part_num}" >/dev/null 2>&1 ;;
            f2fs) mkfs.f2fs -f "${DISK}${part_num}" >/dev/null 2>&1 ;;
        esac
    fi
    
    echo "100" | gauge "Formatting" "Complete"
    sleep 1
}

mount_partitions() {
    local part_num=1
    
    part_num=$((part_num + 1))
    $ENABLE_SWAP && part_num=$((part_num + 1))
    
    mount "${DISK}${part_num}" /mnt
    
    if [[ "$FILESYSTEM" == "btrfs" ]]; then
        btrfs subvolume create /mnt/@ >/dev/null 2>&1
        btrfs subvolume create /mnt/@snapshots >/dev/null 2>&1
        umount /mnt
        mount -o subvol=@ "${DISK}${part_num}" /mnt
    fi
    
    mkdir -p /mnt/boot
    mount "${DISK}1" /mnt/boot
    
    if $SEPARATE_HOME; then
        part_num=$((part_num + 1))
        mkdir -p /mnt/home
        mount "${DISK}${part_num}" /mnt/home
    fi
}

install_base() {
    local packages="base linux linux-firmware networkmanager grub efibootmgr sudo"
    
    [[ "$FILESYSTEM" == "btrfs" ]] && packages="$packages btrfs-progs"
    [[ "$FILESYSTEM" == "xfs" ]] && packages="$packages xfsprogs"
    [[ "$FILESYSTEM" == "f2fs" ]] && packages="$packages f2fs-tools"
    
    pacstrap /mnt $packages 2>&1 | \
        stdbuf -oL tr '\r' '\n' | \
        grep -o '[0-9]\+%' | \
        sed 's/%//' | \
        dialog --clear --title "Installing Base System" --gauge "Installing packages..." 8 60 0
}

generate_fstab() {
    genfstab -U /mnt >> /mnt/etc/fstab
}

configure_system() {
    arch-chroot /mnt /bin/bash <<EOF
    ln -sf /usr/share/zoneinfo/Europe/Zurich /etc/localtime
    hwclock --systohc
    sed -i 's/#en_US.UTF-8/en_US.UTF-8/' /etc/locale.gen
    locale-gen
    echo LANG=en_US.UTF-8 > /etc/locale.conf
    echo $HOSTNAME > /etc/hostname
    echo root:$PASSWORD | chpasswd
    systemctl enable NetworkManager
    useradd -m -G wheel -s /bin/bash $USERNAME
    echo $USERNAME:$PASSWORD | chpasswd
    sed -i 's/# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers
    grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=GRUB
    grub-mkconfig -o /boot/grub/grub.cfg
EOF
}

get_user_input() {
    HOSTNAME=$(inputbox "Hostname" "Enter hostname:")
    [[ -z "$HOSTNAME" ]] && exit 1
    
    USERNAME=$(inputbox "Username" "Enter username:")
    [[ -z "$USERNAME" ]] && exit 1
    
    PASSWORD=$(passwordbox "Password" "Enter password:")
    [[ -z "$PASSWORD" ]] && exit 1
    
    local password2=$(passwordbox "Password" "Confirm password:")
    [[ "$PASSWORD" != "$password2" ]] && { msgbox "Error" "Passwords do not match"; exit 1; }
}

show_summary() {
    local summary="Disk: $DISK\nFilesystem: $FILESYSTEM\n"
    summary+="Separate /home: $SEPARATE_HOME\n"
    summary+="Swap: $ENABLE_SWAP"
    $ENABLE_SWAP && summary+=" ($SWAP_SIZE)"
    summary+="\nHostname: $HOSTNAME\nUsername: $USERNAME"
    
    yesno "Installation Summary" "$summary\n\nProceed with installation?" || exit 1
}

cleanup() {
    clear
    umount -R /mnt 2>/dev/null || true
    swapoff -a 2>/dev/null || true
}

main() {
    trap cleanup EXIT ERR
    
    check_root
    check_uefi
    
    command -v dialog >/dev/null || pacman -Sy --noconfirm dialog
    
    select_disk
    select_filesystem
    configure_partitions
    get_user_input
    show_summary
    
    wipe_disk
    create_partitions
    format_partitions
    mount_partitions
    install_base
    generate_fstab
    configure_system
    
    clear
    msgbox "Installation Complete" "System installed successfully!\n\nPress OK to reboot."
    reboot
}

main
