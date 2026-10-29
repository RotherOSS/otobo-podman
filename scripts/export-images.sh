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

# Build an image archive for air-gapped installations (optional).
# Run on a host WITH internet access, with the same .env as on the target host.
# Pulls all images named in .env and saves them into one tar archive, which is
# then transferred to the target host and loaded with scripts/install.sh --load.
#
# Usage: scripts/export-images.sh [output.tar]

set -euo pipefail

OUTPUT="${1:-otobo-images.tar}"
script_dir=$(dirname "$(realpath -- "${BASH_SOURCE[0]}")")
package_dir=$(dirname "$script_dir")

# Read .env line by line, same format and same reasoning as in scripts/install.sh.
if [[ -f $package_dir/.env ]]; then
    while IFS= read -r line || [[ -n $line ]]; do
        [[ $line =~ ^[[:space:]]*$ ]] && continue
        [[ $line =~ ^[[:space:]]*# ]] && continue
        key="${line%%=*}"
        value="${line#*=}"
        key="${key//[[:space:]]/}"
        [[ $key =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || continue
        export "$key=$value"
    done < "$package_dir/.env"
fi

# Same defaults as in scripts/install.sh
OTOBO_SERVICES="${OTOBO_SERVICES:-db elastic redis web daemon nginx}"
images=(
    "${OTOBO_IMAGE_DB:-docker.io/library/mariadb:lts-noble}"
    "${OTOBO_IMAGE_OTOBO:-docker.io/rotheross/otobo:rel-11_1_1}"
    "${OTOBO_IMAGE_OTOBO_ELASTICSEARCH:-docker.io/rotheross/otobo-elasticsearch:rel-11_1_1}"
)
[[ " $OTOBO_SERVICES " == *" redis "* ]] && images+=( "${OTOBO_IMAGE_REDIS:-docker.io/library/redis:8-bookworm}" )
[[ " $OTOBO_SERVICES " == *" nginx "* ]] && images+=( "${OTOBO_IMAGE_OTOBO_NGINX:-docker.io/rotheross/otobo-nginx-webproxy:rel-11_1_1}" )

echo "==> Pulling images"
for image in "${images[@]}"; do
    podman pull "$image"
done

echo "==> Saving to $OUTPUT"
podman save --multi-image-archive --output "$OUTPUT" "${images[@]}"

echo "==> Checksum"
sha256sum "$OUTPUT" | tee "$OUTPUT.sha256"

echo
echo "Transfer $OUTPUT and $OUTPUT.sha256 to the target host and run"
echo "    sha256sum -c $OUTPUT.sha256"
echo "    scripts/install.sh --load $OUTPUT"
