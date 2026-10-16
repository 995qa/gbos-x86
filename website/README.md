# gbos86.com

Community site and forum for gbOS86. Python 3 standard library only (no pip, no build step), SQLite storage.

| Path | What |
|---|---|
| `app.py` | HTTP server, routes, auth (scrypt, sessions, CSRF), rate limits, forum, contact messages, admin |
| `pages.py` | All HTML (home, install guide, hardware, download, FAQ, about, forum views). User text is always escaped |
| `static/` | CSS, JS, logo (`logo.png` from the project logo), favicons, social card |
| `deploy/` | `deploy.sh`, systemd units (service + daily DB backup timer) |

## What is stored (on the VPS, `/var/www/gbos86/data/`)
`site.db` (SQLite): members (scrypt password hash, optional email), sessions, forum categories/threads/posts, **contact-form
messages**. `secret.key` (CSRF secret), `backups/` (daily snapshots, newest 14). The directory is owned by `gbos86web`, mode 750.

## Run locally
    GBOS_DATA=/tmp/gb GBOS_BIND=127.0.0.1:8083 python3 website/app.py

## Deploy
    HOST=user@server SSH_KEY=~/.ssh/key website/deploy/deploy.sh      # rsync -> /var/www/gbos86, installs gbos86web.service + backup timer, restarts

The service listens on **127.0.0.1:8083** only and is published through a Cloudflare tunnel (any reverse proxy works the same way).
Add to the tunnel's `ingress:` (before the final `http_status:404` rule) and restart `cloudflared`, then add DNS records for
`gbos86.com` and `www` that point at the tunnel
(`cloudflared tunnel route dns <tunnel> gbos86.com`, or CNAME `<tunnel-id>.cfargotunnel.com` in the Cloudflare dashboard):

    - hostname: gbos86.com
      service: http://127.0.0.1:8083
    - hostname: www.gbos86.com
      service: http://127.0.0.1:8083

TLS is terminated by Cloudflare; the app sets `Secure` cookies when it sees `X-Forwarded-Proto: https`/`CF-Visitor`.

## Admin
Register an account on the site, then on the VPS:

    sudo -u gbos86web env GBOS_DATA=/var/www/gbos86/data python3 /var/www/gbos86/app.py promote YOURNAME

Admins can start threads in Announcements, pin/lock/delete threads, delete posts, and read contact messages at `/admin`.
`app.py stats` prints counts; `app.py backup` snapshots the DB.

## Security notes
scrypt password hashing; HttpOnly + SameSite=Lax session cookies (token stored hashed); CSRF token on every POST; per-IP and
per-user rate limits (login, register, posting, contact, search); honeypot field; strict CSP (no inline script/style); all output
escaped, only `http(s)` links auto-linked; request body capped at 64 KB. The systemd unit runs as an unprivileged user with
`ProtectSystem=strict` and a 200 MB memory cap (the VPS has ~1 GB).

## Not hosted here
The image contains Google's OS and patched Google libraries, so the site documents how to build it and never serves it.
