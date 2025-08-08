#!/bin/bash

# Arch Linux Installation Script with Hyprland Setup
# Run this script from the Arch Linux installation ISO

set -e  # Exit on any error

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Function to print colored output
print_status() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

print_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Function to prompt for user input
prompt_input() {
    local prompt="$1"
    local var_name="$2"
    local default="$3"
    
    if [ -n "$default" ]; then
        read -p "$prompt [$default]: " input
        eval "$var_name=\"\${input:-$default}\""
    else
        read -p "$prompt: " input
        eval "$var_name=\"$input\""
    fi
}

# Function to prompt for password
prompt_password() {
    local prompt="$1"
    local var_name="$2"
    local password
    local password_confirm
    
    while true; do
        read -s -p "$prompt: " password
        echo
        read -s -p "Confirm password: " password_confirm
        echo
        
        if [ "$password" = "$password_confirm" ]; then
            eval "$var_name=\"$password\""
            break
        else
            print_error "Passwords do not match. Please try again."
        fi
    done
}

# Check if running as root
check_root() {
    if [ "$EUID" -ne 0 ]; then
        print_error "This script must be run as root"
        exit 1
    fi
}

# Check internet connection
check_internet() {
    print_status "Checking internet connection..."
    if ping -c 1 archlinux.org &> /dev/null; then
        print_success "Internet connection is working"
    else
        print_error "No internet connection. Please check your network settings."
        exit 1
    fi
}

# Update system clock
update_clock() {
    print_status "Updating system clock..."
    timedatectl set-ntp true
    print_success "System clock updated"
}

# List available disks
list_disks() {
    print_status "Available disks:"
    lsblk -dp -o NAME,SIZE,MODEL | grep -E "^/dev/(sd|nvme|vd)"
}

# Partition disk
partition_disk() {
    local disk="$1"
    
    print_status "Partitioning disk $disk..."
    print_warning "This will DESTROY ALL DATA on $disk!"
    
    read -p "Are you sure you want to continue? (yes/no): " confirm
    if [ "$confirm" != "yes" ]; then
        print_error "Aborted by user"
        exit 1
    fi
    
    # Unmount any existing partitions
    umount -R /mnt 2>/dev/null || true
    
    # Wipe disk
    wipefs -af "$disk"
    
    # Create GPT partition table
    parted -s "$disk" mklabel gpt
    
    # Create partitions
    parted -s "$disk" mkpart primary fat32 1MiB 513MiB      # EFI partition (512MB)
    parted -s "$disk" set 1 esp on
    parted -s "$disk" mkpart primary ext4 513MiB 200.5GiB   # Root partition (200GB)
    parted -s "$disk" mkpart primary linux-swap 200.5GiB 216.5GiB  # Swap partition (16GB)
    parted -s "$disk" mkpart primary ext4 216.5GiB 100%     # Home partition (rest of disk)
    
    print_success "Disk partitioned successfully"
    
    # Set partition variables based on disk type
    if [[ "$disk" == *"nvme"* ]]; then
        EFI_PART="${disk}p1"
        ROOT_PART="${disk}p2"
        SWAP_PART="${disk}p3"
        HOME_PART="${disk}p4"
    else
        EFI_PART="${disk}1"
        ROOT_PART="${disk}2"
        SWAP_PART="${disk}3"
        HOME_PART="${disk}4"
    fi
    
    # Wait for partitions to be recognized
    sleep 2
    partprobe "$disk"
    sleep 2
}

# Format partitions
format_partitions() {
    print_status "Formatting partitions..."
    
    # Format EFI partition
    mkfs.fat -F32 -n EFI "$EFI_PART"
    
    # Format root partition
    mkfs.ext4 -L ROOT "$ROOT_PART"
    
    # Format home partition
    mkfs.ext4 -L HOME "$HOME_PART"
    
    # Setup swap
    mkswap -L SWAP "$SWAP_PART"
    swapon "$SWAP_PART"
    
    print_success "Partitions formatted successfully"
}

# Mount partitions
mount_partitions() {
    print_status "Mounting partitions..."
    
    # Mount root
    mount "$ROOT_PART" /mnt
    
    # Create mount points
    mkdir -p /mnt/boot
    mkdir -p /mnt/home
    
    # Mount EFI
    mount "$EFI_PART" /mnt/boot
    
    # Mount home
    mount "$HOME_PART" /mnt/home
    
    print_success "Partitions mounted successfully"
}

# Install base system
install_base_system() {
    print_status "Installing base system..."
    
    # Update keyring
    pacman -Sy --noconfirm archlinux-keyring
    
    # Install base packages with zen kernel
    pacstrap /mnt base base-devel linux-zen linux-zen-headers linux-firmware networkmanager \
             os-prober ntfs-3g dosfstools mtools nano sudo git curl wget \
             pipewire pipewire-alsa pipewire-pulse pipewire-jack wireplumber zsh
    
    print_success "Base system installed"
}

# Generate fstab
generate_fstab() {
    print_status "Generating fstab..."
    genfstab -U /mnt >> /mnt/etc/fstab
    print_success "fstab generated"
}

# Configure system in chroot
configure_system() {
    print_status "Configuring system..."
    
    # Create configuration script for chroot
    cat > /mnt/configure_system.sh << 'EOF'
#!/bin/bash

# Set timezone
ln -sf /usr/share/zoneinfo/$TIMEZONE /etc/localtime
hwclock --systohc

# Set locale
echo "$LOCALE.UTF-8 UTF-8" >> /etc/locale.gen
locale-gen
echo "LANG=$LOCALE.UTF-8" > /etc/locale.conf

# Set keyboard layout
echo "KEYMAP=$KEYMAP" > /etc/vconsole.conf

# Set hostname
echo "$HOSTNAME" > /etc/hostname

# Configure hosts file
cat > /etc/hosts << EOL
127.0.0.1   localhost
::1         localhost
127.0.1.1   $HOSTNAME.localdomain $HOSTNAME
EOL

# Set root password
echo "root:$ROOT_PASSWORD" | chpasswd

# Create user
useradd -m -G wheel,audio,video,optical,storage -s /bin/zsh "$USERNAME"
echo "$USERNAME:$USER_PASSWORD" | chpasswd

# Configure sudo
sed -i 's/^# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers

# Enable NetworkManager
systemctl enable NetworkManager

# Configure systemd-boot
bootctl install

# Get the UUID of the root partition
ROOT_UUID=$(blkid -s UUID -o value $ROOT_PART)

# Create boot entry
cat > /boot/loader/entries/arch.conf << EOL
title   Arch Linux
linux   /vmlinuz-linux-zen
initrd  /initramfs-linux-zen.img
options root=UUID=$ROOT_UUID rw
EOL

# Configure boot loader
cat > /boot/loader/loader.conf << EOL
default arch
timeout 3
console-mode max
editor  no
EOL

EOF

    # Pass variables to script
    sed -i "s|\$TIMEZONE|$TIMEZONE|g" /mnt/configure_system.sh
    sed -i "s|\$LOCALE|$LOCALE|g" /mnt/configure_system.sh
    sed -i "s|\$KEYMAP|$KEYMAP|g" /mnt/configure_system.sh
    sed -i "s|\$HOSTNAME|$HOSTNAME|g" /mnt/configure_system.sh
    sed -i "s|\$ROOT_PASSWORD|$ROOT_PASSWORD|g" /mnt/configure_system.sh
    sed -i "s|\$USERNAME|$USERNAME|g" /mnt/configure_system.sh
    sed -i "s|\$USER_PASSWORD|$USER_PASSWORD|g" /mnt/configure_system.sh
    sed -i "s|\$ROOT_PART|$ROOT_PART|g" /mnt/configure_system.sh

    # Make script executable and run in chroot
    chmod +x /mnt/configure_system.sh
    arch-chroot /mnt /configure_system.sh
    rm /mnt/configure_system.sh
    
    print_success "System configured"
}

# Extended system setup with Hyprland
setup_extended_system() {
    print_status "Setting up extended system with Hyprland..."
    
    # Create extended setup script for chroot
    cat > /mnt/setup_extended.sh << 'EOF'
#!/bin/bash

# Update system
pacman -Syu --noconfirm

# Install essential packages
pacman -S --noconfirm wayland xorg-xwayland hyprland hyprpaper waybar swaync \
                      rofi thunar nwg-look ghostty polkit-kde-agent \
                      ttf-jetbrains-mono-nerd pipewire-pulse wireplumber \
                      pavucontrol playerctl brightnessctl grim slurp \
                      wl-clipboard xdg-desktop-portal-hyprland \
                      graphite-gtk-theme qt5ct qt6ct gtk3 gtk4

# Install AUR helper (yay)
cd /tmp
sudo -u $USERNAME git clone https://aur.archlinux.org/yay.git
cd yay
sudo -u $USERNAME makepkg -si --noconfirm
cd /

# Install AUR packages as user
sudo -u $USERNAME yay -S --noconfirm visual-studio-code-bin goxlr-utility-bin

# Setup Oh My Zsh for user
sudo -u $USERNAME sh -c "$(curl -fsSL https://raw.github.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" "" --unattended

# Install powerlevel10k
sudo -u $USERNAME git clone --depth=1 https://github.com/romkatv/powerlevel10k.git /home/$USERNAME/.oh-my-zsh/custom/themes/powerlevel10k

# Install zsh plugins
sudo -u $USERNAME git clone https://github.com/zsh-users/zsh-autosuggestions /home/$USERNAME/.oh-my-zsh/custom/plugins/zsh-autosuggestions
sudo -u $USERNAME git clone https://github.com/zsh-users/zsh-syntax-highlighting.git /home/$USERNAME/.oh-my-zsh/custom/plugins/zsh-syntax-highlighting

# Configure .zshrc
cat > /home/$USERNAME/.zshrc << 'ZSHEOF'
export ZSH="$HOME/.oh-my-zsh"
ZSH_THEME="powerlevel10k/powerlevel10k"
plugins=(git zsh-autosuggestions zsh-syntax-highlighting)
source $ZSH/oh-my-zsh.sh
ZSHEOF

chown $USERNAME:$USERNAME /home/$USERNAME/.zshrc

# Create Hyprland config directory
mkdir -p /home/$USERNAME/.config/hypr
chown -R $USERNAME:$USERNAME /home/$USERNAME/.config

# Create Hyprland configuration
cat > /home/$USERNAME/.config/hypr/hyprland.conf << 'HYPREOF'
# Monitor configuration
monitor = DP-1, 2560x1440@165, 0x0, 1, vrr, 1
monitor = DP-2, 2560x1440@165, 2560x0, 1

# Input settings
input {
    kb_layout = de
    kb_model = latin1
    follow_mouse = 1
    sensitivity = -0.4
    numlock_by_default = true
    accel_profile = false
}

# Variables
$terminal = ghostty
$fileManager = thunar
$menu = rofi

# Key bindings
$mainMod = SUPER

bind = $mainMod, T, exec, $terminal
bind = $mainMod, Q, killactive,
bind = $mainMod, M, exit,
bind = $mainMod, E, exec, $fileManager
bind = $mainMod, V, togglefloating,
bindr = SUPER, SUPER_L, exec, pkill $menu || $menu -show drun
bind = $mainMod, P, pseudo, # dwindle
bind = $mainMod, J, togglesplit, # dwindle
bind = $mainMod, R, exec, hyprctl reload

# Move focus with mainMod + arrow keys
bind = $mainMod SHIFT, left, movefocus, l
bind = $mainMod SHIFT, right, movefocus, r
bind = $mainMod SHIFT, up, movefocus, u
bind = $mainMod SHIFT, down, movefocus, d

bind = $mainMod, right, movewindow, r
bind = $mainMod, left, movewindow, l
bind = $mainMod, up, movewindow, u
bind = $mainMod, down, movewindow, d

# Switch workspaces with mainMod + [0-9]
bind = $mainMod, 1, workspace, 1
bind = $mainMod, 2, workspace, 2
bind = $mainMod, 3, workspace, 3
bind = $mainMod, 4, workspace, 4
bind = $mainMod, 5, workspace, 5
bind = $mainMod, 6, workspace, 6
bind = $mainMod, 7, workspace, 7
bind = $mainMod, 8, workspace, 8
bind = $mainMod, 9, workspace, 9
bind = $mainMod, 0, workspace, 10

# Move active window to a workspace with mainMod + SHIFT + [0-9]
bind = $mainMod SHIFT, 1, movetoworkspace, 1
bind = $mainMod SHIFT, 2, movetoworkspace, 2
bind = $mainMod SHIFT, 3, movetoworkspace, 3
bind = $mainMod SHIFT, 4, movetoworkspace, 4
bind = $mainMod SHIFT, 5, movetoworkspace, 5
bind = $mainMod SHIFT, 6, movetoworkspace, 6
bind = $mainMod SHIFT, 7, movetoworkspace, 7
bind = $mainMod SHIFT, 8, movetoworkspace, 8
bind = $mainMod SHIFT, 9, movetoworkspace, 9
bind = $mainMod SHIFT, 0, movetoworkspace, 10

# Special workspace
bind = $mainMod, S, togglespecialworkspace, magic
bind = $mainMod SHIFT, S, movetoworkspace, special:magic

# Scroll through workspaces
bind = $mainMod, mouse_down, workspace, e+1
bind = $mainMod, mouse_up, workspace, e-1

# Move/resize windows
bindm = $mainMod, mouse:272, movewindow
bindm = $mainMod, mouse:273, resizewindow

# Media keys
bindle=, XF86AudioRaiseVolume, exec, wpctl set-volume @DEFAULT_AUDIO_SINK@ 5%+
bindle=, XF86AudioLowerVolume, exec, wpctl set-volume @DEFAULT_AUDIO_SINK@ 5%-
bindle=, XF86MonBrightnessUp, exec, brightnessctl set 10%+
bindle=, XF86MonBrightnessDown, exec, brightnessctl set 10%-
bindl=, XF86AudioMute, exec, wpctl set-mute @DEFAULT_AUDIO_SINK@ toggle
bindl=, XF86AudioPlay, exec, playerctl play-pause
bindl=, XF86AudioNext, exec, playerctl next
bindl=, XF86AudioPrev, exec, playerctl previous

# Autostart
exec-once = waybar
exec-once = hyprpaper
exec-once = swaync
exec-once = /usr/lib/polkit-kde-authentication-agent-1

# Window rules
windowrule = float, ^(pavucontrol)$
windowrule = float, ^(nwg-look)$

# Appearance
general {
    gaps_in = 5
    gaps_out = 20
    border_size = 2
    col.active_border = rgba(33ccffee) rgba(00ff99ee) 45deg
    col.inactive_border = rgba(595959aa)
    resize_on_border = false
    allow_tearing = false
    layout = dwindle
}

decoration {
    rounding = 10
    active_opacity = 1.0
    inactive_opacity = 1.0
    drop_shadow = true
    shadow_range = 4
    shadow_render_power = 3
    col.shadow = rgba(1a1a1aee)
    blur {
        enabled = true
        size = 3
        passes = 1
        vibrancy = 0.1696
    }
}

animations {
    enabled = true
    bezier = myBezier, 0.05, 0.9, 0.1, 1.05
    animation = windows, 1, 7, myBezier
    animation = windowsOut, 1, 7, default, popin 80%
    animation = border, 1, 10, default
    animation = borderangle, 1, 8, default
    animation = fade, 1, 7, default
    animation = workspaces, 1, 6, default
}

dwindle {
    pseudotile = true
    preserve_split = true
}

master {
    new_is_master = true
}

misc { 
    force_default_wallpaper = -1
    disable_hyprland_logo = false
}
HYPREOF

chown -R $USERNAME:$USERNAME /home/$USERNAME/.config/hypr

# Create basic waybar config
mkdir -p /home/$USERNAME/.config/waybar
cat > /home/$USERNAME/.config/waybar/config << 'WAYBAREOF'
{
    "layer": "top",
    "height": 30,
    "spacing": 4,
    "modules-left": ["hyprland/workspaces", "hyprland/window"],
    "modules-center": ["clock"],
    "modules-right": ["pulseaudio", "network", "battery", "tray"],
    "hyprland/workspaces": {
        "disable-scroll": true,
        "all-outputs": true,
        "format": "{icon}",
        "format-icons": {
            "1": "1",
            "2": "2",
            "3": "3",
            "4": "4",
            "5": "5",
            "6": "6",
            "7": "7",
            "8": "8",
            "9": "9",
            "10": "10"
        }
    },
    "clock": {
        "format": "{:%Y-%m-%d %H:%M:%S}",
        "interval": 1
    },
    "pulseaudio": {
        "format": "{volume}% {icon}",
        "format-bluetooth": "{volume}% {icon}",
        "format-muted": "婢",
        "format-icons": {
            "headphone": "",
            "hands-free": "",
            "headset": "",
            "phone": "",
            "portable": "",
            "car": "",
            "default": ["", "", ""]
        },
        "on-click": "pavucontrol"
    },
    "network": {
        "format-wifi": "{essid} ({signalStrength}%) ",
        "format-ethernet": "{ifname} ",
        "format-disconnected": "Disconnected ⚠"
    }
}
WAYBAREOF

chown -R $USERNAME:$USERNAME /home/$USERNAME/.config/waybar

# Enable services
systemctl enable pipewire
systemctl enable wireplumber

echo "Extended setup completed!"
EOF

    # Pass username to script
    sed -i "s|\$USERNAME|$USERNAME|g" /mnt/setup_extended.sh
    
    # Make script executable and run in chroot
    chmod +x /mnt/setup_extended.sh
    arch-chroot /mnt /setup_extended.sh
    rm /mnt/setup_extended.sh
    
    print_success "Extended system setup completed"
}

# Main installation function
main() {
    clear
    echo "========================================="
    echo "    Arch Linux Installation Script"
    echo "         with Hyprland Setup"
    echo "========================================="
    echo
    
    check_root
    check_internet
    update_clock
    
    # Get user input
    list_disks
    echo
    prompt_input "Enter the disk to install to (e.g., /dev/sda, /dev/nvme0n1)" DISK
    prompt_input "Enter timezone" TIMEZONE "Europe/Berlin"
    prompt_input "Enter locale" LOCALE "en_US"
    prompt_input "Enter keyboard layout" KEYMAP "de-latin1"
    prompt_input "Enter hostname" HOSTNAME "archlinux"
    prompt_input "Enter username" USERNAME "user"
    prompt_password "Enter root password" ROOT_PASSWORD
    prompt_password "Enter user password" USER_PASSWORD
    
    echo
    read -p "Do you want to install the extended system (Hyprland, AUR packages, etc.)? (yes/no): " INSTALL_EXTENDED
    
    echo
    print_status "Starting installation with the following settings:"
    echo "Disk: $DISK"
    echo "Timezone: $TIMEZONE"
    echo "Locale: $LOCALE"
    echo "Keymap: $KEYMAP"
    echo "Hostname: $HOSTNAME"
    echo "Username: $USERNAME"
    echo "Extended setup: $INSTALL_EXTENDED"
    echo
    
    read -p "Continue with installation? (yes/no): " confirm
    if [ "$confirm" != "yes" ]; then
        print_error "Installation aborted"
        exit 1
    fi
    
    # Perform installation
    partition_disk "$DISK"
    format_partitions
    mount_partitions
    install_base_system
    generate_fstab
    configure_system
    
    # Install extended system if requested
    if [ "$INSTALL_EXTENDED" = "yes" ]; then
        setup_extended_system
    fi
    
    echo
    print_success "========================================="
    print_success "    Installation completed successfully!"
    print_success "========================================="
    echo
    print_status "You can now reboot into your new Arch Linux system."
    if [ "$INSTALL_EXTENDED" = "yes" ]; then
        print_status "Hyprland is installed. Start it with 'Hyprland' after login."
        print_status "Configure powerlevel10k with 'p10k configure'"
    fi
    print_status "Don't forget to remove the installation media."
    echo
    read -p "Reboot now? (yes/no): " reboot_confirm
    if [ "$reboot_confirm" = "yes" ]; then
        umount -R /mnt
        reboot
    fi
}

# Run main function
main "$@"
