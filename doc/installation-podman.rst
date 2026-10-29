.. --
.. OTOBO is a web-based ticketing system for service organisations.
.. --
.. Copyright (C) 2019-2026 Rother OSS GmbH, https://otobo.io/
.. --
.. This program is free software: you can redistribute it and/or modify it under
.. the terms of the GNU General Public License as published by the Free Software
.. Foundation, either version 3 of the License, or (at your option) any later version.
.. This program is distributed in the hope that it will be useful, but WITHOUT
.. ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS
.. FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.
.. You should have received a copy of the GNU General Public License
.. along with this program. If not, see <https://www.gnu.org/licenses/>.
.. --

Installing on RHEL with Podman (Quadlet)
=========================================

.. note::

   Proof of concept. This setup mirrors ``docker-compose/otobo-base.yml``
   together with the HTTP, HTTPS and Redis extensions of ``otobo-docker``.
   It uses only components shipped with Red Hat Enterprise Linux 9 and 10:
   Podman, Quadlet and systemd. No Docker, no Compose tool and no
   third-party repository is required.

Overview
--------

The configuration lives in one file ``.env``, exactly as in ``otobo-docker``
and with the same variable names. ``scripts/install.sh`` reads it and
generates one *Quadlet unit* per service. A Quadlet unit is a small systemd
unit file that Podman turns into a regular service on ``daemon-reload``:

================  =============================  ==============================
Compose service   Quadlet unit                   systemd service
================  =============================  ==============================
db                ``otobo-db.container``         ``otobo-db.service``
elastic           ``otobo-elastic.container``    ``otobo-elastic.service``
redis             ``otobo-redis.container``      ``otobo-redis.service``
web               ``otobo-web.container``        ``otobo-web.service``
daemon            ``otobo-daemon.container``     ``otobo-daemon.service``
nginx             ``otobo-nginx.container``      ``otobo-nginx.service``
(network)         ``otobo.network``              ``otobo-network.service``
volumes           ``otobo-*.volume``             ``otobo-*-volume.service``
================  =============================  ==============================

All services are grouped by ``otobo.target``. The containers run *rootless*
under a dedicated, unprivileged service user. They talk to each other over
the internal network ``otobo``, where Podman's DNS resolves the same host
names as in the Compose setup (``db``, ``elastic``, ``redis``, ``web``).
Only the nginx ports (or, without nginx, the web server port) are published
on the host.

Differences to the Docker Compose setup
---------------------------------------

* ``COMPOSE_FILE`` is replaced by ``OTOBO_SERVICES`` in ``.env``, a list of
  the services to install. ``db elastic web daemon`` are mandatory,
  ``nginx`` (HTTPS) and ``redis`` are optional.
* Image names must be fully qualified, e.g.
  ``docker.io/rotheross/otobo:rel-11_1_0-beta3``. A local registry is
  configured by using its address in the image name.
* ``depends_on`` is replaced by systemd dependencies. Thanks to
  ``Notify=healthy`` the web server starts only after the database and
  Elasticsearch report a passing health check.
* ``restart: always`` and start at boot are handled by systemd. Lingering
  must be enabled for the service user.
* Per container only the variables it needs are passed. ``install.sh``
  generates these files under ``~/.config/otobo/`` from ``.env``.
* Logs go to the journal: ``journalctl --user -u otobo-web``.
* ``docker compose exec web ...`` becomes ``podman exec otobo-web ...``.
* The update script of ``otobo-docker`` is not ported yet.

Requirements
------------

* RHEL 9 or 10 with ``podman`` installed (``dnf install podman systemd-container``).
* SELinux may stay in enforcing mode. Named volumes are used throughout, so
  no relabeling is required.
* Memory: at least 4 GB; Elasticsearch takes 512 MB heap per default.
* Access to the images, see the next section.

Where the images come from
--------------------------

The image names are set in ``.env`` (``OTOBO_IMAGE_OTOBO``,
``OTOBO_IMAGE_DB`` and so on). ``install.sh`` pulls them before installing
the units.

1. **Docker Hub (default).** Nothing to configure. The host needs internet
   access; a proxy is honoured via the usual ``HTTPS_PROXY`` environment of
   the service user.

2. **Local registry.** Put the address of your registry into the image
   names, e.g.
   ``OTOBO_IMAGE_OTOBO=registry.example.com/rotheross/otobo:rel-11_1_0-beta3``.
   A registry with a self-signed certificate has to be declared as
   ``insecure`` in ``/etc/containers/registries.conf``, see
   ``man containers-registries.conf``.

3. **Image archive (optional, for air-gapped hosts).** On a host with
   internet access and the same ``.env`` run
   ``scripts/export-images.sh otobo-images.tar``. It pulls all images named
   in ``.env`` and writes one archive plus a SHA-256 checksum. Transfer both
   files to the target host and pass the archive to ``install.sh --load``.

Installation
------------

1. Prepare the host as root. This creates the system user ``otobo`` with the home directory ``/home/otobo`` ,
   enables lingering, installs the sysctl settings and copies the package to
   ``/home/otobo/otobo-podman``::

       sudo scripts/prepare-host.sh

2. Switch to the service user. ``machinectl shell`` is required because it
   starts a proper user session, which ``systemctl --user`` relies on::

       sudo machinectl shell otobo@
       cd ~/otobo-podman

3. Create ``.env`` from a sample file and edit it. At least
   ``OTOBO_DB_ROOT_PASSWORD`` must be set; with nginx also
   ``OTOBO_NGINX_SSL_CERTIFICATE``, ``OTOBO_NGINX_SSL_CERTIFICATE_KEY`` and
   ``OTOBO_PROXY_SECRET``::

       cp .podman_env_https .env      # or .podman_env_http
       vi .env

4. Pull the images and install the units::

       scripts/install.sh

   Air-gapped hosts load the archive instead of pulling::

       sha256sum -c otobo-images.tar.sha256
       scripts/install.sh --load otobo-images.tar

   Run ``install.sh`` again after every change of ``.env``.

5. With nginx: import the TLS certificate and key into the volume. The file
   names must match the ones in ``.env``::

       systemctl --user start otobo-nginx-ssl-volume.service
       tar -C /path/to/certs -cf /tmp/ssl.tar ssl-cert.crt ssl-key.key
       podman volume import otobo_nginx_ssl /tmp/ssl.tar

6. Start OTOBO and run the installer::

       systemctl --user start otobo.target
       systemctl --user status 'otobo*'

   Open ``https://<host>:8443/otobo/installer.pl`` (or the port set in
   ``.env``).

Ports 80 and 443
----------------

Rootless Podman can not bind ports below 1024 per default, therefore the
sample ``.env`` files use 8080 and 8443. Two options:

* Keep the high ports and put a reverse proxy of your organisation in front.
* Allow the service user to bind low ports: uncomment
  ``net.ipv4.ip_unprivileged_port_start = 80`` in
  ``/etc/sysctl.d/90-otobo.conf``, run ``sysctl --system``, set
  ``OTOBO_WEB_HTTPS_PORT=443`` and ``OTOBO_WEB_HTTP_PORT=80`` in ``.env``
  and run ``scripts/install.sh`` followed by
  ``systemctl --user restart otobo.target``.

Daily operation
---------------

All commands as user ``otobo``::

    systemctl --user status otobo.target        # overview
    systemctl --user restart otobo-web          # restart one service
    systemctl --user stop otobo.target          # stop everything
    journalctl --user -u otobo-daemon -f        # follow a log
    podman exec -it otobo-web bash              # shell in the web container
    podman exec -it otobo-db mariadb -p         # database client
    podman ps                                   # running containers

Backup
------

The volumes live in the storage of the service user
(``~/.local/share/containers/storage/volumes``). The portable way to back
them up is::

    systemctl --user stop otobo.target
    podman volume export otobo_mariadb_data > mariadb.tar
    podman volume export otobo_opt_otobo    > opt_otobo.tar
    systemctl --user start otobo.target

Restore with ``podman volume import``. Volumes exported from a Docker Compose
installation can be imported the same way, the volume names are identical.

Open points of the proof of concept
-----------------------------------

* Port ``scripts/update.sh`` (image update, ``copy_otobo_next``).
* Variants: Kerberos, custom nginx configuration, S3 storage.
* Image signatures and digests for environments that enforce
  ``policy.json``.
* Optional packaging as RPM.
