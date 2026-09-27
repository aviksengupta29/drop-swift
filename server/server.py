#!/usr/bin/env python3
"""
DropSwift laptop server.

Shares ONE folder over the local network so the DropSwift iPhone app can
browse/download files from this computer and upload phone data to it.

Usage:
    python3 server.py                 # shares ./shared on port 8080
    python3 server.py --dir ~/Desktop/DropSwift --port 8080

Then on the iPhone app, enter the IP address + port printed at startup.
Phone and laptop must be on the same Wi-Fi / router.
"""

import argparse
import atexit
import hashlib
import io
import json
import mimetypes
import os
import secrets
import shutil
import socket
import subprocess
import signal
import sys
import threading
import time
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

# Set in main() before the server starts.
SHARE_ROOT = None

# Bonjour service type the iPhone app browses for.
SERVICE_TYPE = "_dropswift._tcp"

# 6-digit access code clients must enter, and the set of session tokens issued
# after a correct code. Tokens reset when the server restarts.
ACCESS_CODE = None
TOKENS = set()
TOKENS_LOCK = threading.Lock()

# Live transfer status — printed to stdout as structured lines that the macOS
# DropSwift Server app reads to show a "Receiving files…" card.
STATUS_LOCK = threading.Lock()
STATUS_RECEIVED = 0
STATUS_ACTIVE = 0
STATUS_PREFIX = "@@DROPSWIFT_STATUS@@ "


def emit_status(event: str, name: str = ""):
    """event: 'start' | 'done' | 'fail'. Thread-safe; flushes immediately."""
    global STATUS_RECEIVED, STATUS_ACTIVE
    with STATUS_LOCK:
        if event == "start":
            STATUS_ACTIVE += 1
        elif event == "done":
            STATUS_ACTIVE = max(0, STATUS_ACTIVE - 1)
            STATUS_RECEIVED += 1
        elif event == "fail":
            STATUS_ACTIVE = max(0, STATUS_ACTIVE - 1)
        payload = {"event": event, "name": name,
                   "active": STATUS_ACTIVE, "received": STATUS_RECEIVED}
        try:
            sys.stdout.write(STATUS_PREFIX + json.dumps(payload) + "\n")
            sys.stdout.flush()
        except Exception:
            pass


def new_code() -> str:
    return "".join(secrets.choice("0123456789") for _ in range(6))


# Where a machine-generated access code is remembered between runs, so a
# console-only launch (the Windows .exe, or `python3 server.py` on any
# platform) keeps the same code across restarts instead of forcing the phone
# to be re-paired every time. The Mac app manages its own code (in
# UserDefaults) and always passes --code explicitly, so it doesn't rely on
# this file, but writes through to it too for consistency.
CODE_FILE = os.path.join(os.path.expanduser("~"), ".dropswift", "access_code.txt")


def load_persisted_code() -> str:
    try:
        with open(CODE_FILE, "r") as f:
            code = f.read().strip()
        return code if len(code) == 6 and code.isdigit() else ""
    except OSError:
        return ""


def save_persisted_code(code: str):
    try:
        os.makedirs(os.path.dirname(CODE_FILE), exist_ok=True)
        with open(CODE_FILE, "w") as f:
            f.write(code)
    except OSError:
        pass


# Mirrors everything printed at startup into a file, since a console-less
# launch has nowhere else for it to go: Windows Task Scheduler runs the
# autostart entry via pythonw.exe with no console attached, so a plain
# print() is invisible (and, with no valid stdout handle, can even raise).
# This is the only place someone can find their access code after a logon-
# triggered start. macOS's launchd path already redirects stdout to its own
# log file, so this is a redundant-but-harmless second copy there.
LOG_FILE = os.path.join(os.path.expanduser("~"), ".dropswift", "server.log")


def log(msg: str = ""):
    try:
        print(msg)
    except Exception:
        pass
    try:
        os.makedirs(os.path.dirname(LOG_FILE), exist_ok=True)
        with open(LOG_FILE, "a", encoding="utf-8") as f:
            f.write(msg + "\n")
    except OSError:
        pass


def pairing_qr_text(ip: str, port: int, code: str):
    """Returns a scannable ASCII QR code for the same dropswift://pair link the
    Mac app renders as an image, so console-only launches (Windows, or a
    manual `python3 server.py`) can also be paired by scanning instead of
    typing the code. Returns None if the optional `qrcode` package isn't
    installed."""
    try:
        import qrcode
    except ImportError:
        return None
    url = "dropswift://pair?host=%s&port=%d&code=%s" % (ip, port, code)
    try:
        qr = qrcode.QRCode(border=1)
        qr.add_data(url)
        qr.make(fit=True)
        buf = io.StringIO()
        qr.print_ascii(out=buf, tty=False)
        return buf.getvalue()
    except Exception:
        return None


def prevent_sleep_windows():
    """Keep a Windows PC from idle-sleeping while the server runs, mirroring
    the Mac app's beginActivity call, so a long/overnight transfer doesn't get
    dropped when the laptop suspends. No-op on other platforms."""
    if sys.platform != "win32":
        return
    try:
        import ctypes
        ES_CONTINUOUS = 0x80000000
        ES_SYSTEM_REQUIRED = 0x00000001
        ctypes.windll.kernel32.SetThreadExecutionState(ES_CONTINUOUS | ES_SYSTEM_REQUIRED)
    except Exception:
        pass


def _instance_name() -> str:
    host = socket.gethostname().split(".")[0]
    return "DropSwift on %s" % host


def advertise(port: int):
    """Announce this server on the local Wi-Fi network via Bonjour/mDNS so the
    iPhone app can auto-discover it with no IP/port typing.

    Tries the cross-platform `zeroconf` library first (works on Windows, macOS
    and Linux); falls back to macOS's built-in `dns-sd`. Returns a short label
    describing which method is active, or None if neither is available.
    """
    # 1) zeroconf — cross-platform (pip install zeroconf)
    try:
        from zeroconf import Zeroconf, ServiceInfo

        ip = lan_ip()
        host = socket.gethostname().split(".")[0]
        info = ServiceInfo(
            type_="%s.local." % SERVICE_TYPE,
            name="%s.%s.local." % (_instance_name(), SERVICE_TYPE),
            addresses=[socket.inet_aton(ip)],
            port=port,
            server="%s.local." % host,
            properties={},
        )
        zc = Zeroconf()
        zc.register_service(info)
        atexit.register(lambda: (zc.unregister_service(info), zc.close()))
        return "zeroconf"
    except ImportError:
        pass
    except Exception:
        pass

    # 2) dns-sd — macOS only, no install needed
    if shutil.which("dns-sd") is not None:
        try:
            proc = subprocess.Popen(
                ["dns-sd", "-R", _instance_name(), SERVICE_TYPE, "local", str(port)],
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
            )
            atexit.register(lambda: proc.terminate())
            return "dns-sd"
        except Exception:
            pass

    return None


def lan_ip() -> str:
    """Best-effort detection of this machine's LAN IP address."""
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        # No packets are actually sent; this just picks the right interface.
        s.connect(("8.8.8.8", 80))
        return s.getsockname()[0]
    except Exception:
        return "127.0.0.1"
    finally:
        s.close()


def open_unique(dest_dir: str, filename: str):
    """Atomically create a brand-new file under `dest_dir`, appending ' (1)',
    ' (2)', … before the extension if the name is taken.

    Using O_CREAT|O_EXCL makes the name allocation race-free: when several
    uploads with the SAME filename arrive at once (parallel transfer), each one
    still gets its own distinct file instead of two threads opening — and
    corrupting — the same path. Returns (open_fd, final_path)."""
    base, ext = os.path.splitext(filename)
    candidate = filename
    i = 0
    while True:
        path = os.path.join(dest_dir, candidate)
        try:
            fd = os.open(path, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o644)
            return fd, path
        except FileExistsError:
            i += 1
            candidate = "%s (%d)%s" % (base, i, ext)


def safe_join(root: str, rel: str) -> str:
    """Resolve `rel` under `root`, refusing to escape the shared folder."""
    rel = rel.lstrip("/")
    target = os.path.realpath(os.path.join(root, rel))
    root = os.path.realpath(root)
    if target != root and not target.startswith(root + os.sep):
        raise PermissionError("path escapes shared folder")
    return target


class Handler(BaseHTTPRequestHandler):
    server_version = "DropSwift/1.0"
    protocol_version = "HTTP/1.1"   # keep-alive + better range streaming
    timeout = 300                   # drop a stalled connection instead of hanging a thread

    # ---- helpers ---------------------------------------------------------
    def _send_json(self, obj, status=200):
        body = json.dumps(obj).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _query(self):
        parsed = urllib.parse.urlparse(self.path)
        params = urllib.parse.parse_qs(parsed.query)
        return parsed.path, {k: v[0] for k, v in params.items()}

    def log_message(self, fmt, *args):
        sys.stderr.write("  %s - %s\n" % (self.address_string(), fmt % args))

    def _authed(self) -> bool:
        token = self.headers.get("X-Auth-Token", "")
        if not token:
            return False
        with TOKENS_LOCK:
            return token in TOKENS

    def _unauthorized(self):
        self._send_json({"error": "unauthorized"}, 401)

    # ---- routing ---------------------------------------------------------
    def do_GET(self):
        path, q = self._query()
        try:
            # Health is open (discovery); everything else needs a valid token.
            if path == "/" or path == "/api/health":
                self._send_json({"status": "ok", "name": socket.gethostname(),
                                 "auth": True, "root": SHARE_ROOT})
            elif path == "/api/ping":
                if not self._authed():
                    return self._unauthorized()
                # `root` lets the phone notice when the shared folder is switched
                # (the Mac restarts us with a new --dir) and auto-refresh Browse.
                self._send_json({"ok": True, "root": SHARE_ROOT})
            elif path == "/api/list":
                if not self._authed():
                    return self._unauthorized()
                self._list(q.get("path", ""))
            elif path == "/api/download":
                if not self._authed():
                    return self._unauthorized()
                self._download(q.get("path", ""))
            else:
                self._send_json({"error": "not found"}, 404)
        except PermissionError as e:
            self._send_json({"error": str(e)}, 403)
        except FileNotFoundError:
            self._send_json({"error": "not found"}, 404)
        except Exception as e:  # pragma: no cover - defensive
            self._send_json({"error": str(e)}, 500)

    def do_POST(self):
        path, q = self._query()
        try:
            if path == "/api/auth":
                self._auth()
            elif path == "/api/upload":
                if not self._authed():
                    return self._unauthorized()
                self._upload(q.get("path", ""))
            else:
                self._send_json({"error": "not found"}, 404)
        except PermissionError as e:
            self._send_json({"error": str(e)}, 403)
        except Exception as e:  # pragma: no cover - defensive
            self._send_json({"error": str(e)}, 500)

    def _auth(self):
        length = int(self.headers.get("Content-Length", 0))
        raw = self.rfile.read(length) if length > 0 else b""
        try:
            code = str(json.loads(raw.decode("utf-8")).get("code", ""))
        except Exception:
            code = ""
        if code and ACCESS_CODE and secrets.compare_digest(code, ACCESS_CODE):
            token = secrets.token_urlsafe(24)
            with TOKENS_LOCK:
                TOKENS.add(token)
            self._send_json({"ok": True, "token": token, "name": socket.gethostname()})
        else:
            time.sleep(1.0)   # slow down brute-force guessing
            self._send_json({"ok": False, "error": "invalid code"}, 401)

    # ---- endpoints -------------------------------------------------------
    def _list(self, rel):
        target = safe_join(SHARE_ROOT, rel)
        if not os.path.isdir(target):
            raise FileNotFoundError
        items = []
        for name in sorted(os.listdir(target)):
            if name.startswith("."):
                continue  # hide dotfiles
            full = os.path.join(target, name)
            is_dir = os.path.isdir(full)
            items.append({
                "name": name,
                "isDir": is_dir,
                "size": 0 if is_dir else os.path.getsize(full),
            })
        self._send_json({"path": rel, "items": items})

    def _download(self, rel):
        target = safe_join(SHARE_ROOT, rel)
        if not os.path.isfile(target):
            raise FileNotFoundError
        size = os.path.getsize(target)
        ctype = mimetypes.guess_type(target)[0] or "application/octet-stream"

        # Honour HTTP Range requests so video can stream/seek and image
        # thumbnails can be fetched without downloading the whole file.
        range_header = self.headers.get("Range", "")
        start, end = 0, size - 1
        partial = False
        if range_header.startswith("bytes="):
            try:
                spec = range_header.split("=", 1)[1].split(",")[0].strip()
                s, _, e = spec.partition("-")
                if s == "":
                    start = max(0, size - int(e))
                else:
                    start = int(s)
                    end = int(e) if e else size - 1
                end = min(end, size - 1)
                if start <= end:
                    partial = True
            except (ValueError, IndexError):
                partial = False

        length = end - start + 1
        try:
            if partial:
                self.send_response(206)
                self.send_header("Content-Range", "bytes %d-%d/%d" % (start, end, size))
            else:
                self.send_response(200)
                self.send_header(
                    "Content-Disposition",
                    'attachment; filename="%s"' % os.path.basename(target))
            self.send_header("Content-Type", ctype)
            self.send_header("Accept-Ranges", "bytes")
            self.send_header("Content-Length", str(length))
            self.end_headers()

            with open(target, "rb") as f:
                f.seek(start)
                remaining = length
                while remaining > 0:
                    chunk = f.read(min(64 * 1024, remaining))
                    if not chunk:
                        break
                    self.wfile.write(chunk)
                    remaining -= len(chunk)
        except (BrokenPipeError, ConnectionResetError):
            # The player/app closed the connection early; that's fine.
            return

    def _upload(self, rel):
        # The app sends the raw file bytes as the body and the desired
        # filename in the X-Filename header. Simple and robust.
        filename = self.headers.get("X-Filename", "").strip()
        if not filename:
            self._send_json({"error": "missing X-Filename header"}, 400)
            return
        filename = os.path.basename(filename)  # strip any path components
        dest_dir = safe_join(SHARE_ROOT, rel)
        os.makedirs(dest_dir, exist_ok=True)

        # Optional end-to-end integrity check: the app sends the SHA-256 of the
        # exact bytes it is uploading. We hash what we actually receive and
        # refuse to keep a file whose contents don't match — so a truncated or
        # garbled transfer is rejected (the app retries) instead of silently
        # leaving a broken file behind.
        want_hash = self.headers.get("X-Content-SHA256", "").strip().lower()

        # Allocate the destination atomically (race-free) so parallel uploads
        # sharing a filename can never write to the same path.
        fd, dest = open_unique(dest_dir, filename)

        length = int(self.headers.get("Content-Length", 0))
        written = 0
        hasher = hashlib.sha256()
        emit_status("start", filename)
        # Stream straight to disk in 1 MB chunks — constant memory even for
        # multi-gigabyte files.
        try:
            with os.fdopen(fd, "wb") as f:
                remaining = length
                while remaining > 0:
                    chunk = self.rfile.read(min(1024 * 1024, remaining))
                    if not chunk:
                        break
                    f.write(chunk)
                    hasher.update(chunk)
                    written += len(chunk)
                    remaining -= len(chunk)
        except (BrokenPipeError, ConnectionResetError, socket.timeout):
            written = -1   # connection dropped / stalled mid-upload

        size_ok = (written == length)
        hash_ok = (not want_hash) or (hasher.hexdigest() == want_hash)

        # If the upload was interrupted OR its contents don't match, discard the
        # file so a broken copy never survives.
        if not size_ok or not hash_ok:
            emit_status("fail", filename)
            try:
                os.remove(dest)
            except OSError:
                pass
            # Close this keep-alive socket: a partially-read body would otherwise
            # desync framing and could corrupt the NEXT file on the connection.
            self.close_connection = True
            reason = "incomplete upload" if not size_ok else "checksum mismatch"
            try:
                self._send_json({"ok": False, "error": reason}, 400)
            except Exception:
                pass
            return

        emit_status("done", os.path.basename(dest))
        self._send_json({"ok": True, "name": os.path.basename(dest), "bytes": written})


def default_share_dir() -> str:
    """Where to share files from by default.

    When running as a bundled .exe (PyInstaller), there's no project folder
    next to us, so default to a friendly, easy-to-find Desktop\\DropSwift.
    """
    if getattr(sys, "frozen", False):
        return os.path.join(os.path.expanduser("~"), "Desktop", "DropSwift")
    return "./shared"


def main():
    global SHARE_ROOT, ACCESS_CODE
    parser = argparse.ArgumentParser(description="DropSwift laptop server")
    parser.add_argument("--dir", default=default_share_dir(),
                        help="folder to share (default: ./shared, or Desktop/DropSwift for the app)")
    parser.add_argument("--port", type=int, default=8080, help="port (default: 8080)")
    parser.add_argument("--code", default=None,
                        help="6-digit access code (persisted + reused if omitted)")
    parser.add_argument("--new-code", action="store_true",
                        help="force a freshly generated access code instead of reusing the saved one")
    args = parser.parse_args()

    SHARE_ROOT = os.path.realpath(os.path.expanduser(args.dir))
    os.makedirs(SHARE_ROOT, exist_ok=True)

    if args.code:
        ACCESS_CODE = args.code
    elif args.new_code:
        ACCESS_CODE = new_code()
    else:
        ACCESS_CODE = load_persisted_code() or new_code()
    save_persisted_code(ACCESS_CODE)

    ip = lan_ip()
    server = ThreadingHTTPServer(("0.0.0.0", args.port), Handler)

    method = advertise(args.port)
    prevent_sleep_windows()

    # On SIGTERM (e.g. the Mac app stopping us), exit cleanly so the atexit
    # handlers run and the Bonjour service is unregistered immediately — the
    # phone then sees this computer vanish from the list right away.
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))

    # Fresh log per run — this is what a logon-triggered Windows autostart
    # (no console window) leaves behind for someone to go find.
    try:
        os.makedirs(os.path.dirname(LOG_FILE), exist_ok=True)
        open(LOG_FILE, "w").close()
    except OSError:
        pass

    log("=" * 56)
    log(" DropSwift server is running")
    log(" Sharing folder : %s" % SHARE_ROOT)
    log(" On this device : http://%s:%d" % (ip, args.port))
    log(" ACCESS CODE    : %s   (enter this in the app to connect)" % ACCESS_CODE)
    if method is not None:
        log(" Auto-discovery : ON via %s (the app finds this computer" % method)
        log("                  by itself — no IP/port typing needed)")
    else:
        log(" Auto-discovery : off — install it with 'pip install zeroconf',")
        log("                  or in the app enter Host %s, Port %d"
            % (ip, args.port))
    log(" Press Ctrl+C to stop.")
    log("=" * 56)
    log("")
    qr_text = pairing_qr_text(ip, args.port, ACCESS_CODE)
    if qr_text:
        log(qr_text)
        log(" Scan this QR code in the DropSwift app to connect instantly.")
    else:
        log(" Tip: 'pip install qrcode' to get a scannable QR code here too.")
    log("")
    log(" (This info is also saved to %s)" % LOG_FILE)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        log("\nStopping DropSwift server.")
        server.shutdown()


if __name__ == "__main__":
    try:
        main()
    except Exception as exc:  # keep the .exe console window open so errors are readable
        print("\nDropSwift server error: %s" % exc)
        if getattr(sys, "frozen", False):
            input("\nPress Enter to close...")
        raise
