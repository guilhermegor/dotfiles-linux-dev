#!/bin/bash
#
# ventoy-plugson.sh -- lives on the Ventoy data partition (copied there by
# `ventoy-plugson --install-launcher`). Opens Plugson for THIS stick: finds the
# block device it is mounted from, then hands it to the host's ventoy-plugson.

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

if ! command -v ventoy-plugson >/dev/null 2>&1; then
    echo "ventoy-plugson is not installed on this machine. Install it with:"
    echo "  git clone https://github.com/guilhermegor/dotfiles-linux-dev && cd dotfiles-linux-dev && make install_programs"
    exit 1
fi

disk=$(lsblk -no PKNAME "$(findmnt -no SOURCE --target "$here")") || exit 1
[ -n "$disk" ] || { echo "Could not resolve the disk behind $here." >&2; exit 1; }
exec ventoy-plugson "/dev/$disk"
