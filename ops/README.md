# Ops — release.burrowee.com

Operator activation notes for the public install channel. **Every step below is
OPERATOR-ACTIVATION** — none runs as part of CI or the release script; do them
once by hand on the host, then `tools/release.sh` keeps the static surface in
sync on each release.

Host: `nsm.renative.com` (the same box that fronts the console / umbree /
burree). Static surface: `/ebs_storage/apps/release.burrowee.com/static`
(matches `STATIC_DIR` in `tools/release.sh`). Edge: Cloudflare, **Full
(strict)** mode.

The nginx vhost is `ops/nginx/release.burrowee.com.conf`.

---

## 1. DNS — OPERATOR

Create an **A record** for `release.burrowee.com` → the nsm origin IP, and set it
**Cloudflare-proxied** (orange cloud). Full (strict) means CF validates the
origin cert, so a real cert must be in place on the origin (step 3) before the
SSL mode will succeed.

## 2. Install the vhost — OPERATOR

> **nsm-specific:** this host's `/etc/nginx/nginx.conf` includes only
> `/etc/nginx/sites-enabled/*` — it does **NOT** include
> `/etc/nginx/conf.d/*.conf`. A file dropped under `conf.d/` is silently dead
> (nginx -t passes, reload succeeds, directives never run). It **must** go into
> `sites-enabled/`.

```sh
# OPERATOR, on nsm:
sudo cp ops/nginx/release.burrowee.com.conf \
        /etc/nginx/sites-enabled/release.burrowee.com.conf
sudo mkdir -p /ebs_storage/apps/release.burrowee.com/static
```

Do **not** add `default_server` to this vhost — another sites-enabled file
already owns `default_server` on `:443`; a duplicate fails `nginx -t`.

## 3. Issue the origin cert — OPERATOR

Issue a cert for `release.burrowee.com` (mirror whatever the console vhost on
this host uses — e.g. certbot / the host's existing LE setup), then point the
`ssl_certificate` / `ssl_certificate_key` placeholders in the vhost at the real
paths.

> **nsm-specific:** this host's nginx build **rejects `TLSv1.3`** — the vhost
> pins `ssl_protocols TLSv1.2;`. Leave it; raising it to TLSv1.3 fails
> `nginx -t` and aborts the reload.

## 4. Validate + reload — OPERATOR

```sh
# OPERATOR, on nsm:
sudo nginx -t && sudo systemctl reload nginx
```

## 5. First publish — OPERATOR

Run the release orchestrator from a workstation; it builds, signs, creates the
GitHub releases, and `scp`s the static surface (`index.html`,
`burrowee-release.pub`, `<comp>/install.sh`, `skills/<name>/SKILL.md`) into
`STATIC_DIR`. See `tools/release.sh` for required env (`RELEASE_HOST`,
`STATIC_DIR`, signing key).

## 6. Smoke test

```sh
curl -fsSI https://release.burrowee.com/                                  # 200, text/html
curl -fsSI https://release.burrowee.com/cli/install.sh                    # 200, text/x-shellscript
curl -fsSI https://release.burrowee.com/burrowee-release.pub             # 200, text/plain
curl -fsSI https://release.burrowee.com/skills/burrowee-cli-install/SKILL.md  # 200, text/markdown
```

A green install path end-to-end:

```sh
curl -fsSL --proto '=https' --tlsv1.2 https://release.burrowee.com/cli/install.sh | sh
```
