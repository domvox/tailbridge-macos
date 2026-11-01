# TailBridge — operations, undo and recovery

Button and menu labels are given as the app shows them.
Requirements and the tested configuration are in the [README](../README.md#requirements-and-tested-configuration).

## Building

```
./build.sh                       # fixture tests → helper → app → icon → ad-hoc signature → BUILDINFO; installs nothing
tests/bundle-manifest-test.sh    # bundle-manifest tests, only in a temporary directory
open build/TailBridge.app        # optional: run the app straight from build/
```

- Version, build number and channel are set only in `version.conf`. The build number is increased by hand.
- `build/BUILDINFO.txt` records the version, commit, an uncommitted-changes flag, the toolchain, the CDHash, SHA-256 sums (executable, helper, icon, `Info.plist`) and the bundle-manifest hash. It sits next to the bundle and is not signed.
- The manifest (`tools/bundle-manifest.sh`) covers the paths and modes of directories and files, and the SHA-256 of files. It does **not** cover extended attributes, ACLs, owner or timestamps, so a matching manifest does not mean a byte-identical bundle. An unreadable file or directory, a symlink, a special file, or a name with a control character makes the manifest fail, and with it the build.
- The signature is ad hoc only: no Developer ID and no notarization. It does not identify the publisher. **TailBridge → About TailBridge** shows the version, channel, build, commit and signature type, read from the signed `Info.plist`.

At launch the app only reads state: `mullvad status`, `mullvad lockdown-mode get`, `mullvad dns get`, `tailscale status --json --peers=false`, `launchctl print`, `/etc/resolver` and `status.json`.
The device list for Test Connection comes from `tailscale status --json`, read inside the app's process. Only the name, IPv4 address and online state are kept. The list is never logged or saved. Only the selected test target is saved, just as when you type it in (see [PRIVACY.md](../PRIVACY.md)).

## App only and helper: two separate installs

| | App (`TailBridge.app`) | Helper (`com.tailbridge.helper`) |
|---|---|---|
| Installed by | copying the bundle by hand (below) | **Administration → Install Helper…** in the app, with an administrator prompt |
| Runs as | your user | root, as a LaunchDaemon |
| Location | `/Applications/TailBridge.app`, or `build/TailBridge.app` | `/Library/PrivilegedHelperTools/com.tailbridge.helper` and `/Library/LaunchDaemons/com.tailbridge.helper.plist` |
| Changes the network | no, until you click Enable or Disable | only on Enable/Disable, and the monitor removes stale items |

Copying, replacing or removing the app never installs, updates, restarts or removes the helper. Quitting the app does not disable TailBridge.

## Copying the app into /Applications

There is no installer script. Copying a clean app into `/Applications` and launching it were observed on one development Mac. Two consecutive updates and rollback were only simulated in temporary directories; the full update/rollback path remains unverified.

1. Run `./build.sh` and check `build/BUILDINFO.txt`: version, build, commit and `uncommitted_changes`. For a preview, build from a committed tree (`uncommitted_changes=no`).
2. Quit the running copy: **TailBridge → Quit TailBridge**. Make sure nothing is running: `pgrep -lf 'TailBridge.app/Contents/MacOS/TailBridge'` prints nothing.
3. If `/Applications/TailBridge.app` already exists, move it into a new, empty folder. The name is always new, so the copy cannot end up inside an earlier one:
   ```
   BK=$(mktemp -d ~/TailBridge-previous.XXXXXX) && mv /Applications/TailBridge.app "$BK/" && echo "$BK"
   ```
   Write down the printed path.
4. Make sure `/Applications/TailBridge.app` does not exist (`ls -d /Applications/TailBridge.app` reports that it is missing). Only then run:
   ```
   ditto build/TailBridge.app /Applications/TailBridge.app
   ```
   Never copy onto an existing bundle: `ditto` would merge the old and new contents.
5. Launch it from the Finder or the Dock. Check the icon and **TailBridge → About TailBridge** (version, channel, build, commit).
6. If you also want the helper from this build, install it separately: **Administration → Install Helper…**. The prompt shows the first 16 characters of the helper's SHA-256. Check that they match the start of `sha256_helper` in `build/BUILDINFO.txt`. The full digest is in the app's log window (Show Log).

Limitation: the steps check that the name is free before `mv`/`ditto`, but something created at that path in between could still be nested or merged.

A copy you download instead of building yourself would carry the quarantine attribute. Gatekeeper behavior for such an ad-hoc-signed copy has **not been tested**. Build from source.

## Rolling back the app

1. Quit the app.
2. Move the current copy away exactly as in step 3 above (into a new folder from `mktemp -d`).
3. Check that `/Applications/TailBridge.app` does not exist.
4. Only then move the previous copy back:
   ```
   mv "<saved path>/TailBridge.app" /Applications/TailBridge.app
   ```
   If the name in `/Applications` were taken, `mv` would put the copy inside it.

Rolling back the app does not roll back the helper. To match them, install the helper again from the restored app.
The `~/TailBridge-previous.*` folders are never removed automatically.

## First use

1. **Administration → Install Helper…** — see step 6 above.
   - Reinstalling restarts the monitor.
   - The network is not changed.
2. **Enable** — requires Mullvad connected, Tailscale running and the monitor running. If there was no env file, the app creates it and asks you to restart Tailscale. Then, in an administrator prompt, the helper:
   - loads the `com.apple/tailbridge` anchor and verifies it exactly;
   - creates the resolver;
   - **adopts the prototype**: the `codex` resolver and `/var/run/codex-vpn-coexist` are moved to backups, and the broad `com.apple/codex-vpn-coexist` rules are removed. This applies only to exactly recognized content.
3. **Test Connection** — choose a device from the list or enter a target under Advanced. It is only the test target: Enable and Disable always apply to this Mac's own interface and addresses, and the exception covers the whole tailnet.

## Disable

Removes the `com.apple/tailbridge` anchor, the resolver with TailBridge's exact content, and recognized prototype items (rules and resolver, with backups).
The env file is moved to `~/Library/Application Support/TailBridge/backups/` and stops applying after Tailscale restarts.
It does **not** run `mullvad connect/disconnect` and does not change Mullvad settings.
Shared files whose content was changed by hand (the env file, resolvers, prototype items) are left untouched and reported. TailBridge's own state files in `/Library/Application Support/TailBridge/` (such as `enabled.json` and `anchor.rules`) are removed without content checks.

## Backups

- root: `/Library/Application Support/TailBridge/backups/` (700)
- user: `~/Library/Application Support/TailBridge/backups/` (700)
- previous app copies: `~/TailBridge-previous.*` (only if you followed the copy steps above)

Restoring the prototype (only deliberately): copy the file from the backup back, e.g. `sudo cp <backup> /etc/resolver/<domain>`.

## Manual recovery (when the app does not work)

Each command affects only TailBridge or prototype items:

```
sudo /Library/PrivilegedHelperTools/com.tailbridge.helper disable     # full disable, verified
sudo /Library/PrivilegedHelperTools/com.tailbridge.helper status      # state as JSON
sudo /sbin/pfctl -a com.apple/tailbridge -F rules                     # emergency: TailBridge anchor only
sudo /sbin/pfctl -a com.apple/tailbridge -sr                          # should print nothing
sudo /sbin/pfctl -a com.apple/codex-vpn-coexist -F rules              # emergency: prototype anchor
```

Remove a resolver by hand only after checking its content: `cat /etc/resolver/<domain>`. The TailBridge resolver starts with `# TailBridge managed resolver v1`.
TailBridge's env file is `~/Library/Containers/io.tailscale.ipn.macos.network-extension/Data/tailscaled-env.txt`. If the app does not work, move it out of the container and restart Tailscale.

Do not use `pfctl -f /etc/pf.conf`, `pfctl -d` or `pfctl -F all`. They change Mullvad's and the system's rules, not just TailBridge's.

## Removal

Helper uninstall has **not been tested live**.

1. **Disable** in the app. Only this step moves the env file out of the Tailscale container. Then restart Tailscale.
2. **Administration → Uninstall Helper…** or `sudo /Library/PrivilegedHelperTools/com.tailbridge.helper uninstall`.
   - The command first removes the exception and the resolver. If that fails, it stops and leaves the monitor running.
   - Then it runs `launchctl bootout` and removes the plist (only with its exact content), `status.json`, `anchor.rules` and the helper binary.
   - A resolver whose content is not exactly TailBridge's (for example, edited by hand) is left in place. The command names it and exits with code 2 (uninstalled, with unrecognized items left), and the app shows a warning. Earlier development helpers reported plain success instead; see [Development history](#development-history-and-current-behavior).
3. Quit the app and move `/Applications/TailBridge.app` (or the `build/` folder) to the Trash.

These stay on disk and are not removed automatically:

| Path | Content |
|---|---|
| `/Library/Application Support/TailBridge/backups/` | prototype resolver and state backups (root, 700) |
| `/Library/Application Support/TailBridge/uninstalled`, `.lock` | marker that refuses late Enable requests, and the lock file |
| `/Library/Logs/TailBridge-helper.log` | helper log |
| `~/Library/Application Support/TailBridge/backups/` | moved env files |
| `~/Library/Preferences/local.tailbridge.app.plist` | last test target (IPv4, MagicDNS name, port) |
| `~/TailBridge-previous.*` | previous app copies, if you made any |
| `/etc/resolver/<tailnet>.ts.net` | only if its content was changed, so TailBridge no longer recognized it |

Look at these files before deleting them. Prototype backups may be the only copy of its state.
Moving them to the Trash is safer than deleting them. Installing the helper again removes the `uninstalled` marker.

## Monitor — what it guarantees and what it does not

- Every 5 s it compares the saved identity (utun, index, IPv4, IPv6, UP/RUNNING, address uniqueness) with `getifaddrs`, and the anchor's exact content with `pfctl`.
- On any mismatch it removes the exception and the resolver. **It never turns anything on by itself.** After a reboot, a PF reload or a Tailscale restart, you have to click Enable again.
- Delay: up to ~5 s plus `pfctl` time, which has no upper bound (next point). The monitor does not run during sleep; its first cycle runs after wake.
- Each `pfctl` call gets 15 s. Then the helper sends SIGTERM, then SIGKILL 2 s later, and waits **without an upper bound** until the process has exited, so that a PF change never overlaps a rollback or the next change. A `pfctl` that does not exit even after SIGKILL (for example, stuck in the kernel) holds the helper's lock until it does. Until then the monitor, cleanup, `status.json` updates and every helper command that needs the lock (Enable, Disable, `status`, uninstall) wait. Once `status.json` is more than 15 s old, the app shows **Status Unknown**. This follows from the code; it has **not been observed live**.
- It assumes that stopping Tailscale removes its utun or addresses. **NOT VERIFIED live.**
- Log: `/Library/Logs/TailBridge-helper.log` (entries only on events).

## Development history and current behavior

Earlier development versions had weaker status/verdict checks and incomplete uninstall reporting. This source snapshot includes the corrections described below. A development build with these runtime sources was installed on one Mac; full lifecycle and failure coverage remain unverified. See [acceptance evidence](ACCEPTANCE.txt).

- **Green "TailBridge Is On" headline:** shown only while the helper recently confirmed TailBridge's own exception and resolver for the current Tailscale interface, Mullvad is reported as connected and Tailscale as running. If the exception is in place but Mullvad is not reported as connected or Tailscale is not running, the app shows "TailBridge Needs Attention". The headline still does not prove that your devices are reachable or that nothing leaks; run Test Connection.
  - Before: green from TailBridge's own exception alone, with a text saying that devices are reachable and other traffic goes through Mullvad.
- **Test Connection:** "MagicDNS name (direct)", "Tailscale route" and "Tailscale ping (TSMP)" show Passed only after the command ends cleanly with a valid answer. A route through a DERP relay stays Info.
  - Before: Passed was possible from output printed by a command that then failed, timed out or had its output cut off.
- **Uninstall with a changed resolver:** see [Removal](#removal) (exit code 2 and a warning).
  - Before: plain success, exit code 0, "Helper uninstalled."
- **Waiting for `pfctl`:** unchanged behavior, now documented in the code. See the [Monitor](#monitor--what-it-guarantees-and-what-it-does-not) section.

## Known limitations

- `TS_BIND_TO_INTERFACE_BY_ROUTE` is an internal Tailscale option. Check that it still works after each Tailscale update.
- The exception lets inbound PF traffic from the whole tailnet reach this Mac's Tailscale address. Tailscale ACLs restrict it.
- The way `pfctl` prints the rules (no `flags` token for `flags any no state`) was confirmed live on 2026-10-31 on macOS 27.2. If a system update changes it, `enable` rolls back with an "anchor differs after loading" error.
- A limited controlled DNS sample and blocked IPv4 TCP observation are recorded in [acceptance evidence](ACCEPTANCE.txt). Actual tunnel failure, IPv6 protection, all DNS/protocol behavior, sleep, network changes and reboots remain **NOT VERIFIED**.
- A limited Lockdown-on sample was recorded, with an automated Inconclusive result. It is not a full kill-switch test. TailBridge does not change Mullvad lockdown settings.
