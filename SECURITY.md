# Security

TailBridge is an **experimental preview**. It changes PF firewall rules and a DNS resolver with root privileges.
The development code received AI-assisted review and fixture testing. It has not received an independent human security audit; historical AI review reports are not included in this snapshot.
It does not guarantee that traffic or DNS will not leak, and it is not a replacement for Mullvad's kill switch.

## Supported versions

There are no releases. Fixes go only to the `main` branch. Older commits and branches are not patched.

## Reporting a vulnerability

Report vulnerabilities privately through [GitHub Private Vulnerability Reporting](https://github.com/domvox/tailbridge-macos/security/advisories/new). The channel is enabled; a GitHub sign-in is required.

Do not post vulnerability details in public issues. Do not include the data described in [PRIVACY.md](PRIVACY.md#what-logs-and-screenshots-can-reveal).

## Scope

In scope:

- privilege escalation through the `com.tailbridge.helper` helper or its installation;
- PF rules broader than those described in [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md);
- an exception or resolver left behind after an interface change, Disable or uninstall;
- bypassing input validation or the ownership, symlink and ACL checks;
- data exposed in files or logs beyond what [PRIVACY.md](PRIVACY.md) describes.

Out of scope:

- bugs in Mullvad, Tailscale or macOS (report them to their vendors);
- historical prototype scripts, which are not distributed in this snapshot.

## Design and assumptions

- **The root helper has a fixed set of commands:** `enable`, `disable`, `status`, `watch`, `install-daemon`, `uninstall`. It does not run arbitrary commands.
  - It runs only `/sbin/pfctl`, `/usr/bin/dscacheutil`, `/usr/bin/killall` and `/bin/launchctl`, with a fixed `PATH`.
  - Arguments are validated in the app and again in the helper.
- **Helper installation:**
  - the binary is copied to a temporary file owned by root;
  - its SHA-256 is checked on that copy;
  - it is set to `root:wheel 755` and moved into place atomically;
  - the owner, mode and ACLs of the parent directories are checked.
- **Administrator rights** are obtained with `osascript … with administrator privileges`, separately for each operation.
  - `SMAppService` and a signed XPC service are not used.
  - The helper requires an effective UID of 0, but does not check which process called it. Anyone with administrator rights can run it, for example with `sudo`.
- **Cleanup and rollback, within limits:**
  - `enable` first finishes any cleanup still owed, then runs checks (interface identity, PF state, anchor order, prototype and resolver state). A failed check stops it before it adds rules or a resolver. During these checks it may create an empty `/etc/resolver` directory, which stays if a later check refuses.
  - Before adding rules it also removes an exception recorded for a different interface identity. This and the earlier cleanup only remove TailBridge items.
  - Then `enable` records its intent (`enabled.json`). Once that has succeeded, a failure while loading and verifying the rules, writing the resolver or removing the prototype's broad PF rules triggers an immediate rollback. Two later steps only log a warning and do not roll back: moving the recognized prototype state directory to backups, and flushing the DNS cache. If recording the intent itself fails, nothing has been added. A rollback that does not complete is reported, and the monitor keeps retrying the cleanup.
  - The Tailscale env file is managed by the app, not the helper. It is created in a separate step before the helper runs, and it stays in place until Disable, even if the later administrator step is cancelled or fails.
  - Every 5 s the monitor removes the exception if the interface, addresses, anchor, PF state or anchor order no longer match. It never turns anything on by itself.
- **Recognized content only, for shared files:** the env file, resolvers, prototype items and the LaunchDaemon plist are replaced or removed only when their content is exactly recognized. Otherwise they are left untouched and reported.
- **TailBridge's own state files** in `/Library/Application Support/TailBridge/` (`enabled.json`, `status.json`, `anchor.rules`, `cleanup-required.json`) are written and removed without content checks. The helper checks the owner, mode and ACLs of that directory instead.

## Known limitations and risks

- **Ad-hoc signature.** No Developer ID signature and no notarization. The signature does not identify the publisher, and `BUILDINFO.txt` is not signed. Build from source yourself.
- **The helper comes from the app you run.** Install Helper… copies the helper out of the running app bundle. The administrator prompt shows only the first 16 characters of the helper's SHA-256. Before you approve it, check that they match the start of `sha256_helper` in the `BUILDINFO.txt` of your own build. The full digest is written to the app's log window.
- **Limited distribution testing.** A clean app was copied into `/Applications` and run on one development Mac. A downloaded copy with the quarantine attribute (Gatekeeper) has not been tested. The manual copy steps check that the destination name is free, but something created at that path in between could still be nested or merged.
- **Broad inbound traffic from the tailnet.** The exception lets PF pass traffic from the whole tailnet to this Mac's Tailscale address. Only Tailscale ACLs restrict it.
- **Monitor delay.** Reaction takes up to ~5 s plus `pfctl` time. The monitor does not run during sleep. Behavior after sleep, network changes, reboots and Tailscale restarts is **NOT TESTED**.
- **Undocumented Tailscale option.** `TS_BIND_TO_INTERFACE_BY_ROUTE` may behave differently after a Tailscale update.
- **DNS and kill switch.** One controlled IPv4 DNS query/response sample and one limited blocked IPv4 TCP observation with Lockdown on were recorded. The automated lockdown result remains Inconclusive because of a cross-process clock-classification error. Actual unexpected tunnel failure, IPv6 protection, all DNS protocols, DoH/DoT and other failure states are unverified. With lockdown off, traffic can leave outside the VPN when Mullvad disconnects, regardless of TailBridge. See [acceptance evidence](docs/ACCEPTANCE.txt).
- **Mullvad DNS content blockers vs. Tailscale.** Mullvad's content-blocking DNS servers use addresses in `100.64.0.0/10`, a range Tailscale also uses. A conflict is possible and **NOT TESTED**. The app only shows a warning.
- **Readable by other accounts.** The state files in `/Library/Application Support/TailBridge/` (mode 644) and the helper log reveal the tailnet name and Tailscale addresses to other local accounts.
- **Trust in vendor CLIs.** The app runs the Mullvad and Tailscale CLIs from `/Applications` as your user, only if the file is owned by root and not writable by others.
- **Unbounded wait after SIGKILL** in `Proc.run`. Each `pfctl` call gets 15 s, then SIGTERM, then SIGKILL 2 s later; the helper then waits without an upper bound for the process to exit, so that PF changes never overlap. A process that does not exit holds the helper's lock: the monitor, cleanup, `status.json` and helper commands, including Disable and uninstall, wait until it does, and the app shows Status Unknown. **Not observed live.**
- **The status headline is not a leak test.** In this snapshot, the green headline needs TailBridge's exception, Mullvad reported as connected and Tailscale running, and some Test Connection results need a cleanly finished command. Earlier development builds were less strict, and their uninstall reports plain success when it leaves a changed resolver in place. Details: [docs/OPERATIONS.md](docs/OPERATIONS.md#development-history-and-current-behavior).
- **One tested configuration:** macOS 27.2 arm64. Helper uninstall and the helper installer's rollback have not been tested live.
