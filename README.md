# luna_moje
modifikovany kod od oo7hacky007

# Luna Installers (TL;DR)

Pick one of the one-liners below depending on where you want Luna to run:

- **Docker Compose on any Linux/macOS host**

  ```shell
  bash -c "$(curl -fsSL https://raw.githubusercontent.com/ritniotvor/luna_moje/main/luna-docker-compose.sh)"
  ```

  - This generates a local Compose project, detects your CPU arch, downloads the matching Luna binary, and runs `docker compose up -d --build` for you

  – Exposes ports `7127` and `7126` on all interfaces

- **Proxmox LXC container installation:**

  ```shell
  bash -c "$(curl -fsSL https://raw.githubusercontent.com/ritniotvor/luna_moje/main/luna-proxmox-installer.sh)"
  ```

  – provisions an unprivileged Debian 12 CT with a systemd service

## Webshare Credentials

Both installers ask for your Webshare.cz username/password (or read `WS_USERNAME` / `WS_PASSWORD`).
WS credentials are used to download Luna binary from Webshare. I do **not** distribute the Luna binary; the scripts authenticate against Webshare and download the official artifact that matches your architecture. Without valid credentials the Webshare API will refuse the download.

## Disclaimer

Use at your own risk. I am not the author of the Luna binary and cannot vouch for its behavior or legality. These scripts are thin wrappers/bootstrappers that automate the download and runtime setup; you are fully responsible for how you use them.
