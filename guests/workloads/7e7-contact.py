#!/usr/bin/env python3
"""7e7.co contact-form handler. Python 3 stdlib only.

  GET  /api/contact   -> {"ok":true,"token":"..."}   (fill-time token, HMAC-signed timestamp)
  POST /api/contact   -> {"ok":true} | {"ok":false,"error":"..."}
       JSON or application/x-www-form-urlencoded:
       name, email, phone (optional), contact_method (optional: Phone|Email), message,
       website (honeypot, must be empty), token (from GET)

Sends one plain-text mail per accepted submission via SMTP. Logs outcome only (never bodies).

Anti-spam (no third-party scripts):
  1. Honeypot: a non-empty `website` field is dropped. The response is the same
     200 {"ok":true} a real submission gets; nothing is mailed.
  2. Fill-time token: contact.js fetches a signed timestamp on page load. Submissions
     faster than CONTACT_MIN_SECONDS, or with a missing/invalid token, are dropped
     the same silent-200 way. An expired token (tab left open too long) still
     returns 400 so a real visitor can reload and try again.
  3. Per-IP rate limit: in-process backstop (CONTACT_RATE_PER_IP per
     CONTACT_RATE_WINDOW). nginx also applies limit_req (see deploy/nginx-web01.md).

Configuration (environment):
  CONTACT_LISTEN       127.0.0.1:8790
  CONTACT_SMTP_HOST    smtp.bitrail.com
  CONTACT_SMTP_PORT    25
  CONTACT_SMTP_TLS     opportunistic | verify | off   (STARTTLS when offered; "verify" checks the cert)
  CONTACT_SMTP_USER / CONTACT_SMTP_PASSWORD_FILE      optional AUTH (e.g. port 587 submission)
  CONTACT_MAIL_FROM    noreply@7e7.co      CONTACT_FROM_NAME  7e7 website
  CONTACT_MAIL_TO      schwim@7e7.co
  CONTACT_TRUST_PROXY  1   (client IP from X-Real-IP or X-Forwarded-For when the peer is loopback)
  CONTACT_MIN_SECONDS  3     CONTACT_MAX_TOKEN_AGE 7200
  CONTACT_RATE_PER_IP  5 per CONTACT_RATE_WINDOW 3600 s;  CONTACT_RATE_GLOBAL 60 per window
"""
import hashlib, hmac, json, logging, os, re, secrets, smtplib, ssl, sys, threading, time
from collections import deque
from email.message import EmailMessage
from email.utils import formataddr, formatdate, make_msgid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs

E = os.environ.get
LISTEN = E('CONTACT_LISTEN', '127.0.0.1:8790')
SMTP_HOST = E('CONTACT_SMTP_HOST', 'smtp.bitrail.com')
SMTP_PORT = int(E('CONTACT_SMTP_PORT', '25'))
SMTP_TLS = E('CONTACT_SMTP_TLS', 'opportunistic')
SMTP_USER = E('CONTACT_SMTP_USER', '')
SMTP_PASSWORD_FILE = E('CONTACT_SMTP_PASSWORD_FILE', '')
MAIL_FROM = E('CONTACT_MAIL_FROM', 'noreply@7e7.co')
FROM_NAME = E('CONTACT_FROM_NAME', '7e7 website')
MAIL_TO = E('CONTACT_MAIL_TO', 'schwim@7e7.co')
HELO = E('CONTACT_HELO', 'www.7e7.co')
TRUST_PROXY = E('CONTACT_TRUST_PROXY', '1') == '1'
MIN_SECONDS = float(E('CONTACT_MIN_SECONDS', '3'))
MAX_TOKEN_AGE = float(E('CONTACT_MAX_TOKEN_AGE', '7200'))
RATE_PER_IP = int(E('CONTACT_RATE_PER_IP', '5'))
RATE_GLOBAL = int(E('CONTACT_RATE_GLOBAL', '60'))
RATE_WINDOW = float(E('CONTACT_RATE_WINDOW', '3600'))
MAX_BODY = 32 * 1024
LIMITS = {'name': 100, 'email': 254, 'phone': 40, 'contact_method': 10, 'message': 5000}
SECRET = secrets.token_bytes(32)   # per process; a restart only invalidates open forms' tokens

EMAIL_RE = re.compile(r"^[A-Za-z0-9.!#$%&'*+/=?^_`{|}~-]{1,64}@(?=.{1,253}$)"
                      r"[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?(?:\.[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?)+$")
PHONE_RE = re.compile(r'^[0-9+()./ x-]{0,40}$')
CTRL_RE = re.compile(r'[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]')
log = logging.getLogger('contact')

class RateLimiter:
    def __init__(self):
        self.lock = threading.Lock(); self.per_ip = {}; self.all = deque()
    def allow(self, ip, now):
        with self.lock:
            cut = now - RATE_WINDOW
            while self.all and self.all[0] < cut: self.all.popleft()
            # Expire complete IP buckets, not only the current client's queue.
            for key in [k for k, v in self.per_ip.items() if not v or v[-1] < cut]:
                del self.per_ip[key]
            if ip not in self.per_ip and len(self.per_ip) >= 10000:
                return False
            q = self.per_ip.setdefault(ip, deque())
            while q and q[0] < cut: q.popleft()
            if len(q) >= RATE_PER_IP or len(self.all) >= RATE_GLOBAL:
                return False
            q.append(now); self.all.append(now)
            if len(self.per_ip) > 10000:   # bound memory
                for k in [k for k, v in self.per_ip.items() if not v]: del self.per_ip[k]
            return True
limiter = RateLimiter()

def make_token(now=None):
    ts = str(int(now or time.time()))
    return ts + '.' + hmac.new(SECRET, ts.encode(), hashlib.sha256).hexdigest()[:32]

def check_token(tok, now):
    if not tok or not str(tok).strip():
        return 'missing'
    try:
        ts, sig = tok.split('.', 1)
        good = hmac.new(SECRET, ts.encode(), hashlib.sha256).hexdigest()[:32]
        if not hmac.compare_digest(sig, good):
            return 'invalid'
        age = now - int(ts)
    except Exception:
        return 'invalid'
    if age < MIN_SECONDS:
        return 'too_fast'
    if age > MAX_TOKEN_AGE:
        return 'expired'
    return None

class Invalid(Exception):
    pass

def validate(d):
    f = {}
    for k, lim in LIMITS.items():
        v = d.get(k, '')
        if not isinstance(v, str): raise Invalid(f'invalid {k}')
        if k != 'message' and ('\r' in v or '\n' in v or '\t' in v):
            raise Invalid(f'invalid characters in {k}')
        v = v.strip() if k != 'message' else v.strip('\r\n\t ')
        if len(v) > lim: raise Invalid(f'{k} is too long (max {lim} characters)')
        f[k] = v
    if not f['name']: raise Invalid('name is required')
    if not f['email']: raise Invalid('email is required')
    if not f['message']: raise Invalid('message is required')
    for k in ('name', 'email', 'phone', 'contact_method'):     # header-bound / single-line fields
        if '\r' in f[k] or '\n' in f[k] or CTRL_RE.search(f[k]): raise Invalid(f'invalid characters in {k}')
    if CTRL_RE.search(f['message']): raise Invalid('invalid characters in message')
    if not EMAIL_RE.match(f['email']): raise Invalid('email address looks invalid')
    if f['phone'] and not PHONE_RE.match(f['phone']): raise Invalid('phone number looks invalid')
    if f['contact_method'] not in ('', 'Phone', 'Email'): raise Invalid('invalid contact method')
    return f

def send_mail(f, ip):
    msg = EmailMessage()
    msg['From'] = formataddr((FROM_NAME, MAIL_FROM))
    msg['To'] = MAIL_TO
    msg['Reply-To'] = formataddr((f['name'], f['email']))
    msg['Subject'] = f'7e7.co contact: {f["name"]}'
    msg['Date'] = formatdate(localtime=True)
    msg['Message-ID'] = make_msgid(domain=MAIL_FROM.split('@')[1])
    msg['Auto-Submitted'] = 'auto-generated'
    lines = [f'Name: {f["name"]}', f'Email: {f["email"]}']
    if f['phone']: lines.append(f'Phone: {f["phone"]}')
    if f['contact_method']: lines.append(f'Preferred contact method: {f["contact_method"]}')
    lines += ['', f['message'], '', '--', f'Sent from the contact form on www.7e7.co (client {ip}).']
    msg.set_content('\n'.join(lines))
    s = smtplib.SMTP(local_hostname=HELO, timeout=30)
    s._host = SMTP_HOST                       # SNI / hostname for STARTTLS
    try:
        s.connect(SMTP_HOST, SMTP_PORT)
        s.ehlo()
        if SMTP_TLS != 'off' and s.has_extn('starttls'):
            ctx = ssl.create_default_context()
            if SMTP_TLS != 'verify':
                ctx.check_hostname = False; ctx.verify_mode = ssl.CERT_NONE
            s.starttls(context=ctx); s.ehlo()
        elif SMTP_TLS == 'verify':
            raise smtplib.SMTPException('server does not offer STARTTLS')
        if SMTP_USER:
            if SMTP_TLS != 'verify' or not isinstance(s.sock, ssl.SSLSocket):
                raise smtplib.SMTPException('SMTP AUTH requires verified STARTTLS')
            s.login(SMTP_USER, open(SMTP_PASSWORD_FILE).read().strip())
        code, resp = s.mail(MAIL_FROM)
        if code != 250:
            raise smtplib.SMTPSenderRefused(code, resp, MAIL_FROM)
        code, resp = s.rcpt(MAIL_TO)
        if code not in (250, 251):
            raise smtplib.SMTPRecipientsRefused({MAIL_TO: (code, resp)})
        code, resp = s.data(msg.as_bytes())   # raises SMTPDataError unless 250
        return msg['Message-ID'], f'{code} {resp.decode(errors="replace")}'[:200]
    finally:
        try: s.quit()
        except Exception: pass

def trusted_client_ip(peer, headers):
    """Return the client IP. X-Real-IP / X-Forwarded-For are used only when the
    immediate peer is loopback (nginx on the same host). nginx should set both
    headers to $remote_addr so a client-supplied chain cannot be trusted."""
    if TRUST_PROXY and peer in ('127.0.0.1', '::1'):
        raw = (headers.get('X-Real-IP') or headers.get('X-Forwarded-For') or '').strip()
        if raw:
            cand = raw.split(',')[-1].strip()
            if cand and len(cand) <= 64 and not any(c in cand for c in ' \r\n\t'):
                return cand
    return peer

class Handler(BaseHTTPRequestHandler):
    server_version = 'contact'
    sys_version = ''
    def log_message(self, fmt, *a):          # silence default access log (nginx logs requests)
        pass
    def setup(self):
        super().setup()
        self.connection.settimeout(35)
    def client_ip(self):
        return trusted_client_ip(self.client_address[0], self.headers)
    def reply(self, status, obj):
        b = json.dumps(obj).encode()
        self.send_response(status)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Cache-Control', 'no-store')
        self.send_header('X-Content-Type-Options', 'nosniff')
        self.send_header('Content-Length', str(len(b)))
        self.end_headers(); self.wfile.write(b)
    def do_GET(self):
        if self.path.split('?')[0] != '/api/contact':
            return self.reply(404, {'ok': False, 'error': 'not found'})
        self.reply(200, {'ok': True, 'token': make_token()})
    def do_POST(self):
        ip = self.client_ip(); now = time.time()
        if self.path.split('?')[0] != '/api/contact':
            return self.reply(404, {'ok': False, 'error': 'not found'})
        try:
            n = int(self.headers.get('Content-Length') or 0)
        except ValueError:
            n = -1
        if n <= 0 or n > MAX_BODY:
            log.info('reject ip=%s reason=size', ip)
            return self.reply(413 if n > MAX_BODY else 400, {'ok': False, 'error': 'request body missing or too large'})
        raw = self.rfile.read(n)
        ctype = (self.headers.get('Content-Type') or '').split(';')[0].strip().lower()
        try:
            if ctype == 'application/json':
                d = json.loads(raw.decode('utf-8'))
                if not isinstance(d, dict): raise ValueError
            elif ctype == 'application/x-www-form-urlencoded':
                d = {k: v[0] for k, v in parse_qs(raw.decode('utf-8'), keep_blank_values=True).items()}
            else:
                return self.reply(415, {'ok': False, 'error': 'unsupported content type'})
        except (ValueError, UnicodeDecodeError):
            return self.reply(400, {'ok': False, 'error': 'malformed request'})
        if str(d.get('website', '')).strip():
            log.info('drop ip=%s reason=honeypot', ip)
            return self.reply(200, {'ok': True})            # look successful to bots
        bad = check_token(str(d.get('token', '')), now)
        if bad in ('too_fast', 'missing', 'invalid'):
            log.info('drop ip=%s reason=%s', ip, bad)
            return self.reply(200, {'ok': True})            # same silent drop as the honeypot
        if bad:
            log.info('reject ip=%s reason=token', ip)
            return self.reply(400, {'ok': False, 'error': 'This form has expired. Please reload the page and try again.'})
        try:
            f = validate(d)
        except Invalid as e:
            log.info('reject ip=%s reason=invalid detail=%s', ip, e)
            return self.reply(400, {'ok': False, 'error': str(e)[:1].upper() + str(e)[1:] + '.'})
        if not limiter.allow(ip, now):
            log.info('reject ip=%s reason=rate_limited', ip)
            return self.reply(429, {'ok': False, 'error': 'Too many messages. Please try again later.'})
        try:
            mid, smtp_reply = send_mail(f, ip)
        except smtplib.SMTPRecipientsRefused as e:
            r = list(e.recipients.values())[0]
            log.error('smtp_fail ip=%s rcpt_refused code=%s resp=%s', ip, r[0], r[1].decode(errors='replace')[:200])
            return self.reply(502, {'ok': False, 'error': 'Unable to send right now. Please try again later.'})
        except Exception as e:
            log.error('smtp_fail ip=%s err=%s: %s', ip, type(e).__name__, str(e)[:200])
            return self.reply(502, {'ok': False, 'error': 'Unable to send right now. Please try again later.'})
        log.info('sent ip=%s message_id=%s smtp="%s"', ip, mid, smtp_reply)
        self.reply(200, {'ok': True})

def main():
    logging.basicConfig(level=logging.INFO, stream=sys.stderr, format='%(levelname)s %(message)s')
    host, port = LISTEN.rsplit(':', 1)
    srv = ThreadingHTTPServer((host, int(port)), Handler)
    srv.daemon_threads = True
    log.info('listening on %s smtp=%s:%d tls=%s to=%s', LISTEN, SMTP_HOST, SMTP_PORT, SMTP_TLS, MAIL_TO)
    srv.serve_forever()

if __name__ == '__main__':
    main()
