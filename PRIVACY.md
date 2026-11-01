# Privacy

TailBridge works only locally. It has no accounts, telemetry, crash reporting, update checks or server of its own.
This description is based on the runtime code in this source snapshot. It is not an external audit. The limited development observations in [docs/ACCEPTANCE.txt](docs/ACCEPTANCE.txt) include a separate controlled DNS capture; they do not verify all app traffic. Raw captures and runtime logs remain private and are not part of the source preview.

## Network requests

Launching the app, Refresh, Run Diagnostics and the About panel make no internet requests. Building with `./build.sh` makes none either. They read state locally: the Mullvad and Tailscale CLIs, `launchctl`, `getifaddrs` and files.

Network traffic happens **only when you click Test Connection**:

| Check | Destination | What it reveals |
|---|---|---|
| Public IPv4 / IPv6 | `https://ipv4.am.i.mullvad.net/json` and `https://ipv6.am.i.mullvad.net/json` (a Mullvad service), via `/usr/bin/curl` with no proxy and no `~/.curlrc` | Mullvad sees the public address the request came from, and when. If traffic leaves outside Mullvad, Mullvad sees your real IP address. |
| MagicDNS name (macOS) | the system resolver, for `<device>.<tailnet>.ts.net` | Without an active TailBridge resolver, the query may go to the DNS server macOS is using, such as Mullvad's. That server then sees the device and tailnet names. |
| MagicDNS name (direct) | `dig @100.100.100.100` | a query to Tailscale's local resolver |
| Ping, TCP, Tailscale route, TSMP | the selected tailnet device | The TCP check only opens and closes a connection, without logging in. The target device may log the connection attempt. |

The public IP address returned by the service is not shown or saved. Only the Mullvad exit server name is shown, if the service returns one.

The root helper makes no network requests. It runs only `pfctl`, `dscacheutil`, `killall` and `launchctl`.

## Data stored locally

| Path | Owner / mode | Content |
|---|---|---|
| `~/Library/Preferences/local.tailbridge.app.plist` | user | last test target: device IPv4, MagicDNS name, TCP port |
| `~/Library/Containers/io.tailscale.ipn.macos.network-extension/Data/tailscaled-env.txt` | user, 600 | fixed content `TS_BIND_TO_INTERFACE_BY_ROUTE=1`, no personal data |
| `~/Library/Application Support/TailBridge/backups/` | user, 700 | env files moved on Disable |
| `/Library/Application Support/TailBridge/enabled.json`, `status.json`, `anchor.rules`, `cleanup-required.json` | root, **644** | interface name and index, this Mac's Tailscale IPv4/IPv6 addresses, **tailnet name**, PF and resolver state, last event |
| `/Library/Application Support/TailBridge/backups/` | root, 700 | prototype resolver and state backups |
| `/etc/resolver/<tailnet>.ts.net` | root | the tailnet name (in the file name) and `100.100.100.100` |
| `/Library/Logs/TailBridge-helper.log` | root; mode not checked | timestamps, interface names, resolver paths with the **tailnet name**, backup paths, error messages |
| `~/TailBridge-previous.*` | user | previous app copies, only if you followed the manual copy steps in [docs/OPERATIONS.md](docs/OPERATIONS.md#copying-the-app-into-applications) |

Build outputs (`build/`, ignored by Git):

| Path | Content |
|---|---|
| `build/BUILDINFO.txt` | version, build, channel, full commit hash, uncommitted-changes flag, build time (UTC), Swift and SDK versions, the Xcode path (`xcode-select -p`), the build host's macOS version, build number and architecture, CDHash and SHA-256 sums |
| `build/TailBridge.app/Contents/Info.plist` | version, build, channel, full commit hash, uncommitted-changes flag, signature type; shown in the About panel |

The Xcode path in `BUILDINFO.txt` can contain your account name if Xcode is installed under your home folder. Check the file before you publish it.

Files with mode 644 and the helper log can be read by **other local accounts** on this Mac. They reveal the tailnet name and this Mac's Tailscale addresses.
The helper log is not rotated. Entries are written only on events.

Uninstalling the helper does not remove backups, the log or preferences (see [docs/OPERATIONS.md](docs/OPERATIONS.md#removal)).

The tailnet device list for Test Connection is kept only in memory. It is never logged or saved.
The app's log window is also kept only in memory, until the app quits. Its Copy All button puts the content on the clipboard.

## What logs and screenshots can reveal

Review the content before you share anything publicly, for example in a GitHub issue. This applies to:

- **Run Diagnostics output and the log window:**
  - macOS, Tailscale and Mullvad versions;
  - Mullvad lockdown state;
  - this Mac's Tailscale IPv4 and IPv6 addresses;
  - the **tailnet name**;
  - the env file path, which contains your **macOS account name** (`/Users/<account>/…`);
  - recent helper events;
- **Test Connection results:** the target device's address and name, the full MagicDNS name including the tailnet name, and the Mullvad server name (which indicates country and city);
- **screenshots of the window:** the tailnet device list (names, addresses, online state), everything above, and warnings about the Mullvad configuration;
- **`/Library/Logs/TailBridge-helper.log` and `status.json`:** the tailnet name, addresses and paths;
- **`BUILDINFO.txt`:** the build time, the Xcode path and the build host's macOS version;
- **macOS crash reports** (`~/Library/Logs/DiagnosticReports/`), which may contain paths with your account name.

A tailnet name (`tailXXXX.ts.net` or a custom one) together with device names can help identify a person or an organization. Replace them with placeholders such as `example-tail.ts.net`, `100.64.0.1` and `example-user`.

Do not paste keys, tokens, your Mullvad account number, Mullvad's `settings.json`, full `tailscale status --json` output, or screenshots of the Tailscale admin console into issues.
