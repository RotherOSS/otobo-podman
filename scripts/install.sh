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

# Generate and install the OTOBO Quadlet units from .env.
# Run as the service user after scripts/prepare-host.sh has been executed as root.
# Run it again after every change of .env.
#
# Usage: scripts/install.sh [--load IMAGE-ARCHIVE] [--no-pull]
#
# Per default the images named in .env are pulled from their registry.
#
#   --load ARCHIVE   Air-gapped hosts: load the images from a tar archive
#                    created by scripts/export-images.sh instead of pulling.
#   --no-pull        Only install the units, do not pull or check images.
#                    Podman then pulls them on the first start.

set -euo pipefail

IMAGE_ARCHIVE=""
PULL=1
while [[ $# -gt 0 ]]; do
    case "$1" in
        --load)    IMAGE_ARCHIVE="$2"; shift 2 ;;
        --no-pull) PULL=0; shift ;;
        -h|--help) sed -n '17,28p' "${BASH_SOURCE[0]}"; exit 0 ;;
        *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
done

script_dir=$(dirname "$(realpath -- "${BASH_SOURCE[0]}")")
package_dir=$(dirname "$script_dir")

if [[ $EUID -eq 0 ]]; then
    echo "Do not run this script as root. Switch to the service user first:" >&2
    echo "    sudo machinectl shell otobo@" >&2
    exit 1
fi

# systemctl --user needs the runtime directory of the user. machinectl shell
# sets it, a plain 'su' does not.
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
if [[ ! -d $XDG_RUNTIME_DIR ]]; then
    echo "No user session found. Lingering must be enabled and the shell must be started with" >&2
    echo "    sudo machinectl shell $(id -un)@" >&2
    exit 1
fi

# Where the generated files go
quadlet_dir="$HOME/.config/containers/systemd"
systemd_dir="$HOME/.config/systemd/user"
env_dir="$HOME/.config/otobo"

################################################################################
# Read .env and apply the defaults
################################################################################

if [[ ! -f $package_dir/.env ]]; then
    echo "No .env found in $package_dir. Copy a sample file first, e.g.:" >&2
    echo "    cp $package_dir/.podman_env_https $package_dir/.env" >&2
    exit 1
fi

echo "==> Reading $package_dir/.env"

# .env has the same syntax as in otobo-docker: one KEY=VALUE per line, values
# are taken verbatim up to the end of the line (spaces allowed, no quoting
# needed), lines starting with '#' are comments. The file is not sourced by
# the shell, because unquoted values with spaces would break there.
read_env_file() {
    local line key value
    while IFS= read -r line || [[ -n $line ]]; do
        # skip blank lines and comments
        [[ $line =~ ^[[:space:]]*$ ]] && continue
        [[ $line =~ ^[[:space:]]*# ]] && continue
        # split at the first '='
        key="${line%%=*}"
        value="${line#*=}"
        key="${key//[[:space:]]/}"
        if [[ ! $key =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
            echo "Ignoring invalid line in .env: $line" >&2
            continue
        fi
        export "$key=$value"
    done < "$1"
}
read_env_file "$package_dir/.env"

# Defaults, identical to the ones in the compose files of otobo-docker,
# except that Podman needs fully qualified image names.
OTOBO_SERVICES="${OTOBO_SERVICES:-db elastic redis web daemon nginx}"
OTOBO_IMAGE_DB="${OTOBO_IMAGE_DB:-docker.io/library/mariadb:lts-noble}"
OTOBO_IMAGE_OTOBO="${OTOBO_IMAGE_OTOBO:-docker.io/rotheross/otobo:rel-11_1_0-beta3}"
OTOBO_IMAGE_OTOBO_ELASTICSEARCH="${OTOBO_IMAGE_OTOBO_ELASTICSEARCH:-docker.io/rotheross/otobo-elasticsearch:rel-11_1_0-beta3}"
OTOBO_IMAGE_OTOBO_NGINX="${OTOBO_IMAGE_OTOBO_NGINX:-docker.io/rotheross/otobo-nginx-webproxy:rel-11_1_0-beta3}"
OTOBO_IMAGE_REDIS="${OTOBO_IMAGE_REDIS:-docker.io/library/redis:8-bookworm}"
OTOBO_DB_QUERY_CACHE_SIZE="${OTOBO_DB_QUERY_CACHE_SIZE:-33554432}"
OTOBO_WEB_OPTION="${OTOBO_WEB_OPTION:-}"
OTOBO_WEB_HTTP_IPADDR="${OTOBO_WEB_HTTP_IPADDR:-0.0.0.0}"
OTOBO_WEB_HTTP_PORT="${OTOBO_WEB_HTTP_PORT:-8080}"
OTOBO_WEB_HTTPS_IPADDR="${OTOBO_WEB_HTTPS_IPADDR:-0.0.0.0}"
OTOBO_WEB_HTTPS_PORT="${OTOBO_WEB_HTTPS_PORT:-8443}"
OTOBO_ELASTICSEARCH_ES_JAVA_OPTS="${OTOBO_ELASTICSEARCH_ES_JAVA_OPTS:--Xms512m -Xmx512m}"
OTOBO_PROXY_SECRET="${OTOBO_PROXY_SECRET:-}"
NGINX_ENVSUBST_TEMPLATE_DIR="${NGINX_ENVSUBST_TEMPLATE_DIR:-}"
OTOBO_ENV_DIR="$env_dir"

# Mandatory settings, same checks as ':?err' in the compose files.
if [[ -z ${OTOBO_DB_ROOT_PASSWORD:-} ]]; then
    echo "OTOBO_DB_ROOT_PASSWORD must be set in .env" >&2
    exit 1
fi

# Helper: is a service listed in OTOBO_SERVICES?
has_service() {
    local service
    for service in $OTOBO_SERVICES; do
        [[ $service == "$1" ]] && return 0
    done
    return 1
}

for service in db elastic web daemon; do
    has_service "$service" || {
        echo "OTOBO_SERVICES must contain '$service'" >&2
        exit 1
    }
done

if has_service nginx; then
    if [[ -z ${OTOBO_NGINX_SSL_CERTIFICATE:-} || -z ${OTOBO_NGINX_SSL_CERTIFICATE_KEY:-} ]]; then
        echo "OTOBO_NGINX_SSL_CERTIFICATE and OTOBO_NGINX_SSL_CERTIFICATE_KEY must be set in .env" >&2
        exit 1
    fi
    # The web server port is not published, nginx is the only entry point.
    OTOBO_WEB_PUBLISHPORT=""
else
    # No nginx: publish the OTOBO web server directly via HTTP.
    OTOBO_WEB_PUBLISHPORT="PublishPort=${OTOBO_WEB_HTTP_IPADDR}:${OTOBO_WEB_HTTP_PORT}:5000"
fi

if has_service redis; then
    OTOBO_WEB_REDIS_DEPENDENCY="otobo-redis.service"
else
    OTOBO_WEB_REDIS_DEPENDENCY=""
fi

# The list of placeholders that may occur in the templates.
placeholders=(
    OTOBO_ENV_DIR
    OTOBO_IMAGE_DB OTOBO_IMAGE_OTOBO OTOBO_IMAGE_OTOBO_ELASTICSEARCH OTOBO_IMAGE_OTOBO_NGINX OTOBO_IMAGE_REDIS
    OTOBO_DB_QUERY_CACHE_SIZE OTOBO_WEB_OPTION
    OTOBO_WEB_HTTP_IPADDR OTOBO_WEB_HTTP_PORT OTOBO_WEB_HTTPS_IPADDR OTOBO_WEB_HTTPS_PORT
    OTOBO_WEB_PUBLISHPORT OTOBO_WEB_REDIS_DEPENDENCY
)

# Replace every ${NAME} in a template file with the value of the variable NAME
# and write the result to the target file.
render_template() {
    local template=$1
    local target=$2
    local content name value

    content=$(<"$template")
    for name in "${placeholders[@]}"; do
        value="${!name}"
        content="${content//\$\{$name\}/$value}"
    done

    # A placeholder that is still there points to a bug in the templates.
    if [[ $content =~ \$\{[A-Z_]+\} ]]; then
        echo "Unresolved placeholder ${BASH_REMATCH[0]} in $template" >&2
        exit 1
    fi

    printf '%s\n' "$content" > "$target"
}

################################################################################
# Images
################################################################################

images=( "$OTOBO_IMAGE_DB" "$OTOBO_IMAGE_OTOBO" "$OTOBO_IMAGE_OTOBO_ELASTICSEARCH" )
has_service redis && images+=( "$OTOBO_IMAGE_REDIS" )
has_service nginx && images+=( "$OTOBO_IMAGE_OTOBO_NGINX" )

echo "==> Checking Podman"
podman --version
podman info --format '{{.Host.Security.Rootless}}' | grep -q true || {
    echo "Podman is not running rootless for this user." >&2
    exit 1
}

if [[ -n $IMAGE_ARCHIVE ]]; then
    echo "==> Loading images from $IMAGE_ARCHIVE"
    podman load --input "$IMAGE_ARCHIVE"
elif [[ $PULL -eq 1 ]]; then
    echo "==> Pulling images"
    for image in "${images[@]}"; do
        podman pull "$image"
    done
fi

if [[ $PULL -eq 1 ]]; then
    echo "==> Checking that all required images are present"
    missing=0
    for image in "${images[@]}"; do
        if podman image exists "$image"; then
            echo "ok      $image"
        else
            echo "MISSING $image"
            missing=1
        fi
    done
    if [[ $missing -eq 1 ]]; then
        echo "Not all images are available. Check the registry access or use --load ARCHIVE." >&2
        exit 1
    fi
fi

################################################################################
# Environment files of the containers
################################################################################

echo "==> Writing container environment files to $env_dir"
mkdir -p "$env_dir"
chmod 700 "$env_dir"

# Each container gets only the variables it needs. The files are generated
# from .env on every run, so .env stays the single place for configuration.
cat > "$env_dir/db.env" <<EOF
MYSQL_ROOT_PASSWORD=$OTOBO_DB_ROOT_PASSWORD
MARIADB_AUTO_UPGRADE=1
EOF

cat > "$env_dir/elastic.env" <<EOF
discovery.type=single-node
xpack.security.enabled=false
ES_JAVA_OPTS=$OTOBO_ELASTICSEARCH_ES_JAVA_OPTS
EOF

cat > "$env_dir/web.env" <<EOF
OTOBO_PROXY_SECRET=$OTOBO_PROXY_SECRET
EOF

if has_service nginx; then
    # nginx needs the external HTTPS port for the redirect, except for 443.
    https_port_for_redirect="$OTOBO_WEB_HTTPS_PORT"
    [[ $https_port_for_redirect == 443 ]] && https_port_for_redirect=""

    cat > "$env_dir/nginx.env" <<EOF
OTOBO_NGINX_WEB_HOST=web
OTOBO_NGINX_WEB_PORT=5000
OTOBO_NGINX_PROXY_SECRET=$OTOBO_PROXY_SECRET
OTOBO_WEB_HTTPS_PORT=$https_port_for_redirect
OTOBO_NGINX_SSL_CERTIFICATE=$OTOBO_NGINX_SSL_CERTIFICATE
OTOBO_NGINX_SSL_CERTIFICATE_KEY=$OTOBO_NGINX_SSL_CERTIFICATE_KEY
NGINX_ENVSUBST_TEMPLATE_DIR=$NGINX_ENVSUBST_TEMPLATE_DIR
EOF
fi
chmod 600 "$env_dir"/*.env

################################################################################
# Quadlet units
################################################################################

echo "==> Generating Quadlet units into $quadlet_dir"
mkdir -p "$quadlet_dir" "$systemd_dir"

# Remove units of a previous run, so that a service removed from
# OTOBO_SERVICES disappears as well.
rm -f "$quadlet_dir"/otobo*.container "$quadlet_dir"/otobo*.volume "$quadlet_dir"/otobo.network

# Network and volumes are needed in every setup.
for template in "$package_dir"/quadlet/*.network "$package_dir"/quadlet/*.volume; do
    render_template "$template" "$quadlet_dir/$(basename "$template")"
done

# The containers according to OTOBO_SERVICES.
for service in $OTOBO_SERVICES; do
    template="$package_dir/quadlet/otobo-$service.container"
    if [[ ! -f $template ]]; then
        echo "Unknown service '$service' in OTOBO_SERVICES, no template $template" >&2
        exit 1
    fi
    render_template "$template" "$quadlet_dir/otobo-$service.container"
    echo "generated otobo-$service.container"
done

install -m 0644 "$package_dir/systemd/otobo.target" "$systemd_dir/"

echo "==> Generating systemd units"
systemctl --user daemon-reload
# Quadlet generates the services on daemon-reload. List them as a sanity check.
systemctl --user list-unit-files 'otobo*' --no-legend

echo "==> Enabling otobo.target (start at boot)"
systemctl --user enable otobo.target

cat <<EOF

Installation finished.

EOF
if has_service nginx; then
    cat <<EOF
Before the first start import the TLS certificate and key into the volume otobo_nginx_ssl:
    systemctl --user start otobo-nginx-ssl-volume.service
    tar -C /path/to/certs -cf /tmp/ssl.tar $(basename "$OTOBO_NGINX_SSL_CERTIFICATE") $(basename "$OTOBO_NGINX_SSL_CERTIFICATE_KEY")
    podman volume import otobo_nginx_ssl /tmp/ssl.tar

Then start OTOBO:
    systemctl --user start otobo.target
    systemctl --user status 'otobo*'
and open https://<host>:$OTOBO_WEB_HTTPS_PORT/otobo/installer.pl
EOF
else
    cat <<EOF
Start OTOBO:
    systemctl --user start otobo.target
    systemctl --user status 'otobo*'
and open http://<host>:$OTOBO_WEB_HTTP_PORT/otobo/installer.pl
EOF
fi
cat <<EOF

Logs:   journalctl --user -u otobo-web -f
Stop:   systemctl --user stop otobo.target
EOF
