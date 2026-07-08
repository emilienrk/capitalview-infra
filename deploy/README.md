# Pull-based deployment (home machine)

The machine is not reachable from GitHub, so it pulls updates itself. A systemd
timer runs `deploy.sh` every 5 min:

```
git pull infra -> sops decrypt -> docker compose pull -> up -d --remove-orphans -> prune
```

Single source of truth: **this repo** (`capitalview-infra`). The `api` / `web`
images are built and pushed to ghcr.io by their own workflows; the machine picks
them up on the next tick.

## Requirements

- Docker + Docker Compose (`docker compose` plugin).
- The user running the service must be in the `docker` group.

> No native `sops`/`age` install needed: the script decrypts via the
> `ghcr.io/getsops/sops` Docker image (same as CI), and SOPS handles age decryption
> itself — you only need the age **private key** on disk.

## Bootstrap (once)

1. **Clone the repo** where the service expects it:
   ```bash
   sudo mkdir -p /opt/capitalview && sudo chown "$USER" /opt/capitalview
   git clone https://github.com/emilienrk/capitalview-infra.git /opt/capitalview/capitalview-infra
   ```

2. **Drop the age private key** (decrypts `.env.prod.enc`). This is the **only local
   secret**, never committed:
   ```bash
   mkdir -p ~/.config/sops/age
   # paste your age private key here (AGE-SECRET-KEY-...)
   vi ~/.config/sops/age/keys.txt
   chmod 600 ~/.config/sops/age/keys.txt
   ```

3. **Adjust the units** if needed (`capitalview-deploy.service`) — the 3 lines
   marked "ADAPT": `User`, `WorkingDirectory` / `ExecStart`, `SOPS_AGE_KEY_FILE`.

4. **Install and enable** the timer:
   ```bash
   sudo cp /opt/capitalview/capitalview-infra/deploy/capitalview-deploy.{service,timer} /etc/systemd/system/
   sudo systemctl daemon-reload
   sudo systemctl enable --now capitalview-deploy.timer
   ```

5. **Trigger a first deployment** without waiting for the tick:
   ```bash
   sudo systemctl start capitalview-deploy.service
   ```

## Observability

```bash
systemctl status capitalview-deploy.timer     # timer state
systemctl list-timers capitalview-deploy      # next trigger
journalctl -u capitalview-deploy -f           # deployment logs
```

## Manual rollback

Images are also tagged `:<sha>` on ghcr.io. To roll back, pin the wanted tag in
`docker-compose.prod.yaml`, commit/push, or edit locally then
`docker compose -f docker-compose.prod.yaml up -d`.
