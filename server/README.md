# DropSwift — laptop server

This is the computer side of DropSwift. It shares one folder over your local
Wi‑Fi so the DropSwift iPhone app can browse/download files and receive photos.

## Easiest: install auto-start (recommended)

Run this **once** so the server starts automatically at every login and the app
finds your Mac by itself — no typing IPs, no running scripts:

```bash
cd server
./install-autostart.command      # or double-click it in Finder
```

This shares `~/Desktop/DropSwift` on port 8080 and keeps the server running in the
background. To undo it: `./uninstall-autostart.command`.

## Or run it manually

```bash
cd server
python3 server.py                       # shares ./shared on port 8080
# or pick your own folder / port:
python3 server.py --dir ~/Desktop/DropSwift --port 8080
```

## On Windows

The server is cross-platform. On a Windows PC:

```bat
pip install -r requirements.txt
```

Then either:
- **Run manually:** double-click `start-windows.bat`, or
- **Auto-start at logon:** double-click `install-autostart-windows.bat` (once).
  Remove it later with `uninstall-autostart-windows.bat`.

Files land in `Desktop\DropSwift`. The PC then shows up in the app automatically,
exactly like a Mac. If the app can't connect, allow Python through **Windows
Defender Firewall** for **Private networks** when prompted.

> Auto-discovery on Windows requires the `zeroconf` package (installed by the
> commands above). The Windows scripts install it for you.

Windows has no GUI app (the Mac's "DropSwift Server.app" is Mac-only), but the
console/log output gives you the same pairing experience:
- The access code is generated once and **reused across restarts** (saved to
  `%USERPROFILE%\.dropswift\access_code.txt`) instead of changing every launch.
- A scannable **QR code** (same `dropswift://pair` link the Mac app shows as an
  image) is printed alongside it — scan it in the app instead of typing the code.
- Because `install-autostart-windows.bat` runs with no visible console, all of
  this — access code, IP/port, QR code — is written to
  `%USERPROFILE%\.dropswift\server.log` on every start; the installer opens it
  in Notepad for you the first time.
- The PC is also kept from idle-sleeping while the server runs, so an overnight
  transfer isn't dropped (closing the lid can still sleep it — that's a separate
  Windows power setting).

## Auto-discovery (Bonjour)

The server announces itself on the local network via Bonjour (`_dropswift._tcp`),
so the iPhone app lists it automatically under "Computers on this Wi‑Fi" — just tap
to connect. Manual Host/Port entry is still available in the app as a fallback.

On startup it prints something like:

```
 On this device : http://192.168.1.5:8080
 In the app, enter ->  Host: 192.168.1.5   Port: 8080
```

Type that **Host** and **Port** into the app's **Connect** tab.

> Phone and laptop must be on the **same Wi‑Fi / router**.
> If it won't connect, allow `python` through the macOS firewall
> (System Settings → Network → Firewall), or temporarily turn the firewall off.

## What the app can do
- **Browse** the shared folder and download any file to the phone (saved via the share sheet → Files/Photos).
- **Send** photos and videos from the phone into the shared folder.

## HTTP API (for reference)
| Method | Path | Purpose |
|---|---|---|
| GET | `/api/health` | connection check |
| GET | `/api/list?path=<rel>` | list a folder (JSON) |
| GET | `/api/download?path=<rel>` | download a file |
| POST | `/api/upload?path=<rel>` | upload (raw body, `X-Filename` header) |

All paths are restricted to the shared folder; requests that try to escape it are rejected.
