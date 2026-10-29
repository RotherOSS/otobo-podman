#!/bin/bash
# --
# OTOBO is a web-based ticketing system for service organisations.
# --
# Copyright (C) 2019-2026 Rother OSS GmbH, https://otobo.io/
# --
# This program is free software: you can redistribute it and/or modify it under
# the terms of the GNU General Public License as published by the Free Software
# Foundation, either version 3 of the License, or (at your option) any later version.
# This program is distributed in the hope that it will be useful, but WITHOUT
# ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS
# FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.
# You should have received a copy of the GNU General Public License
# along with this program. If not, see <https://www.gnu.org/licenses/>.
# --

# Prepare a RHEL host for running OTOBO with rootless Podman.
# Run once as root. Creates the service user, enables lingering, installs the
# sysctl settings and copies this package to the home directory of the user.
#
# Usage: sudo scripts/prepare-host.sh [service-user]

set -euo pipefail

SERVICE_USER="${1:-otobo}"
script_dir=$(dirname "$(realpath -- "${BASH_SOURCE[0]}")")
package_dir=$(dirname "$script_dir")

if [[ $EUID -ne 0 ]]; then
    echo "This script must be run as root." >&2
    exit 1
fi

echo "==> Checking for podman"
if ! command -v podman >/dev/null; then
    echo "podman is not installed. Install it with: dnf install podman" >&2
    exit 1
fi
podman --version

echo "==> Creating service user '$SERVICE_USER'"
if id "$SERVICE_USER" >/dev/null 2>&1; then
    echo "user already exists"
else
    # useradd on RHEL assigns subordinate UID/GID ranges automatically.
    useradd --system --create-home --shell /bin/bash "$SERVICE_USER"
fi

echo "==> Checking subordinate ID ranges (needed for rootless containers)"
if ! grep -q "^$SERVICE_USER:" /etc/subuid /etc/subgid; then
    # Fallback for hosts where useradd did not add the ranges.
    usermod --add-subuids 200000-265535 --add-subgids 200000-265535 "$SERVICE_USER"
fi
grep "^$SERVICE_USER:" /etc/subuid /etc/subgid

echo "==> Enabling lingering so that the services start at boot without a login"
loginctl enable-linger "$SERVICE_USER"

echo "==> Installing sysctl settings"
install -m 0644 "$package_dir/sysctl/90-otobo.conf" /etc/sysctl.d/90-otobo.conf
sysctl --system >/dev/null
sysctl vm.max_map_count

echo "==> Copying the package to the home directory of '$SERVICE_USER'"
home_dir=$(getent passwd "$SERVICE_USER" | cut -d: -f6)
target_dir="$home_dir/otobo-podman"
mkdir -p "$target_dir"
# Copy everything including the hidden sample files, but keep an existing .env.
cp -r "$package_dir"/{quadlet,systemd,scripts,sysctl,doc,README.md} "$target_dir/"
cp "$package_dir"/.podman_env_* "$target_dir/"
chown -R "$SERVICE_USER:$SERVICE_USER" "$target_dir"
chmod +x "$target_dir"/scripts/*.sh

cat <<MSG

Host preparation finished.

For the next steps switch to the service user $SERVICE_USER.

    sudo machinectl shell $SERVICE_USER@

Next steps, as user '$SERVICE_USER':
    cd ~/otobo-podman
    cp .podman_env_https .env      # or .podman_env_http
    vi .env                        # at least OTOBO_DB_ROOT_PASSWORD, certificate names, OTOBO_PROXY_SECRET
    scripts/install.sh             # pulls the images and installs the units
    scripts/install.sh --load otobo-images.tar     # air-gapped: load the images from an archive instead

The sysctl option net.ipv4.ip_unprivileged_port_start=80 is commented out in
/etc/sysctl.d/90-otobo.conf. Enable it when nginx should listen on 80/443.
MSG
