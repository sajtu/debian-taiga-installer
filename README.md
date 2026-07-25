# debian-taiga-installer
# Taiga installer for Debian
# by Sean Tu
# git clone https://github.com/sajtu/debian-taiga-installer
# Provided AS-IS.
# MIT License: See LICENSE file.

`debian-setup-taiga.bash` performs an interactive, single-Taiga deployment using
Taiga's official stable Docker Compose repository.

## Supported systems

- Debian 13 (Trixie)
- Debian 12 (Bookworm)
- Debian 11 (Bullseye)

Run it from an interactive terminal:

```bash
sudo ./debian-setup-taiga.bash
```

Before changing the system, the installer explains its actions and asks for
confirmation. It then:

- checks and installs required Debian packages;
- installs Docker Engine and the Compose plugin from Docker's official Debian
  repository when they are missing;
- creates a locked `taiga-svc` system account by default;
- gives that account Docker access and a Bash shell for
  `sudo su - taiga-svc`;
- prompts for `/opt/taiga` or a custom absolute installation path;
- clones Taiga's `stable` branch;
- prompts for the browser-facing Taiga URL;
- generates random application, PostgreSQL, and RabbitMQ secrets;
- adds `unless-stopped` restart policies without editing Taiga's upstream
  Compose file;
- validates the merged Compose configuration;
- installs and enables `taiga-compose.service`;
- pulls and starts the containers;
- applies all pending database migrations;
- optionally launches Taiga's administrator-creation command.

## Security notes

Membership in the local `docker` group is effectively root access. The service
account has a locked password, but administrators with sudo can enter it with:

```bash
sudo su - taiga-svc
```

The generated `.env` is mode `0600`. Back it up securely along with the Docker
volumes; it contains credentials needed for recovery.

For HTTPS deployments, configure a reverse proxy to forward HTTP and
WebSockets to port `9000` on the Taiga VM.

## Existing installations

The installer recognizes an existing directory only when it is a Git checkout
whose `origin` is Taiga's official Docker repository. It preserves an existing
`.env` and does not rotate its secrets. It refuses to overwrite any other
non-empty directory.

## Service management

```bash
sudo systemctl status taiga-compose.service
sudo systemctl restart taiga-compose.service

sudo su - taiga-svc
cd /opt/taiga
docker compose ps
docker compose logs --tail=100
```
