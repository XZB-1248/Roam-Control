# Changelog

All notable public changes to Roam Control are recorded here.

## [Unreleased]

### Changed

- Replaced the LocalDevVPN dependency with a bundled `NEPacketTunnelProvider`. Roam Control now brings up its own loopback tunnel for the length of a location session, so there is no app switching and no external install step.
- Renamed the bundle identifier to `com.clover.RoamControl`. The tunnel extension is `com.clover.RoamControl.tunnel`.
- Building now requires a paid Apple Developer Program membership: Network Extension entitlements cannot be signed by a free account, so SideStore and AltStore installs are no longer possible.

### Fixed

- Stopping a location session now waits for the iPhone to confirm that the simulated location was cleared, and reports it when the confirmation never arrives. Previously the clear was fire-and-forget, so a failed or hung stop still looked successful. Adopted from upstream 0.9.2 Beta 3, including the rebuilt native slices.
- A stop the iPhone never confirmed keeps the session recovery record, so the next launch still offers to restore the real location.
- Pairing: destroy the native session on the main actor, where cancellation also runs; keep the coordinator busy during the keychain write; ignore background-task launches and submission failures belonging to a superseded attempt; settle the phase when a cancel arrives before the worker starts.
- Background-task refusals now report what iOS actually withheld, and a refusal the tunnel cannot fix no longer sends the user into tunnel troubleshooting.
- Connection Health connects to the pairing port it discovered instead of passing on the announcement alone, so a stale announcement no longer reports a healthy connection.

### Added

- Settings → Local Tunnel shows the tunnel's live state and can keep it running between sessions for troubleshooting.

### Internal

- Split `LocalDeviceSessionCoordinator` into focused collaborators: `LocalTunnelController` (tunnel lifecycle), `RemotePairingBrowser` (discovery and pairing match), `LocationSessionRunner` (native session and background task). The coordinator now only sequences them.
- `ConnectionDiagnosticsCoordinator` reuses `RemotePairingBrowser` instead of carrying its own duplicate Bonjour implementation.

## [0.9.1] - 2026-09-10

First beta polish release, corresponding to app version 0.9.1 Build 47.

### Improved

- Made location restoration clearer: confirmation, visible restoration progress and a clean return to the ready state.
- Improved interrupted-session recovery and removed unnecessary resume controls after a successful stop and restore.
- Kept active location sessions reliable in the background while allowing the Dynamic Island presentation to stay compact.
- Restored richer, faster place-search results, including useful address detail.
- Added drag-to-reorder for favourites while keeping history in chronological order.
- Made the selected map location reliably recenter when returning to it.

### Added

- Added **Copy Diagnostics** under Settings → Connection Health. The copied report deliberately excludes locations, searches, pairing records, PINs, device names and error text.
- Added Settings links for GitHub bug reports and feature requests, plus structured GitHub issue forms.
- Added a manual **Check for Updates** control in Settings that checks only the public GitHub release.
- Added privacy-preserving telemetry for handled pairing, preparation, restoration, start and LocalDevVPN failures.

## [0.9.0-beta.1] - 2026-09-04

First public beta, corresponding to app version 0.9.0 Build 29.

### Added

- Fixed reported locations selected by search, coordinates or map pin.
- Live MapKit search, favourites, history and renamed saved places.
- Walking-route preview, pace control, pause/resume, reverse and redirect.
- Native on-device pairing with secure Keychain storage.
- Guided LocalDevVPN flows for Wi-Fi and mobile data.
- Interrupted-session recovery and explicit real-location restoration.
- Light, dark and automatic appearance; map styles; Dynamic Type, VoiceOver and Reduce Motion support.
- Optional, off-by-default anonymous usage statistics with an in-app disclosure and Apple privacy manifest.

### Privacy and release hardening

- Removed per-launch analytics session identifiers.
- Preserved existing consent choices while defaulting new installations to sharing off.
- Prevented failed location updates from being counted as successful.
- Moved the release analytics destination and Apple development-team identifier out of tracked project settings.

[Unreleased]: https://github.com/seanhowarthdev/Roam-Control/compare/v0.9.1...HEAD
[0.9.1]: https://github.com/seanhowarthdev/Roam-Control/compare/v0.9.0-beta.1...v0.9.1
[0.9.0-beta.1]: https://github.com/seanhowarthdev/Roam-Control/releases/tag/v0.9.0-beta.1
