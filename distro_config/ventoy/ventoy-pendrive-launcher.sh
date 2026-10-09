#!/bin/bash
#
# ventoy-plugson.sh -- lives on the Ventoy data partition (copied there by
# `ventoy-plugson --install-launcher`). Opens Plugson for THIS stick: finds the
# block device it is mounted from, then hands it to the host's ventoy-plugson.

# Convenience for your own sticks: this file sits on a FAT partition that anyone
# holding the stick can edit, so whoever modifies it can run code as the user.
# It therefore calls the host wrapper by absolute path only (never via $PATH);
# the wrapper itself refuses non-root-owned Ventoy scripts before using sudo.
VENTOY_PLUGSON=/usr/local/bin/ventoy-plugson

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

if [ ! -x "$VENTOY_PLUGSON" ]; then
    echo "ventoy-plugson is not installed on this machine. Install it with:"
    echo "  git clone https://github.com/guilhermegor/dotfiles-linux-dev && cd dotfiles-linux-dev && make install_programs"
    exit 1
fi

disk=$(lsblk -no PKNAME "$(findmnt -no SOURCE --target "$here")") || exit 1
[ -n "$disk" ] || { echo "Could not resolve the disk behind $here." >&2; exit 1; }
exec "$VENTOY_PLUGSON" "/dev/$disk"
