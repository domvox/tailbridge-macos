# TailBridge

[Source repository](https://github.com/domvox/tailbridge-macos) · [Private vulnerability reports](https://github.com/domvox/tailbridge-macos/security/advisories/new)

> **Source-only Experimental preview for review (1.1.0, channel Experimental).** TailBridge changes PF firewall rules and a DNS resolver as root.
> It has been tested on one Mac, in one configuration. There are no prebuilt downloads, no installer and no automatic updates.
> This source preview is not a recommendation for sensitive use. Understand the changes below and how to undo them before running it.

TailBridge is a local macOS app that lets **Mullvad VPN** and **Tailscale** run at the same time on one Mac.
It has four functions: Enable, Disable, Test Connection and Run Diagnostics.

TailBridge is not affiliated with Mullvad VPN AB or Tailscale Inc. Their product names are used only to describe compatibility.

## The problem and what TailBridge changes

While Mullvad is connected, its PF rules block traffic outside the Mullvad tunnel. That includes Tailscale's own transport and traffic to tailnet devices on Tailscale's `utun` interface.

When you click **Enable**, TailBridge makes three changes:

1. **A Tailscale env file** (as your user) containing `TS_BIND_TO_INTERFACE_BY_ROUTE=1`, in the Tailscale network extension's container. Tailscale then picks its interface by route, which sends its transport through the Mullvad tunnel.
   - This is an **internal, undocumented Tailscale option**. It may stop working after a Tailscale update.
   - It takes effect only after Tailscale restarts.
2. **Four narrow PF rules** (as root) in the anchor `com.apple/tailbridge`. They cover only the current Tailscale `utun` interface and this Mac's own Tailscale addresses. The rules are listed in [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) (in Polish).
3. **A resolver** `/etc/resolver/<tailnet>.ts.net` → `100.100.100.100`, Tailscale's MagicDNS (as root).

A root helper (`com.tailbridge.helper`) runs as a LaunchDaemon. Every 5 seconds it checks the interface and the rules. If anything no longer matches, it **removes** the exception and the resolver. It never turns anything on by itself.

### What TailBridge does not do

- It does not connect or disconnect Mullvad, and does not change Mullvad settings, including lockdown mode and DNS.
- It does not edit `/etc/pf.conf`, does not reload the main PF ruleset, and does not enable or disable PF globally.
- It sends no telemetry, does not check for updates and downloads nothing. The network requests made by Test Connection are listed in [PRIVACY.md](PRIVACY.md).
- **It does not guarantee the absence of leaks or full security.** Actual unexpected tunnel failure, IPv6 protection, sleep, network changes and reboots remain unverified. Limited DNS and Lockdown observations are described below.
- While enabled, PF lets inbound traffic from the whole tailnet reach this Mac's Tailscale address. Only Tailscale ACLs restrict it.

## Status

Evidence log (in Polish): [STATUS.md](STATUS.md).

| Area | Status |
|---|---|
| Recorded pre-publication build and CI, on the same runtime sources | Core **445**, presentation **1,127**, manifest **14/14**, soak **10,000**. The separate public repository has not run CI yet. |
| App and matching helper on one development Mac | A development build with the same runtime sources was copied to `/Applications`; its matching helper was installed through the standard app path and observed over several status cycles. This is not full lifecycle coverage. |
| PF and resolver after helper installation | The helper reported enabled PF, expected anchor order, exact owned rules/resolver and no pending cleanup/problems. The separate independent PF snapshot predates this installation. |
| Public IPv4 | HTTP 200 and strict `mullvad_exit_ip=true` in the observed samples. |
| Public IPv6 | **Unavailable**, with no usable global IPv6 connectivity. This is not a protection pass. Earlier IPv6 claims remain unconfirmed. |
| Controlled IPv4 DNS sample | One query and response observed on loopback and inside the Mullvad tunnel; no plaintext port-53 DNS captured on the active physical interface during that sample, with zero kernel drops. This does not cover all DNS or failure states. |
| Lockdown sample | Automated result **Inconclusive** because the harness compared process-relative clocks across processes. A manual, limited observation showed one pinned-endpoint IPv4 TCP attempt blocked while sampled states were Disconnected/Lockdown on; the endpoint worked before and after reconnection. This is not an actual tunnel-failure test. |
| Helper Enable/Disable/uninstall/rollback lifecycle on this version | **Not fully tested.** Older v1 lifecycle observations do not establish current lifecycle coverage. |
| Unexpected tunnel failure, IPv6 protection, sleep, network changes, reboot, extended stability | **Not verified.** No claim of leak-free operation or kill-switch protection. |
| Quarantined download, Developer ID and notarization | **Not verified / not provided.** No binary release is offered. |
| Mullvad DNS content-blocker conflict with Tailscale | **Not tested.** The app only shows a warning. |

## Requirements and tested configuration

The only tested configuration:

| Component | Version |
|---|---|
| macOS | 27.2 (26B123), Apple silicon (arm64) |
| Toolchain | Xcode 27.2 (27B52), Swift 6.4.2 |
| Tailscale | 1.104.4, Mac App Store version (`io.tailscale.ipn.macos`) at `/Applications/Tailscale.app` |
| Mullvad VPN | 2026.5, app at `/Applications/Mullvad VPN.app` (CLI from the app bundle) |

Requirements that follow from the code:

- an administrator account: installing the helper, Enable and Disable ask for your password;
- `xcrun swiftc` from Xcode or the Command Line Tools (`iconutil`, `codesign` and `plutil` come with macOS);
- the Mac App Store version of Tailscale at the path above. The code uses the container path `io.tailscale.ipn.macos.network-extension`, so **other Tailscale variants are not supported**, such as the standalone download or `tailscaled` from Homebrew;
- Mullvad VPN at the path above, with its CLI owned by root and not writable by others;
- PF enabled, with the `com.apple/*` anchor before the `mullvad` anchor. The helper checks this and otherwise refuses to enable.

Other macOS versions, Intel Macs, and other Tailscale or Mullvad versions are **untested**. `LSMinimumSystemVersion` in `Info.plist` is not a support statement.

## Building

```
./build.sh
tests/bundle-manifest-test.sh
```

`build.sh`:

- reads the version, build number and channel from `version.conf` (the only place they are set);
- compiles and runs the fixture tests and the presentation tests;
- builds the helper, the app and the icon, and signs the bundle **ad hoc** (no Developer ID, no notarization);
- writes `build/TailBridge.app` and `build/BUILDINFO.txt`, and prints `BUILDINFO.txt` at the end.

It **installs nothing** and does not change network settings. The tests do not touch `/etc`, PF or the network. They only start local processes such as `/bin/sh` and `/bin/sleep`.
The `Proc` soak test (10,000 runs by default) can be skipped with `TAILBRIDGE_SOAK=0 ./build.sh`.

`BUILDINFO.txt` records the commit, whether the tree had uncommitted changes, the toolchain, the CDHash, SHA-256 sums (including `sha256_helper`) and a bundle-manifest hash. It is not signed.
Build from a clean, committed tree (`uncommitted_changes=no`) if you want the About panel and `BUILDINFO.txt` to identify the exact source.

`tests/bundle-manifest-test.sh` checks `tools/bundle-manifest.sh` in a temporary directory, and checks that the built bundle matches `BUILDINFO.txt`.

## Installation

There are no prebuilt downloads and no installer script. Build from source, then install in two separate steps:

1. **The app only.** Copy `build/TailBridge.app` into `/Applications` by hand, following [docs/OPERATIONS.md](docs/OPERATIONS.md#copying-the-app-into-applications). You can also run it from `build/`.
   - Copying the app does **not** install, update or restart the helper, and does not change the network.
   - Quitting the app does not disable TailBridge. The helper keeps running.
   - Copying a clean app into `/Applications` and launching it were observed on one development Mac; this does not verify a downloaded or quarantined copy.
2. **The helper, separately.** In the app: **Administration → Install Helper…**
   - The administrator prompt shows the first 16 characters of the helper's SHA-256. Check that they match the start of `sha256_helper` in `build/BUILDINFO.txt`. The full digest is in the app's log window (Show Log).
   - This creates `/Library/PrivilegedHelperTools/com.tailbridge.helper` and `/Library/LaunchDaemons/com.tailbridge.helper.plist`, and starts the monitor. The network is not changed.
   - The helper is copied from the app bundle you are running. After you update the app, the installed helper stays at its old version until you install it again.

Then:

3. **Enable** — requires Mullvad connected, Tailscale running and the helper running. On first use the app creates the env file and asks you to restart Tailscale.
4. **Test Connection** — choose a tailnet device, or enter a target under Advanced. Results marked as not verified or inconclusive are not proof of protection.
   - The green "TailBridge Is On" headline needs TailBridge's exception in place, Mullvad reported as connected and Tailscale running. It does not prove that your devices are reachable or that nothing leaks. Earlier development builds were less strict: [details](docs/OPERATIONS.md#development-history-and-current-behavior).

## Disabling, removal and recovery

- **Disable** removes the anchor, the TailBridge resolver and recognized prototype items, and moves the env file to a backup folder. It does **not** disconnect Mullvad. The env file stops applying after Tailscale restarts.
- **Removal**, in this order: Disable, **Administration → Uninstall Helper…**, quit the app, then remove the app copy. Uninstalling the helper leaves backups, the helper log and the app's preferences on disk. Helper uninstall has **not been tested live**.
- **Rolling back the app** to a previous copy: [docs/OPERATIONS.md](docs/OPERATIONS.md#rolling-back-the-app).
- **Manual recovery** when the app does not work: helper commands, and `pfctl` commands limited to the TailBridge anchor.

Full instructions, including the files left on disk: [docs/OPERATIONS.md](docs/OPERATIONS.md).

## Privacy and security

- [PRIVACY.md](PRIVACY.md): network requests, data stored locally, and what logs, `BUILDINFO.txt` and screenshots reveal.
- [SECURITY.md](SECURITY.md): design, known limitations and vulnerability reporting.

Before you paste a log, Run Diagnostics output or a screenshot into a public issue, remove your tailnet name, device names and addresses, and your macOS account name.

## Repository layout

- `src/Core/` — validation, PF rules, interface identity, safe file operations, the `enable`/`teardown`/monitor engine.
- `src/Helper/main.swift` — the root helper with a fixed set of commands.
- `src/App/` — the AppKit app (English UI), read-only diagnostics and the About panel.
- `tests/main.swift`, `tests/app/main.swift` — fixture tests and presentation-logic tests.
- `tests/bundle-manifest-test.sh` — tests for the bundle manifest, in a temporary directory.
- `build.sh`, `version.conf` — build script and the single source of version, build number and channel.
- `tools/` — icon generator (`make-icon.swift`) and bundle manifest (`bundle-manifest.sh`).
- `.github/workflows/ci.yml` — CI: build and tests only.
- `docs/` — operations, [release checklist](docs/RELEASE-CHECKLIST.md), acceptance evidence and design notes. Historical AI review reports are not included in this snapshot.
- `LICENSE` — the full text of the Apache License 2.0.

## License

TailBridge is licensed under the [Apache License, Version 2.0](LICENSE) (SPDX identifier: `Apache-2.0`).

It is distributed on an "AS IS" basis, without warranties or conditions of any kind. See [LICENSE](LICENSE) for the full terms.
