#!/usr/bin/env python3
"""gbos86.com: community site + forum. Standard library only (no pip installs on the server), SQLite storage.

    python3 app.py                 serve on GBOS_BIND (default 127.0.0.1:8083)
    python3 app.py promote NAME    make a user an admin
    python3 app.py stats           print counts
    python3 app.py backup          snapshot the database to data/backups/ (a systemd timer runs this daily)

Runs behind a Cloudflare tunnel (see deploy/). Data lives in GBOS_DATA (default ./data/site.db).
"""
import hashlib, hmac, html, http.server, json, os, re, secrets, socketserver, sqlite3, sys, threading, time
import urllib.parse
import urllib.request
from http import cookies

import pages

HERE = os.path.dirname(os.path.abspath(__file__))
DATA = os.environ.get('GBOS_DATA', os.path.join(HERE, 'data'))
DB_PATH = os.path.join(DATA, 'site.db')
BIND = os.environ.get('GBOS_BIND', '127.0.0.1:8083')
BASE = os.environ.get('GBOS_BASE', 'https://gbos86.com')
MAX_BODY = 64 * 1024
SESSION_DAYS = 30
STATIC = os.path.join(HERE, 'static')
MIME = {'.css': 'text/css; charset=utf-8', '.js': 'text/javascript; charset=utf-8', '.png': 'image/png', '.jpg': 'image/jpeg', '.mp4': 'video/mp4', '.gif': 'image/gif', '.svg': 'image/svg+xml',
        '.ico': 'image/x-icon', '.txt': 'text/plain; charset=utf-8', '.xml': 'application/xml'}

CATEGORIES = [  # slug, title, description, staff_only
    ('announcements', 'Announcements', 'Releases, news and project status from the gbOS86 team.', 1),
    ('downloads', 'Downloads & Builds', 'Building the image, flashing the stick, checksums, updates.', 0),
    ('install', 'Install Guides', 'Step-by-step help installing or updating on the internal SSD.', 0),
    ('hardware', 'Hardware Compatibility', 'Post your laptop, what works, what does not, and your hwdetect.txt.', 0),
    ('support', 'Support & Troubleshooting', 'Boot problems, Wi-Fi, sound, touchpad, display. Attach your logs.', 0),
    ('dev', 'Development', 'Kernel, CPU emulation, patches, drivers, the Android-side workarounds.', 0),
    ('showcase', 'Showcase', 'Screenshots, benchmarks, your setup.', 0),
    ('general', 'General Chat', 'Everything else.', 0),
]

_local = threading.local()


def db():
    c = getattr(_local, 'c', None)
    if c is None:
        c = _local.c = sqlite3.connect(DB_PATH, timeout=10)
        c.row_factory = sqlite3.Row
        c.execute('PRAGMA foreign_keys=ON')
    return c


SCHEMA = '''
CREATE TABLE IF NOT EXISTS users(
  id INTEGER PRIMARY KEY, name TEXT NOT NULL UNIQUE COLLATE NOCASE, pw TEXT NOT NULL, email TEXT,
  created INTEGER NOT NULL, is_admin INTEGER NOT NULL DEFAULT 0, bio TEXT NOT NULL DEFAULT '',
  laptop TEXT NOT NULL DEFAULT '', banned INTEGER NOT NULL DEFAULT 0);
CREATE TABLE IF NOT EXISTS sessions(
  token TEXT PRIMARY KEY, user_id INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  csrf TEXT NOT NULL, expires INTEGER NOT NULL);
CREATE TABLE IF NOT EXISTS categories(
  id INTEGER PRIMARY KEY, slug TEXT UNIQUE NOT NULL, title TEXT NOT NULL, descr TEXT NOT NULL,
  staff_only INTEGER NOT NULL DEFAULT 0, pos INTEGER NOT NULL DEFAULT 0);
CREATE TABLE IF NOT EXISTS threads(
  id INTEGER PRIMARY KEY, cat_id INTEGER NOT NULL REFERENCES categories(id), user_id INTEGER NOT NULL REFERENCES users(id),
  title TEXT NOT NULL, created INTEGER NOT NULL, last_post INTEGER NOT NULL, replies INTEGER NOT NULL DEFAULT 0,
  views INTEGER NOT NULL DEFAULT 0, pinned INTEGER NOT NULL DEFAULT 0, locked INTEGER NOT NULL DEFAULT 0);
CREATE INDEX IF NOT EXISTS threads_cat ON threads(cat_id, pinned DESC, last_post DESC);
CREATE TABLE IF NOT EXISTS posts(
  id INTEGER PRIMARY KEY, thread_id INTEGER NOT NULL REFERENCES threads(id) ON DELETE CASCADE,
  user_id INTEGER NOT NULL REFERENCES users(id), body TEXT NOT NULL, created INTEGER NOT NULL, edited INTEGER);
CREATE INDEX IF NOT EXISTS posts_thread ON posts(thread_id, id);
CREATE TABLE IF NOT EXISTS messages(  -- contact form: stored for the admins
  id INTEGER PRIMARY KEY, name TEXT NOT NULL, email TEXT NOT NULL, subject TEXT NOT NULL, body TEXT NOT NULL,
  created INTEGER NOT NULL, ip TEXT NOT NULL, handled INTEGER NOT NULL DEFAULT 0);
'''


def init_db():
    os.makedirs(DATA, exist_ok=True)
    c = db()
    c.execute('PRAGMA journal_mode=WAL')
    c.executescript(SCHEMA)
    if 'ip' not in [r[1] for r in c.execute('PRAGMA table_info(users)')]:
        c.execute('ALTER TABLE users ADD COLUMN ip TEXT')
    c.execute('CREATE UNIQUE INDEX IF NOT EXISTS users_email ON users(lower(email)) WHERE email IS NOT NULL')
    c.execute('CREATE INDEX IF NOT EXISTS users_ip ON users(ip, created)')
    for i, (slug, title, descr, staff) in enumerate(CATEGORIES):
        c.execute('INSERT OR IGNORE INTO categories(slug,title,descr,staff_only,pos) VALUES(?,?,?,?,?)', (slug, title, descr, staff, i))
    if not c.execute("SELECT 1 FROM users WHERE name='gbOS86'").fetchone():
        c.execute("INSERT INTO users(name,pw,created,is_admin,bio) VALUES('gbOS86','!',?,1,'Project account.')", (int(time.time()),))
        uid = c.execute("SELECT id FROM users WHERE name='gbOS86'").fetchone()[0]
        cat = c.execute("SELECT id FROM categories WHERE slug='announcements'").fetchone()[0]
        now = int(time.time())
        c.execute('INSERT INTO threads(cat_id,user_id,title,created,last_post,pinned) VALUES(?,?,?,?,?,1)', (cat, uid, 'Welcome to gbOS86', now, now))
        tid = c.execute('SELECT last_insert_rowid()').fetchone()[0]
        c.execute('INSERT INTO posts(thread_id,user_id,body,created) VALUES(?,?,?,?)', (tid, uid, pages.WELCOME_POST, now))
    c.commit()


# ---------------------------------------------------------------- security helpers
def hash_pw(pw):
    salt = secrets.token_bytes(16)
    h = hashlib.scrypt(pw.encode(), salt=salt, n=2 ** 14, r=8, p=1, maxmem=64 * 1024 * 1024, dklen=32)
    return 's1$' + salt.hex() + '$' + h.hex()


def check_pw(pw, stored):
    try:
        _, salt, h = stored.split('$')
        t = hashlib.scrypt(pw.encode(), salt=bytes.fromhex(salt), n=2 ** 14, r=8, p=1, maxmem=64 * 1024 * 1024, dklen=32)
        return hmac.compare_digest(t.hex(), h)
    except Exception:
        return False


_hits = {}
_hits_lock = threading.Lock()


def limited(key, n, per):
    """True if `key` already made n requests in the last `per` seconds (and records this one)."""
    now = time.time()
    with _hits_lock:
        q = [t for t in _hits.get(key, []) if now - t < per]
        over = len(q) >= n
        if not over:
            q.append(now)
        _hits[key] = q
        if len(_hits) > 5000:
            for k in [k for k, v in _hits.items() if not v or now - v[-1] > 3600]:
                _hits.pop(k, None)
    return over


TS_SITE = os.environ.get('GBOS_TURNSTILE_SITE', '')
TS_SECRET = os.environ.get('GBOS_TURNSTILE_SECRET', '')
pages.TURNSTILE_SITE = TS_SITE
COMMON_PW = {'password', 'password1', 'password12', 'password123', '1234567890', '12345678910', 'qwertyuiop', 'qwerty12345', 'iloveyou123',
             'letmein1234', 'welcome1234', 'admin12345', 'changeme123', 'passw0rd123', 'gbos86gbos86', 'googlebook1'}


def weak_password(pw, name):
    low = pw.lower()
    if len(pw) < 10: return 'Password must be at least 10 characters.'
    if len(pw) > 200: return 'Password is too long.'
    if low in COMMON_PW or len(set(low)) < 5: return 'That password is too easy to guess. Use a longer, less common one.'
    if name and name.lower() in low: return 'Password must not contain your username.'
    return ''


def captcha_ok(req):
    """Cloudflare Turnstile check. Disabled (always True) until GBOS_TURNSTILE_SECRET is set; fails closed on errors."""
    if not TS_SECRET:
        return True
    tok = req.field('cf-turnstile-response')
    if not tok or len(tok) > 2048:
        return False
    try:
        data = urllib.parse.urlencode({'secret': TS_SECRET, 'response': tok, 'remoteip': req.ip}).encode()
        r = urllib.request.urlopen(urllib.request.Request('https://challenges.cloudflare.com/turnstile/v0/siteverify', data=data), timeout=6)
        return bool(json.loads(r.read().decode()).get('success'))
    except Exception as ex:
        sys.stderr.write('turnstile error: %r\n' % (ex,))
        return False


NAME_RE = re.compile(r'^[A-Za-z0-9_.-]{3,24}$')


e = html.escape


# ---------------------------------------------------------------- request handling
class Req:
    def __init__(self, h):
        self.h = h
        u = urllib.parse.urlsplit(h.path)
        self.path = urllib.parse.unquote(u.path)
        self.q = urllib.parse.parse_qs(u.query)
        self.method = h.command
        self.ip = h.headers.get('CF-Connecting-IP') or (h.headers.get('X-Forwarded-For', '').split(',')[0].strip()) or h.client_address[0]
        self.secure = h.headers.get('X-Forwarded-Proto', '') == 'https' or '"https"' in h.headers.get('CF-Visitor', '')
        self.form = {}
        self.user = None
        self.csrf = ''
        self.token = ''
        self.cookies_out = []
        c = cookies.SimpleCookie(h.headers.get('Cookie', ''))
        tok = c['gb_s'].value if 'gb_s' in c else ''
        if tok and re.fullmatch(r'[0-9a-f]{64}', tok):
            row = db().execute('SELECT u.*, s.csrf AS csrf, s.expires AS exp FROM sessions s JOIN users u ON u.id=s.user_id WHERE s.token=?',
                               (hashlib.sha256(tok.encode()).hexdigest(),)).fetchone()
            if row and row['exp'] > time.time() and not row['banned']:
                self.user, self.csrf, self.token = row, row['csrf'], tok
        if not self.csrf:  # anonymous forms still get a token, tied to an anonymous cookie
            a = c['gb_a'].value if 'gb_a' in c and re.fullmatch(r'[0-9a-f]{32}', c['gb_a'].value) else secrets.token_hex(16)
            self.anon = a
            self.cookies_out.append(self.cookie('gb_a', a, 86400))
            self.csrf = hmac.new(SECRET, a.encode(), 'sha256').hexdigest()
        else:
            self.anon = None

    def arg(self, k, default=''):
        return self.q.get(k, [default])[0]

    def field(self, k, default=''):
        return self.form.get(k, [default])[0].replace('\r\n', '\n').replace('\r', '\n')

    def cookie(self, name, value, max_age):
        s = '%s=%s; Path=/; Max-Age=%d; HttpOnly; SameSite=Lax' % (name, value, max_age)
        return s + ('; Secure' if self.secure else '')

    def check_csrf(self):
        tok = self.field('csrf')
        return bool(tok) and hmac.compare_digest(tok, self.csrf)


SECRET = b''


def load_secret():
    global SECRET
    p = os.path.join(DATA, 'secret.key')
    if not os.path.exists(p):
        fd = os.open(p, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        os.write(fd, secrets.token_bytes(32)); os.close(fd)
    SECRET = open(p, 'rb').read()


class Resp(Exception):
    def __init__(self, status=200, body='', ctype='text/html; charset=utf-8', headers=()):
        self.status, self.body, self.ctype, self.headers = status, body, ctype, list(headers)


def redirect(url, headers=()):
    return Resp(303, '', headers=[('Location', url)] + list(headers))


def page(req, title, body, status=200, desc='', nav=''):
    return Resp(status, pages.layout(req, title, body, desc=desc, nav=nav))


def err(req, status, msg):
    return page(req, 'Error %d' % status, '<div class="card narrow"><h1>%s</h1><p>%s</p><p><a href="/">Back to the front page</a></p></div>'
                % (status, e(msg)), status=status)


POST_DELAY = 15 * 60  # new accounts (non-staff) may post after 15 minutes


def too_new(req):
    """'' if the user may post, else a message saying how long to wait."""
    if req.user['is_admin']:
        return ''
    left = POST_DELAY - (int(time.time()) - req.user['created'])
    if left <= 0:
        return ''
    return 'New accounts can post after 15 minutes. Please wait about %d more minute%s.' % ((left + 59) // 60, '' if left <= 60 else 's')


def need_login(req):
    if not req.user:
        raise redirect('/login?next=' + urllib.parse.quote(req.path))


def form_csrf(req):
    return '<input type="hidden" name="csrf" value="%s">' % req.csrf


# ---------------------------------------------------------------- routes
def route_home(req):
    c = db()
    cats = c.execute('SELECT c.*, (SELECT COUNT(*) FROM threads t WHERE t.cat_id=c.id) AS nt, '
                     '(SELECT COUNT(*) FROM posts p JOIN threads t ON t.id=p.thread_id WHERE t.cat_id=c.id) AS np FROM categories c ORDER BY pos').fetchall()
    latest = c.execute('SELECT t.*, u.name AS author, c.title AS ctitle, c.slug AS cslug FROM threads t JOIN users u ON u.id=t.user_id '
                       'JOIN categories c ON c.id=t.cat_id ORDER BY t.last_post DESC LIMIT 8').fetchall()
    news = c.execute("SELECT t.id, t.title, t.created FROM threads t JOIN categories c ON c.id=t.cat_id WHERE c.slug='announcements' "
                     'ORDER BY t.created DESC LIMIT 4').fetchall()
    st = {'members': c.execute("SELECT COUNT(*) FROM users WHERE pw!='!'").fetchone()[0], 'threads': c.execute('SELECT COUNT(*) FROM threads').fetchone()[0],
          'posts': c.execute('SELECT COUNT(*) FROM posts').fetchone()[0]}
    return page(req, 'gbOS86: GooglebookOS for Non-Google PCs', pages.home(req, cats, latest, news, st),
                desc='gbOS86 runs Google\'s Googlebook OS on ordinary Intel laptops: patched, with hardware detection for Wi-Fi, Bluetooth, sound, touchpad and display. Guides, hardware reports and a community forum.')


def route_forum(req):
    c = db()
    cats = c.execute('SELECT c.*, (SELECT COUNT(*) FROM threads t WHERE t.cat_id=c.id) AS nt, '
                     '(SELECT COUNT(*) FROM posts p JOIN threads t ON t.id=p.thread_id WHERE t.cat_id=c.id) AS np, '
                     '(SELECT t.title || char(1) || t.id || char(1) || t.last_post FROM threads t WHERE t.cat_id=c.id ORDER BY t.last_post DESC LIMIT 1) AS lastt '
                     'FROM categories c ORDER BY pos').fetchall()
    return page(req, 'Forum', pages.forum_index(req, cats), nav='forum')


def route_category(req, slug):
    c = db()
    cat = c.execute('SELECT * FROM categories WHERE slug=?', (slug,)).fetchone()
    if not cat:
        return err(req, 404, 'No such forum.')
    pg = max(1, int(req.arg('p', '1') or 1)) if req.arg('p', '1').isdigit() else 1
    per = 25
    n = c.execute('SELECT COUNT(*) FROM threads WHERE cat_id=?', (cat['id'],)).fetchone()[0]
    ths = c.execute('SELECT t.*, u.name AS author, (SELECT u2.name FROM posts p JOIN users u2 ON u2.id=p.user_id WHERE p.thread_id=t.id ORDER BY p.id DESC LIMIT 1) AS lastby '
                    'FROM threads t JOIN users u ON u.id=t.user_id WHERE t.cat_id=? ORDER BY t.pinned DESC, t.last_post DESC LIMIT ? OFFSET ?',
                    (cat['id'], per, (pg - 1) * per)).fetchall()
    return page(req, cat['title'], pages.category(req, cat, ths, pg, (n + per - 1) // per), nav='forum', desc=cat['descr'])


def route_thread(req, tid):
    c = db()
    t = c.execute('SELECT t.*, c.title AS ctitle, c.slug AS cslug FROM threads t JOIN categories c ON c.id=t.cat_id WHERE t.id=?', (tid,)).fetchone()
    if not t:
        return err(req, 404, 'No such thread.')
    per = 20
    n = t['replies'] + 1
    pg = int(req.arg('p')) if req.arg('p').isdigit() and int(req.arg('p')) > 0 else 1
    ps = c.execute('SELECT p.*, u.name AS author, u.is_admin AS admin, u.laptop AS laptop, u.created AS joined, '
                   '(SELECT COUNT(*) FROM posts p2 WHERE p2.user_id=u.id) AS pcount FROM posts p JOIN users u ON u.id=p.user_id '
                   'WHERE p.thread_id=? ORDER BY p.id LIMIT ? OFFSET ?', (tid, per, (pg - 1) * per)).fetchall()
    if not limited('view:%s:%d' % (req.ip, tid), 1, 600):
        c.execute('UPDATE threads SET views=views+1 WHERE id=?', (tid,)); c.commit()
    return page(req, t['title'], pages.thread(req, t, ps, pg, (n + per - 1) // per), nav='forum')


def route_new_thread(req, slug):
    c = db()
    cat = c.execute('SELECT * FROM categories WHERE slug=?', (slug,)).fetchone()
    if not cat:
        return err(req, 404, 'No such forum.')
    need_login(req)
    if cat['staff_only'] and not req.user['is_admin']:
        return err(req, 403, 'Only staff can start threads here.')
    msg = ''
    title = body = ''
    if req.method == 'POST':
        title, body = req.field('title').strip(), req.field('body').strip()
        if not req.check_csrf(): msg = 'Session expired, please try again.'
        elif too_new(req): msg = too_new(req)
        elif not (3 <= len(title) <= 120): msg = 'Title must be 3-120 characters.'
        elif not (2 <= len(body) <= 20000): msg = 'Message must be 2-20000 characters.'
        elif limited('post:%d' % req.user['id'], 6, 120): msg = 'You are posting too fast. Wait a minute.'
        else:
            now = int(time.time())
            c.execute('INSERT INTO threads(cat_id,user_id,title,created,last_post) VALUES(?,?,?,?,?)', (cat['id'], req.user['id'], title, now, now))
            tid = c.execute('SELECT last_insert_rowid()').fetchone()[0]
            c.execute('INSERT INTO posts(thread_id,user_id,body,created) VALUES(?,?,?,?)', (tid, req.user['id'], body, now))
            c.commit()
            raise redirect('/forum/t/%d' % tid)
    return page(req, 'New thread in ' + cat['title'], pages.new_thread(req, cat, title, body, msg), nav='forum', status=400 if msg else 200)


def route_reply(req, tid):
    c = db()
    t = c.execute('SELECT * FROM threads WHERE id=?', (tid,)).fetchone()
    if not t:
        return err(req, 404, 'No such thread.')
    need_login(req)
    if req.method != 'POST':
        raise redirect('/forum/t/%d' % tid)
    body = req.field('body').strip()
    if not req.check_csrf(): return err(req, 400, 'Session expired, go back and try again.')
    if too_new(req): return err(req, 403, too_new(req))
    if t['locked'] and not req.user['is_admin']: return err(req, 403, 'This thread is locked.')
    if not (2 <= len(body) <= 20000): return err(req, 400, 'Message must be 2-20000 characters.')
    if limited('post:%d' % req.user['id'], 6, 120): return err(req, 429, 'You are posting too fast. Wait a minute.')
    now = int(time.time())
    c.execute('INSERT INTO posts(thread_id,user_id,body,created) VALUES(?,?,?,?)', (tid, req.user['id'], body, now))
    pid = c.execute('SELECT last_insert_rowid()').fetchone()[0]
    c.execute('UPDATE threads SET replies=replies+1, last_post=? WHERE id=?', (now, tid))
    c.commit()
    n = c.execute('SELECT replies+1 FROM threads WHERE id=?', (tid,)).fetchone()[0]
    raise redirect('/forum/t/%d?p=%d#p%d' % (tid, (n + 19) // 20, pid))


def route_mod(req, action, ident):
    """Admin actions: pin/lock/unpin/unlock/delete-thread/delete-post."""
    need_login(req)
    if req.method != 'POST' or not req.user['is_admin'] or not req.check_csrf():
        return err(req, 403, 'Not allowed.')
    c = db()
    if action in ('pin', 'unpin', 'lock', 'unlock'):
        col, val = ('pinned', 1) if action == 'pin' else ('pinned', 0) if action == 'unpin' else ('locked', 1) if action == 'lock' else ('locked', 0)
        c.execute('UPDATE threads SET %s=? WHERE id=?' % col, (val, ident)); c.commit()
        raise redirect('/forum/t/%d' % ident)
    if action == 'delthread':
        t = c.execute('SELECT c.slug FROM threads t JOIN categories c ON c.id=t.cat_id WHERE t.id=?', (ident,)).fetchone()
        c.execute('DELETE FROM threads WHERE id=?', (ident,)); c.commit()
        raise redirect('/forum/c/' + (t['slug'] if t else ''))
    if action == 'delpost':
        p = c.execute('SELECT thread_id FROM posts WHERE id=?', (ident,)).fetchone()
        if not p: return err(req, 404, 'No such post.')
        first = c.execute('SELECT MIN(id) FROM posts WHERE thread_id=?', (p['thread_id'],)).fetchone()[0]
        if first == ident: return err(req, 400, 'Delete the thread instead.')
        c.execute('DELETE FROM posts WHERE id=?', (ident,))
        c.execute('UPDATE threads SET replies=replies-1 WHERE id=?', (p['thread_id'],)); c.commit()
        raise redirect('/forum/t/%d' % p['thread_id'])
    return err(req, 404, 'Unknown action.')


def start_session(req, uid):
    tok = secrets.token_hex(32)
    db().execute('INSERT INTO sessions(token,user_id,csrf,expires) VALUES(?,?,?,?)',
                 (hashlib.sha256(tok.encode()).hexdigest(), uid, secrets.token_hex(16), int(time.time()) + SESSION_DAYS * 86400))
    db().execute('DELETE FROM sessions WHERE expires<?', (int(time.time()),))
    db().commit()
    return req.cookie('gb_s', tok, SESSION_DAYS * 86400)


def safe_next(n):
    return n if n.startswith('/') and not n.startswith('//') and '\\' not in n else '/forum'


def ip_hash(req):
    return hashlib.sha256(req.ip.encode() + SECRET).hexdigest()[:16]


def ip_accounts(req):
    return db().execute('SELECT COUNT(*) FROM users WHERE ip=? AND created>?', (ip_hash(req), int(time.time()) - 86400)).fetchone()[0]


def route_register(req):
    msg, name, email = '', '', ''
    if req.method == 'POST':
        name, email = req.field('name').strip(), req.field('email').strip()
        pw, pw2 = req.field('password'), req.field('password2')
        if not req.check_csrf(): msg = 'Your session token did not match. Reload the page and try again (cookies must be enabled).'
        elif req.field('website'): msg = 'Registration failed.'  # honeypot
        elif not NAME_RE.match(name): msg = 'Username: 3-24 letters, digits, _ . -'
        elif weak_password(pw, name): msg = weak_password(pw, name)
        elif pw != pw2: msg = 'Passwords do not match.'
        elif not email or len(email) > 120 or not re.fullmatch(r'[^@\s]+@[^@\s]+\.[^@\s]+', email): msg = 'Enter a valid email address.'
        elif limited('reg:' + req.ip, 4, 3600): msg = 'Too many registrations from your network. Try later.'
        elif ip_accounts(req) >= 2: msg = 'Too many accounts were created from your network in the last 24 hours. Try again tomorrow.'
        elif not captcha_ok(req): msg = 'Please complete the human check and try again.'
        elif name.lower() in ('admin', 'administrator', 'moderator', 'staff', 'root', 'support', 'gbos86'): msg = 'That username is reserved.'
        else:
            try:
                db().execute('INSERT INTO users(name,pw,email,created,ip) VALUES(?,?,?,?,?)', (name, hash_pw(pw), email.lower(), int(time.time()), ip_hash(req)))
                db().commit()
            except sqlite3.IntegrityError as ex:
                msg = 'That email address is already registered.' if 'email' in str(ex) else 'That username is taken.'
            else:
                uid = db().execute('SELECT id FROM users WHERE name=?', (name,)).fetchone()[0]
                raise redirect('/forum', headers=[('Set-Cookie', start_session(req, uid))])
    return page(req, 'Register', pages.register(req, msg, name, email), nav='forum', status=400 if msg else 200)


def route_login(req):
    msg = ''
    nxt = safe_next(req.arg('next') or req.field('next'))
    if req.method == 'POST':
        name, pw = req.field('name').strip(), req.field('password')
        if not req.check_csrf(): msg = 'Session expired, please try again.'
        elif limited('login:' + req.ip, 10, 600) or limited('loginu:' + name.lower(), 8, 600): msg = 'Too many attempts. Wait a few minutes.'
        elif not captcha_ok(req): msg = 'Please complete the human check and try again.'
        else:
            u = db().execute('SELECT * FROM users WHERE name=?', (name,)).fetchone()
            ok = check_pw(pw, u['pw']) if u else check_pw(pw, 's1$' + '00' * 16 + '$' + '00' * 32)  # equalise timing
            if u and ok and not u['banned']:
                raise redirect(nxt, headers=[('Set-Cookie', start_session(req, u['id']))])
            msg = 'Wrong username or password.'
    return page(req, 'Log in', pages.login(req, msg, nxt), nav='forum', status=400 if msg else 200)


def route_logout(req):
    if req.method == 'POST' and req.check_csrf() and req.token:
        db().execute('DELETE FROM sessions WHERE token=?', (hashlib.sha256(req.token.encode()).hexdigest(),)); db().commit()
    raise redirect('/', headers=[('Set-Cookie', req.cookie('gb_s', '', 0))])


def route_profile(req, name):
    c = db()
    u = c.execute('SELECT * FROM users WHERE name=?', (name,)).fetchone()
    if not u:
        return err(req, 404, 'No such member.')
    ths = c.execute('SELECT t.*, c.title AS ctitle FROM threads t JOIN categories c ON c.id=t.cat_id WHERE t.user_id=? ORDER BY t.created DESC LIMIT 15', (u['id'],)).fetchall()
    cnt = c.execute('SELECT COUNT(*) FROM posts WHERE user_id=?', (u['id'],)).fetchone()[0]
    return page(req, u['name'], pages.profile(req, u, ths, cnt), nav='forum')


def route_settings(req):
    need_login(req)
    msg = ''
    if req.method == 'POST':
        if not req.check_csrf(): msg = 'Session expired, please try again.'
        else:
            bio, laptop = req.field('bio').strip()[:500], req.field('laptop').strip()[:100]
            db().execute('UPDATE users SET bio=?, laptop=? WHERE id=?', (bio, laptop, req.user['id'])); db().commit()
            raise redirect('/u/' + urllib.parse.quote(req.user['name']))
    return page(req, 'Profile settings', pages.settings(req, msg), nav='forum')


def route_search(req):
    q = req.arg('q').strip()[:80]
    res = []
    if len(q) >= 2 and not limited('search:' + req.ip, 20, 60):
        like = '%' + q.replace('\\', '\\\\').replace('%', '\\%').replace('_', '\\_') + '%'
        res = db().execute("SELECT t.id, t.title, t.created, u.name AS author, c.title AS ctitle FROM threads t JOIN users u ON u.id=t.user_id JOIN categories c ON c.id=t.cat_id "
                           "WHERE t.title LIKE ? ESCAPE '\\' OR t.id IN (SELECT thread_id FROM posts WHERE body LIKE ? ESCAPE '\\') ORDER BY t.last_post DESC LIMIT 40",
                           (like, like)).fetchall()
    return page(req, 'Search', pages.search(req, q, res), nav='forum')


def route_contact(req):
    msg, ok = '', False
    f = {'name': '', 'email': '', 'subject': '', 'body': ''}
    if req.method == 'POST':
        for k in f: f[k] = req.field(k).strip()
        if not req.check_csrf(): msg = 'Session expired, please try again.'
        elif req.field('website'): ok = True  # honeypot: pretend success
        elif not (1 <= len(f['name']) <= 80 and 3 <= len(f['subject']) <= 120 and 5 <= len(f['body']) <= 5000): msg = 'Please fill in name, subject (3+) and message (5+ characters).'
        elif not re.fullmatch(r'[^@\s]+@[^@\s]+\.[^@\s]+', f['email']) or len(f['email']) > 120: msg = 'Please give a valid email address so we can reply.'
        elif limited('contact:' + req.ip, 3, 3600): msg = 'Too many messages from your network. Try again later.'
        elif not captcha_ok(req): msg = 'Please complete the human check and try again.'
        else:
            db().execute('INSERT INTO messages(name,email,subject,body,created,ip) VALUES(?,?,?,?,?,?)',
                         (f['name'], f['email'], f['subject'], f['body'], int(time.time()), hashlib.sha256(req.ip.encode() + SECRET).hexdigest()[:16]))
            db().commit(); ok = True
    return page(req, 'Contact', pages.contact(req, f, msg, ok), nav='contact', status=400 if msg else 200)


def route_admin(req):
    need_login(req)
    if not req.user['is_admin']:
        return err(req, 403, 'Staff only.')
    if req.method == 'POST' and req.check_csrf() and req.field('handle').isdigit():
        db().execute('UPDATE messages SET handled=1-handled WHERE id=?', (int(req.field('handle')),)); db().commit()
        raise redirect('/admin')
    msgs = db().execute('SELECT * FROM messages ORDER BY handled, id DESC LIMIT 100').fetchall()
    users = db().execute("SELECT name, created, is_admin FROM users WHERE pw!='!' ORDER BY id DESC LIMIT 30").fetchall()
    return page(req, 'Admin', pages.admin(req, msgs, users), nav='forum')


def route_sitemap(req):
    c = db()
    urls = ['/', '/docs'] + ['/docs/' + d[0] for d in __import__('docs').DOCS] + ['/hardware', '/download', '/faq', '/about', '/contact', '/forum'] + ['/forum/c/' + r[0] for r in c.execute('SELECT slug FROM categories')]
    urls += ['/forum/t/%d' % r[0] for r in c.execute('SELECT id FROM threads ORDER BY id DESC LIMIT 500')]
    body = '<?xml version="1.0" encoding="UTF-8"?><urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">' + ''.join('<url><loc>%s%s</loc></url>' % (BASE, u) for u in urls) + '</urlset>'
    return Resp(200, body, 'application/xml')


STATIC_PAGES = {'/hardware': ('Hardware', pages.hardware, 'Supported Intel laptops, Wi-Fi, Bluetooth, audio, touchpad and graphics for gbOS86.'),
                '/download': ('Get gbOS86', pages.download, 'How to build the gbOS86 image from Google\'s recovery image and flash it.'),
                '/faq': ('FAQ', pages.faq, 'Frequently asked questions about gbOS86.'),
                '/about': ('About', pages.about, 'About gbOS86, who makes it and how it works.')}


def dispatch(req):
    p, m = req.path, req.method
    if p == '/': return route_home(req)
    if p in STATIC_PAGES:
        title, fn, desc = STATIC_PAGES[p]
        return page(req, title, fn(req), desc=desc, nav=p[1:])
    if p == '/guide': raise Resp(301, '', headers=[('Location', '/docs/install')])
    if p == '/docs': return page(req, 'Install & Docs', pages.docs_index(req), nav='docs', desc='Install guide and full documentation for gbOS86: how it works, CPU emulation, hardware detection, configuration, logs, updating and building.')
    mm = re.fullmatch(r'/docs/([a-z-]{1,30})', p)
    if mm:
        d = pages.docs_page(req, mm.group(1))
        if not d: return err(req, 404, 'No such documentation page.')
        return page(req, d[0], d[1], nav='docs', desc='gbOS86 documentation: ' + d[0])
    if p == '/forum': return route_forum(req)
    mm = re.fullmatch(r'/forum/c/([a-z]+)', p)
    if mm: return route_category(req, mm.group(1))
    mm = re.fullmatch(r'/forum/c/([a-z]+)/new', p)
    if mm: return route_new_thread(req, mm.group(1))
    mm = re.fullmatch(r'/forum/t/(\d{1,9})', p)
    if mm: return route_thread(req, int(mm.group(1)))
    mm = re.fullmatch(r'/forum/t/(\d{1,9})/reply', p)
    if mm: return route_reply(req, int(mm.group(1)))
    mm = re.fullmatch(r'/forum/mod/(pin|unpin|lock|unlock|delthread|delpost)/(\d{1,9})', p)
    if mm: return route_mod(req, mm.group(1), int(mm.group(2)))
    mm = re.fullmatch(r'/u/([A-Za-z0-9_.-]{1,24})', p)
    if mm: return route_profile(req, mm.group(1))
    routes = {'/register': route_register, '/login': route_login, '/logout': route_logout, '/settings': route_settings,
              '/search': route_search, '/contact': route_contact, '/admin': route_admin, '/sitemap.xml': route_sitemap}
    if p in routes: return routes[p](req)
    if p == '/robots.txt':
        return Resp(200, 'User-agent: *\nDisallow: /admin\nDisallow: /login\nDisallow: /register\nDisallow: /search\nSitemap: %s/sitemap.xml\n' % BASE, 'text/plain; charset=utf-8')
    if p == '/favicon.ico':
        raise redirect('/static/favicon.png')
    return err(req, 404, 'That page does not exist.')


def serve_static(h, rel):
    fp = os.path.normpath(os.path.join(STATIC, rel))
    if not fp.startswith(STATIC + os.sep) or not os.path.isfile(fp):
        return False
    size = os.path.getsize(fp)
    start, end, status = 0, size - 1, 200
    rng = h.headers.get('Range', '')
    m = re.fullmatch(r'bytes=(\d*)-(\d*)', rng)  # single range only: enough for video seeking
    if m and (m.group(1) or m.group(2)):
        if m.group(1):
            start = int(m.group(1)); end = int(m.group(2)) if m.group(2) else size - 1
        else:
            start = max(0, size - int(m.group(2))); end = size - 1
        if start >= size or start > end:
            h.send_response(416); h.send_header('Content-Range', 'bytes */%d' % size); h.end_headers(); return True
        end = min(end, size - 1); status = 206
    h.send_response(status)
    h.send_header('Content-Type', MIME.get(os.path.splitext(fp)[1].lower(), 'application/octet-stream'))
    h.send_header('Content-Length', str(end - start + 1))
    h.send_header('Accept-Ranges', 'bytes')
    if status == 206:
        h.send_header('Content-Range', 'bytes %d-%d/%d' % (start, end, size))
    h.send_header('Cache-Control', 'public, max-age=86400')
    h.send_header('X-Content-Type-Options', 'nosniff')
    h.end_headers()
    if h.command != 'HEAD':
        with open(fp, 'rb') as f:
            f.seek(start)
            left = end - start + 1
            while left:
                b = f.read(min(left, 1 << 20))
                if not b:
                    break
                h.wfile.write(b); left -= len(b)
    return True


_TS = ' https://challenges.cloudflare.com' if TS_SECRET else ''
CSP = ("default-src 'self'; img-src 'self' data:; style-src 'self'; script-src 'self'%s; frame-src 'self'%s; connect-src 'self'%s; object-src 'none'; "
       "base-uri 'self'; form-action 'self'; frame-ancestors 'none'" % (_TS, _TS, _TS))


class Handler(http.server.BaseHTTPRequestHandler):
    server_version = 'gbos86'
    sys_version = ''
    timeout = 20

    def log_message(self, fmt, *a):
        pass

    def handle_any(self):
        try:
            self._handle()
        finally:
            try:  # never leave a write transaction open on this thread's connection (a failed INSERT would hold the lock)
                db().rollback()
            except Exception:
                pass

    def _handle(self):
        try:
            if self.command not in ('GET', 'HEAD', 'POST'):
                self.send_error(405); return
            if self.path.startswith('/static/'):
                if not serve_static(self, urllib.parse.unquote(urllib.parse.urlsplit(self.path).path)[len('/static/'):]):
                    self.send_error(404)
                return
            req = Req(self)
            if req.method == 'POST':
                n = int(self.headers.get('Content-Length') or 0)
                if n > MAX_BODY:
                    self.send_error(413); return
                ct = self.headers.get('Content-Type', '')
                if not ct.startswith('application/x-www-form-urlencoded'):
                    self.send_error(415); return
                req.form = urllib.parse.parse_qs(self.rfile.read(n).decode('utf-8', 'replace'), keep_blank_values=True)
            try:
                resp = dispatch(req)
            except Resp as r:
                resp = r
            body = resp.body.encode() if isinstance(resp.body, str) else resp.body
            self.send_response(resp.status)
            self.send_header('Content-Type', resp.ctype)
            self.send_header('Content-Length', str(len(body)))
            self.send_header('Content-Security-Policy', CSP)
            self.send_header('X-Content-Type-Options', 'nosniff')
            self.send_header('X-Frame-Options', 'DENY')
            self.send_header('Referrer-Policy', 'strict-origin-when-cross-origin')
            self.send_header('Permissions-Policy', 'camera=(), microphone=(), geolocation=()')
            if req.secure:
                self.send_header('Strict-Transport-Security', 'max-age=15552000')
            if req.method == 'POST' or req.user:
                self.send_header('Cache-Control', 'no-store')
            for c in req.cookies_out:
                self.send_header('Set-Cookie', c)
            for k, v in resp.headers:
                self.send_header(k, v)
            self.end_headers()
            if self.command != 'HEAD':
                self.wfile.write(body)
        except (BrokenPipeError, ConnectionResetError, TimeoutError):
            pass
        except Exception as ex:  # never leak internals
            sys.stderr.write('error %s %s: %r\n' % (self.command, self.path, ex))
            try:
                self.send_error(500)
            except Exception:
                pass

    do_GET = do_POST = do_HEAD = handle_any


class Server(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True
    request_queue_size = 64


def main():
    os.makedirs(DATA, exist_ok=True)
    load_secret()
    init_db()
    if len(sys.argv) > 1 and sys.argv[1] == 'promote':
        db().execute('UPDATE users SET is_admin=1 WHERE name=?', (sys.argv[2],)); db().commit()
        print('admin:', db().execute('SELECT name FROM users WHERE is_admin=1').fetchall() and [r[0] for r in db().execute('SELECT name FROM users WHERE is_admin=1')])
        return
    if len(sys.argv) > 1 and sys.argv[1] == 'backup':  # consistent copy of the live DB, keeps the newest 14
        bdir = os.path.join(DATA, 'backups'); os.makedirs(bdir, exist_ok=True)
        dst = sqlite3.connect(os.path.join(bdir, 'site-%s.db' % time.strftime('%Y%m%d')))
        db().backup(dst); dst.close()
        for old in sorted(os.listdir(bdir))[:-14]:
            os.remove(os.path.join(bdir, old))
        print('backup ok:', sorted(os.listdir(bdir))[-1])
        return
    if len(sys.argv) > 1 and sys.argv[1] == 'stats':
        for t in ('users', 'threads', 'posts', 'messages'):
            print(t, db().execute('SELECT COUNT(*) FROM %s' % t).fetchone()[0])
        return
    host, port = BIND.rsplit(':', 1)
    print('gbos86 site on %s' % BIND, flush=True)
    Server((host, int(port)), Handler).serve_forever()


if __name__ == '__main__':
    main()
