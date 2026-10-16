# otobo-podman (proof of concept)

Run OTOBO on Red Hat Enterprise Linux 9/10 with the tools shipped by the
distribution only: rootless Podman, Quadlet and systemd.

Configuration works like in otobo-docker: one `.env` file with the same
variable names. `scripts/install.sh` generates the Quadlet units from it.

```
.podman_env_https   sample .env for HTTPS via nginx (copy to .env)
.podman_env_http    sample .env for plain HTTP without nginx
quadlet/            unit templates (.container, .network, .volume), one per Compose service
systemd/            otobo.target grouping all services
scripts/            prepare-host.sh (root), install.sh (service user),
                    export-images.sh (optional: image archive for air-gapped hosts)
sysctl/             kernel settings (vm.max_map_count, optional low ports)
doc/                installation-podman.rst
```

Quick start:

```
sudo scripts/prepare-host.sh
sudo machinectl shell otobo@
cd ~/otobo-podman
cp .podman_env_https .env && vi .env     # password, certificate names, proxy secret, images/registry
scripts/install.sh                       # pulls the images named in .env and installs the units
# air-gapped: scripts/install.sh --load otobo-images.tar
# import certificates (see doc), then:
systemctl --user start otobo.target
```

See `doc/installation-podman.rst` for details.

OTOBO is Copyright (C) 2019-2026 Rother OSS GmbH, https://otobo.io/ and
licensed under the GNU General Public License v3, see the OTOBO repository.
