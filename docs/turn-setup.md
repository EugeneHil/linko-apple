# TURN (coturn) on the Windows VPS — runbook

Proven during the LNK-3 spike (findings: `docs/adr/0001-webrtc-callkit-turn-spike.md`). Everything runs on the VPS in PowerShell unless noted. The shared secret never leaves the VPS; `<vps-ip>` below is the VPS public address.

The scripts referenced here live on the `spike/LNK-3-webrtc-callkit` branch of this repository: `Spike/turn/setup-turn.ps1`, `Spike/turn/turn-cred.ps1`, `Spike/relay/relay.ps1`.

## 1. Build coturn (native, MSVC)

- Build coturn from source with CMake + MSVC using a dedicated vcpkg instance for dependencies; disable PostgreSQL support (not needed for `use-auth-secret`).
- Working dependency set from the spike build, all DLLs next to `turnserver.exe`: `event_core.dll`, `event_extra.dll`, `event_openssl.dll`, `libcrypto-3-x64.dll`, `libssl-3-x64.dll`, `libmicrohttpd-dll.dll`, `sqlite3.dll`, `pthreadVC3.dll`. The build also produces `turnutils_uclient.exe`.
- Keep one folder with `turnserver.exe`, the DLLs and the two scripts from `Spike/turn/`.

## 2. Configure and start — `setup-turn.ps1`

```
powershell -ExecutionPolicy Bypass -File setup-turn.ps1 -PublicIp <vps-ip>
```

What it does:

- First run generates `turnserver.conf` with a 32-byte hex secret from a CSPRNG (hex, not Base64: no look-alike characters for the config parser). Reruns keep the existing secret. The config gets an owner-only ACL (Administrators and SYSTEM). This secret is the single source of truth: copy the same hex into the linko-server config's `turnSecret` (`linko-server/docs/deploy.md` §3) — copy-paste only, never retype.
- Opens Windows Firewall rules: UDP 3478, TCP 3478, UDP 49160–49200 (inbound).
- Starts `turnserver.exe` hidden. coturn on Windows does not resolve a drive-letter absolute path after `-c`, so the script passes the config name relative to the working directory.

**No Windows service in v0.1.** `setup-turn.ps1` starts `turnserver.exe` inside the current RDP/SSH session and nothing registers it as a Windows service, so coturn dies when that session closes (the spike deliberately skipped persistence). Keep the session open for the whole scenario window and check `tasklist | findstr turnserver` before relying on TURN. Registering a proper `LinkoTurn` service (spec §8's "server and TURN registered as Windows services") is roadmap, not done here.

Generated config (the options that mattered):

```
listening-port=3478
listening-ip=<vps-ip>
relay-ip=<vps-ip>
external-ip=<vps-ip>
min-port=49160
max-port=49200
realm=linko
use-auth-secret
static-auth-secret=<generated on the VPS, never printed>
fingerprint
no-tls
no-cli
no-multicast-peers
denied-peer-ip=10.0.0.0-10.255.255.255
denied-peer-ip=172.16.0.0-172.31.255.255
denied-peer-ip=192.168.0.0-192.168.255.255
denied-peer-ip=169.254.0.0-169.254.255.255
log-file=<dir>\turn.log
simple-log
```

## 3. Issue short-lived credentials — `turn-cred.ps1`

```
powershell -ExecutionPolicy Bypass -File turn-cred.ps1 | Set-Clipboard
```

REST scheme, valid 1 h: `username = <unix-expiry>:spike`, `credential = base64(hmac_sha1(secret, username))`. The script reads the secret from the local config and prints only the resulting pair. Paste over RDP; never retype — Base64 look-alikes (`I/l`, `0/O`) silently break the HMAC.

## 4. Point the clients

- TURN URL of the form `turn:<vps-ip>:3478`; a URL without `?transport=` is applied twice (UDP and TCP); an explicit transport is used as given.
- Relay-only diagnostics mode: `iceTransportPolicy = .relay` and no public STUN servers.
- In the spike the Mac forwarded the credentials to the iPhone over signaling; the product server issues them itself.

## 5. Verify

- On the VPS (or from the Mac with Homebrew `coturn`): `turnutils_uclient -u <username> -w <credential> -y <vps-ip>` — allocations must succeed.
- Call iPhone on LTE (Wi-Fi off) to Mac on Wi-Fi in relay-only mode: the app stats overlay must show a selected `relay` pair.
- With relay-only off on MTS LTE the call went direct (`pair host`, RTT ~1 ms, ~226 kbps outgoing at 320x240 on the Mac) — TURN is the fallback path, not a requirement.
- Server log: `turn.log` next to the binary.

## 6. Teardown and security

- The signaling relay (`relay.ps1`, port 9000) is spike-only: stop it and close port 9000 after testing. coturn keeps running only inside the session that started it — it is not registered as a Windows service in v0.1 (see §2).
- `turnserver.conf` holds the shared secret: owner-only ACL, never copied off the VPS, never committed.
- `no-tls` was acceptable for the spike; revisit TLS for the product.
