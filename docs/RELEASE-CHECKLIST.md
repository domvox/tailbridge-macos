# Release checklist

Proposal, updated 2026-11-01 for this clean source snapshot. Planned publication is source-only Experimental for review, without a tag, release asset or binary recommendation for sensitive use. The limited current observations are in [ACCEPTANCE.txt](ACCEPTANCE.txt); unchecked beta/lifecycle gates stay unchecked.
An updater, an in-app DNS leak test, a kill switch, an installer script and new features are **out of scope** for both lists.
"Live verification" items are manual tests with the result recorded in [STATUS.md](../STATUS.md), not new features.

## First preview release (public repository, source only)

### Blocking owner decisions

The repository must not be made public until every item here is resolved.

- [x] **License:** Apache License 2.0 (SPDX `Apache-2.0`), chosen on 2026-11-01. [`LICENSE`](../LICENSE) holds the unmodified official text, appendix included.
- [x] **Private vulnerability-reporting channel:** GitHub Private Vulnerability Reporting is enabled. The public reporting button and sign-in route were verified; [SECURITY.md](../SECURITY.md) links to it.

### Other owner decisions

- [ ] Copyright holder, if a copyright line, a `NOTICE` file or per-file headers are wanted. Apache-2.0 does not require any of them. `LICENSE` stays the unmodified official text.
- [ ] Confirm that all tracked material (including the AI-assisted code and documents) may be published under Apache-2.0. A local scan on 2026-11-01 found no third-party code, notices or dependencies. It was heuristic and does not guarantee the rights.
- [ ] Review the Polish design/status notes before publication. Historical review reports and prototype scripts are excluded from this snapshot.
- [ ] Confirm the new initial commit uses only the public handle and verified GitHub noreply for author and committer, with no personal-email trailers.
- [ ] The name "TailBridge" checked for trademark issues, including Tailscale's and Mullvad's name-usage rules.
- [ ] Source-only release, without binaries (recommended: an ad-hoc signature does not identify the publisher, and a quarantined download has not been tested).

### Repository and history

- [ ] Use a new repository with one initial commit and verified GitHub noreply. Keep the original repository private. Do not import its Git history or refs.
- [ ] Scan all snapshot content and the initial commit metadata before publishing. Synthetic test addresses and protocol constants are not runtime records.
- [ ] Publish only this snapshot. No build output, runtime logs, packet captures, private reports or historical AI review documents.
- [x] Repository name: [domvox/tailbridge-macos](https://github.com/domvox/tailbridge-macos).

### CI

- [ ] Runner label re-checked against the official documentation on the day of the first run. On 2026-11-01, `xcode-27` was listed for the standard arm64 macOS runner for public and private repositories. GitHub's changelog announced the image as generally available on 2026-10-15. The runner-images inventory still listed Xcode 27.2, the version CI selects, as a release candidate.
- [ ] **First CI run in the new repository is green.** Pre-publication CI on the same runtime sources passed Core 445, presentation 1127, manifest 14 and soak 10,000; it is not a run of this new initial commit. Verify the new checkout SHA, toolchain and before/after guards. A green run is not proof of VPN protection.
- [ ] Actions settings: default `GITHUB_TOKEN` read-only, and approval required for workflow runs from first-time contributors' forks.
- [ ] Optional: CI status required for `main`.

### Live verification before preview (recommended)

A development app/helper with the same runtime sources was installed and observed on one development Mac. This does not complete the lifecycle checks below. IPv6 was unavailable; the automated lockdown result remains Inconclusive. See [ACCEPTANCE.txt](ACCEPTANCE.txt).

- [ ] Install the helper from current `main`, check that the SHA-256 prefix in the prompt and the full digest in the app log match `sha256_helper` in `BUILDINFO.txt`, and confirm the file-descriptor count stays stable for several hours.
- [ ] Enable, Test Connection, Disable and Enable again on current `main`.
- [ ] Verify IPv6 protection when real global IPv6 connectivity is available; Unavailable does not pass protection.
- [ ] Copy a clean build (`uncommitted_changes=no`) into `/Applications` with the steps in [OPERATIONS.md](OPERATIONS.md#copying-the-app-into-applications), launch it from the Finder and the Dock, check the About panel, then roll back once.
- [ ] Uninstall the helper live, and check that the files left on disk match [OPERATIONS.md](OPERATIONS.md#removal).

### Documentation

- [ ] The README "Status" table matches [STATUS.md](../STATUS.md) on release day.
- [ ] The tested configuration in the README matches the actual tests.
- [ ] The release label (e.g. a preview tag) matches `version.conf` (version, build, channel).

## Conditions for moving to beta

- [ ] Every scenario under "NADAL NIESPRAWDZONE" (still not tested) in STATUS.md tested live and documented, with a pass or a documented limitation:
  - sleep, network change, reboot, Tailscale restart;
  - utun behavior after Tailscale stops;
  - PF rule counters in both directions.
- [ ] Manual DNS-leak check (e.g. dnsleaktest Extended with browser DoH off) and behavior when Mullvad disconnects, with lockdown on and off. Results recorded.
- [ ] The Mullvad DNS content-blocker conflict checked with Tailscale running.
- [ ] Helper uninstall and the helper installer's rollback tested live, including after a failed install.
- [ ] Tested on a second Mac or a clean user account, not only on the development machine.
- [ ] Distribution decided and tested end to end: a Developer ID signature and notarization, or an explicitly documented alternative, including how a downloaded copy behaves under Gatekeeper. SHA-256 sums published with any release.
- [ ] Build reproducibility checked across machines, or documented as not guaranteed.
- [ ] Security review of the root helper by a human, not only by AI models.
- [ ] Known limitations resolved:
  - the unbounded wait after SIGKILL in `Proc.run` (kept deliberately so PF changes never overlap): bounded, or accepted as a documented availability limitation;
  - the helper log's file mode;
  - state files readable by other accounts (644).
- [ ] CI green on a generally available GitHub image with a released (non-RC) Xcode, or a documented reason for using a release candidate.
- [ ] Supported macOS, Tailscale and Mullvad versions described from the tests actually run, not from `LSMinimumSystemVersion`.
- [ ] The vulnerability-reporting channel works and has been tested.
