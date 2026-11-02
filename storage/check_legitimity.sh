#!/bin/bash

# shellcheck source=../lib/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"

# Check if script is run as root
if [ "$(id -u)" -ne 0 ]; then
    print_status "error" "This script must be run as root. Please use sudo."
    exit 1
fi

# Check if f3 is installed, if not install it
check_f3_installed() {
    if ! command -v f3write &> /dev/null || ! command -v f3read &> /dev/null; then
        print_status "warning" "f3 tools not found. Installing..."
        
        if command -v apt-get &> /dev/null; then
            apt-get update
            apt-get install -y f3
        elif command -v yum &> /dev/null; then
            yum install -y f3
        elif command -v dnf &> /dev/null; then
            dnf install -y f3
        elif command -v pacman &> /dev/null; then
            pacman -Sy --noconfirm f3
        else
            print_status "error" "Could not detect package manager to install f3. Please install it manually."
            exit 1
        fi
        
        # Verify installation
        if ! command -v f3write &> /dev/null || ! command -v f3read &> /dev/null; then
            print_status "error" "Failed to install f3 tools. Please install them manually."
            exit 1
        else
            print_status "success" "f3 tools installed successfully."
        fi
    else
        print_status "success" "f3 tools are already installed."
    fi
    if command -v f3-qt &> /dev/null; then
        print_status "info" "f3-qt (GUI front-end for f3) is also available."
    fi
}

# List available drives
list_drives() {
    print_status "info" "Available drives:"
    lsblk -d -o NAME,SIZE,MODEL | grep -v "NAME"
}

# Select drive
select_drive() {
    while true; do
        read -rp "$(echo -e ${CYAN}"Enter the drive to test (e.g. sdc): "${NC})" drive || {
            print_status "info" "No input (stdin closed); exiting."
            exit 0
        }

        # Check if drive exists
        if [ ! -e "/dev/$drive" ]; then
            print_status "error" "Drive /dev/$drive does not exist."
            continue
        fi
        
        # Check if drive is mounted
        if mount | grep -q "/dev/$drive"; then
            print_status "warning" "Drive /dev/$drive is mounted. Attempting to unmount..."
            
            # Try to unmount all partitions
            for partition in /dev/"${drive}"[0-9]*; do
                [ -e "$partition" ] || continue  # glob matched nothing
                umount "$partition" 2>/dev/null
            done
            
            # Check if still mounted
            if mount | grep -q "/dev/$drive"; then
                print_status "error" "Could not unmount /dev/$drive. Please unmount manually and try again."
                exit 1
            else
                print_status "success" "Successfully unmounted /dev/$drive."
            fi
        fi
        
        # Confirm selection
        drive_size=$(lsblk -d -n -o SIZE "/dev/$drive")
        read -rp "$(echo -e ${CYAN}"You selected /dev/$drive (${drive_size}). Is this correct? [y/N]: "${NC})" confirm || {
            print_status "info" "No input (stdin closed); exiting."
            exit 0
        }

        if [[ "$confirm" =~ ^[Yy]$ ]]; then
            break
        fi
    done
}

# Run f3 tests
run_f3_tests() {
    local drive="$1"
    
    print_status "info" "Starting f3write on /dev/$drive..."
    f3write "/dev/$drive" | tee f3write.log
    
    if [ ${PIPESTATUS[0]} -ne 0 ]; then
        print_status "error" "f3write failed on /dev/$drive."
        exit 1
    fi
    
    print_status "info" "Starting f3read on /dev/$drive..."
    f3read "/dev/$drive" | tee f3read.log
    
    if [ ${PIPESTATUS[0]} -ne 0 ]; then
        print_status "error" "f3read failed on /dev/$drive."
        exit 1
    fi
    
    # Analyze results
    if grep -q "Good" f3read.log && ! grep -q "Bad" f3read.log; then
        print_status "success" "Pendrive legitimacy check PASSED. The drive appears to be genuine."
    else
        print_status "error" "Pendrive legitimacy check FAILED. The drive may be counterfeit or damaged."
        print_status "warning" "Bad sectors were detected. Actual capacity may be less than advertised."
    fi
}

# Main function
main() {
    echo -e "${MAGENTA}\n=== Pendrive Legitimacy Checker ===${NC}\n"
    
    check_f3_installed
    list_drives
    select_drive
    run_f3_tests "$drive"
    
    print_status "info" "Cleaning up..."
    rm -f f3write.log f3read.log
    
    print_status "success" "Test completed."
}

main