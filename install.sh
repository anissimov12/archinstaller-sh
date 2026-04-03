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

print_header() {
    clear
    echo "================================"
    echo "  Arch Linux Installer"
    echo "================================"
    echo ""
}

menu() {
    local title="$1"
    shift
    local prompt="$2"
    shift 2
    local options=("$@")
    
    print_header
    echo "$title"
    echo ""
    
    local i=1
    while [[ $i -le ${#options[@]} ]]; do
        echo "  $((i/2 + 1)). ${options[$((i-1))]}"
        i=$((i + 2))
    done
    echo ""
    read -rp "Select [1-$((${#options[@]}/2))]: " choice
    
    local idx=$(( (choice - 1) * 2 ))
    echo "${options[$idx]}"
}

yesno() {
    local title="$1"
    local msg="$2"
    
    print_header
    echo "$title"
    echo ""
    echo "$msg"
    echo ""
    read -rp "Continue? [y/N]: " answer
    [[ "$answer" =~ ^[Yy]$ ]]
}

inputbox() {
    local title="$1"
    local prompt="$2"
    
    print_header
    echo "$title"
    echo ""
    read -rp "$prompt " value
    echo "$value"
}

passwordbox() {
    local title="$1"
    local prompt="$2"
    
    print_header
    echo "$title"
    echo ""
    read -rsp "$prompt " value
    echo ""
    echo "$value"
}

msgbox() {
    local title="$1"
    local msg="$2"
    
    print_header
    echo "$title"
    echo ""
    echo "$msg"
    echo ""
    read -rp "Press Enter to continue..."
}

progress() {
    local title="$1"
    local msg="$2"
    
    print_header
    echo "$title"
    echo ""
    echo "$msg"
}

select_disk() {
    local disks=()
    while IFS= read -r line; do
        local name=$(echo "$line" | awk '{print $1}')
        local size=$(echo "$line" | awk '{print $2}')
        disks+=("$name" "$size")
    done < <(lsblk -dpnoNAME,SIZE | grep -v "loop\|rom")
    
    DISK=$(menu "Disk Selection" "Choose installation disk:" "${disks[@]}")
    [[ -z "$DISK" ]] && exit 1
    
    print_header
    echo "Selected Disk: $DISK"
    echo ""
    lsblk -o NAME,SIZE,TYPE,MOUNTPOINT "$DISK"
    echo ""
    echo "WARNING: All data will be destroyed!"
    echo ""
    yesno "Confirm" "Proceed with $DISK?" || exit 1
}

select_filesystem() {
    FILESYSTEM=$(menu "Filesystem Type" "Choose filesystem:" \
        "ext4" "Stable" \
        "btrfs" "Snapshots" \
        "xfs" "Performance" \
        "f2fs" "SSD")
    [[ -z "$FILESYSTEM" ]] && exit 1
}

configure_partitions() {
    yesno "Separate /home" "Create separate /home partition?" && SEPARATE_HOME=true
    
    yesno "Enable Swap" "Create swap partition?" && {
        ENABLE_SWAP=true
        SWAP_SIZE=$(inputbox "Swap Size" "Size (e.g., 4G, 8G):")
        [[ -z "$SWAP_SIZE" ]] && SWAP_SIZE="4G"
    }
    
    if $SEPARATE_HOME; then
        ROOT_SIZE=$(inputbox "Root Size" "Size (e.g., 50G):")
        [[ -z "$ROOT_SIZE" ]] && ROOT_SIZE="50G"
    fi
}

wipe_disk() {
    progress "Wiping Disk" "Clearing partition table..."
    wipefs -af "$DISK" >/dev/null 2>&1
    sgdisk -Z "$DISK" >/dev/null 2>&1
    sleep 1
}

create_partitions() {
    local current=1
    local efi_end=$((1 + ${EFI_SIZE%M}))
    local swap_end=$efi_end
    local root_end=$swap_end
    
    progress "Partitioning" "Creating GPT table..."
    parted -s "$DISK" mklabel gpt
    
    progress "Partitioning" "Creating EFI partition..."
    parted -s "$DISK" mkpart ESP fat32 1MiB ${EFI_SIZE}
    parted -s "$DISK" set 1 esp on
    
    if $ENABLE_SWAP; then
        progress "Partitioning" "Creating swap partition..."
        swap_end=$((efi_end + ${SWAP_SIZE%G} * 1024))
        parted -s "$DISK" mkpart primary linux-swap ${efi_end}MiB ${swap_end}MiB
        current=$((current + 1))
    fi
    
    progress "Partitioning" "Creating root partition..."
    if $SEPARATE_HOME && [[ -n "$ROOT_SIZE" ]]; then
        root_end=$((swap_end + ${ROOT_SIZE%G} * 1024))
        parted -s "$DISK" mkpart primary $FILESYSTEM ${swap_end}MiB ${root_end}MiB
        current=$((current + 1))
        
        progress "Partitioning" "Creating home partition..."
        parted -s "$DISK" mkpart primary $FILESYSTEM ${root_end}MiB 100%
    else
        parted -s "$DISK" mkpart primary $FILESYSTEM ${swap_end}MiB 100%
    fi
    
    partprobe "$DISK"
    sleep 2
}

format_partitions() {
    local part_num=1
    
    progress "Formatting" "EFI partition..."
    mkfs.fat -F32 "${DISK}${part_num}" >/dev/null 2>&1
    part_num=$((part_num + 1))
    
    if $ENABLE_SWAP; then
        progress "Formatting" "Swap partition..."
        mkswap "${DISK}${part_num}" >/dev/null 2>&1
        swapon "${DISK}${part_num}"
        part_num=$((part_num + 1))
    fi
    
    progress "Formatting" "Root partition..."
    case $FILESYSTEM in
        ext4) mkfs.ext4 -F "${DISK}${part_num}" >/dev/null 2>&1 ;;
        btrfs) mkfs.btrfs -f "${DISK}${part_num}" >/dev/null 2>&1 ;;
        xfs) mkfs.xfs -f "${DISK}${part_num}" >/dev/null 2>&1 ;;
        f2fs) mkfs.f2fs -f "${DISK}${part_num}" >/dev/null 2>&1 ;;
    esac
    part_num=$((part_num + 1))
    
    if $SEPARATE_HOME; then
        progress "Formatting" "Home partition..."
        case $FILESYSTEM in
            ext4) mkfs.ext4 -F "${DISK}${part_num}" >/dev/null 2>&1 ;;
            btrfs) mkfs.btrfs -f "${DISK}${part_num}" >/dev/null 2>&1 ;;
            xfs) mkfs.xfs -f "${DISK}${part_num}" >/dev/null 2>&1 ;;
            f2fs) mkfs.f2fs -f "${DISK}${part_num}" >/dev/null 2>&1 ;;
        esac
    fi
    
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
    
    progress "Installing" "Base system packages..."
    pacstrap /mnt $packages
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
    HOSTNAME=$(inputbox "Hostname" "Hostname:")
    [[ -z "$HOSTNAME" ]] && exit 1
    
    USERNAME=$(inputbox "Username" "Username:")
    [[ -z "$USERNAME" ]] && exit 1
    
    PASSWORD=$(passwordbox "Password" "Password:")
    [[ -z "$PASSWORD" ]] && exit 1
    
    local password2=$(passwordbox "Password" "Confirm:")
    [[ "$PASSWORD" != "$password2" ]] && { msgbox "Error" "Passwords do not match"; exit 1; }
}

show_summary() {
    print_header
    echo "Installation Summary"
    echo ""
    echo "  Disk: $DISK"
    echo "  Filesystem: $FILESYSTEM"
    echo "  Separate /home: $SEPARATE_HOME"
    echo -n "  Swap: $ENABLE_SWAP"
    $ENABLE_SWAP && echo " ($SWAP_SIZE)" || echo ""
    echo "  Hostname: $HOSTNAME"
    echo "  Username: $USERNAME"
    echo ""
    yesno "Confirm" "Proceed with installation?" || exit 1
}

cleanup() {
    umount -R /mnt 2>/dev/null || true
    swapoff -a 2>/dev/null || true
}

main() {
    trap cleanup EXIT ERR
    
    check_root
    check_uefi
    
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
    
    msgbox "Complete" "Installation successful! System will reboot."
    reboot
}

main
