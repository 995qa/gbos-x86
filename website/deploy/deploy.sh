#!/bin/sh
# Deploy the site to the VPS. Standard library only: nothing is pip-installed. Touches only /var/www/gbos86, the
# gbos86web user and the gbos86web* units; it does not touch other sites or services on the server.
#   HOST=user@server SSH_KEY=~/.ssh/key website/deploy/deploy.sh
set -e
HOST=${HOST:?set HOST=user@your-server}
KEY=${SSH_KEY:?set SSH_KEY=/path/to/ssh-private-key}
D=$(cd "$(dirname "$0")/.." && pwd)
SSH="ssh -i $KEY"
$SSH $HOST 'id gbos86web >/dev/null 2>&1 || sudo useradd --system --home-dir /var/www/gbos86 --shell /usr/sbin/nologin gbos86web
  sudo mkdir -p /var/www/gbos86/data && sudo chown gbos86web:gbos86web /var/www/gbos86/data && sudo chmod 750 /var/www/gbos86/data; mkdir -p ~/gbos86-stage'
rsync -a --delete -e "$SSH" --exclude data --exclude __pycache__ --exclude '*.pyc' --exclude deploy "$D/" $HOST:gbos86-stage/
scp -i "$KEY" -q "$D"/deploy/gbos86web.service "$D"/deploy/gbos86web-backup.service "$D"/deploy/gbos86web-backup.timer $HOST:gbos86-stage-units/ 2>/dev/null || {
  $SSH $HOST 'mkdir -p ~/gbos86-stage-units'; scp -i "$KEY" -q "$D"/deploy/gbos86web.service "$D"/deploy/gbos86web-backup.service "$D"/deploy/gbos86web-backup.timer $HOST:gbos86-stage-units/; }
$SSH $HOST 'sudo rsync -rlt --delete --exclude=data --chown=root:root --chmod=D755,F644 ~/gbos86-stage/ /var/www/gbos86/
  sudo cp ~/gbos86-stage-units/* /etc/systemd/system/ && sudo systemctl daemon-reload
  sudo systemctl enable --now gbos86web.service gbos86web-backup.timer >/dev/null 2>&1; sudo systemctl restart gbos86web.service; sleep 2
  echo "service: $(systemctl is-active gbos86web)"; curl -s -o /dev/null -w "local http %{http_code}\n" http://127.0.0.1:8083/'
