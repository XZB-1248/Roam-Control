<p align="center">
  <img src="Design/RoamControl-AppIcon-v2-source.png" width="128" height="128" alt="Roam Control app icon">
</p>

<h1 align="center">Roam Control</h1>

<p align="center">
  Choose, test and move an iPhone's reported location from one clean Apple Maps interface.
</p>

<p align="center">
  <strong>Public beta:</strong> 0.9.1 Beta 2 (Build 47) · <strong>Requires:</strong> iOS 27+
</p>

<p align="center">
  <img src="https://img.shields.io/badge/iOS-27%2B-blue" alt="iOS 27+">
  <img src="https://img.shields.io/badge/UI-SwiftUI-orange" alt="SwiftUI">
  <img src="https://img.shields.io/badge/Beta-2-purple" alt="Beta 2">
  <img src="https://img.shields.io/badge/Build-47-lightgrey" alt="Build 47">
  <img src="https://img.shields.io/badge/License-PolyForm%20NC%201.0.0-blue" alt="PolyForm Noncommercial 1.0.0">
</p>

Roam Control is a source-available SwiftUI app for location-based development, quality assurance and responsible personal testing on an iPhone you own and control. It supports fixed locations, walking routes, favourites, history, native on-device pairing and a self-contained local tunnel.

## Screenshots

<p align="center">
  <img src="Documentation/Images/README/welcome.png" width="240" alt="Roam Control welcome screen">
  <img src="Documentation/Images/README/fixed-location.png" width="240" alt="Selecting a fixed location in London">
  <img src="Documentation/Images/README/walking-active.png" width="240" alt="Active simulated walking route">
</p>

<p align="center">
  <sub>Welcome · Fixed location · Walking route</sub>
</p>

<p align="center">
  <img src="Documentation/Images/README/privacy.png" width="240" alt="Privacy-first anonymous statistics choice">
  <img src="Documentation/Images/README/settings.png" width="240" alt="Roam Control settings">
</p>

<p align="center">
  <sub>Private by design · Settings</sub>
</p>

## Highlights

- Search places live with MapKit, enter coordinates or tap the map.
- Start a fixed reported location and update it without reconnecting.
- Preview an Apple Maps walking route before starting.
- Pause, resume, reverse or redirect an active walk.
- Save named favourites and revisit recent locations.
- Restore the real location explicitly when testing is finished.
- Recover safely after an interrupted fixed or walking session.
- Follow separate, guided connection flows for Wi-Fi and mobile data.
- Choose automatic, light or dark appearance and standard, satellite or hybrid maps.
- Use Dynamic Type, VoiceOver and Reduce Motion.

## Install the public beta

This fork bundles its own packet tunnel, so it must be built and signed with a paid Apple Developer Program membership. Free accounts, SideStore and AltStore cannot sign a Network Extension.

You will need:

- An iPhone running iOS 27 or newer.
- Developer Mode enabled.
- Xcode 27 or newer and a paid Apple Developer Program membership.

Read the complete [installation guide](Documentation/Installation.md) before installing.

## First-time setup

1. Install and open Roam Control.
2. Complete the four-page introduction.
3. Tap **Pair This iPhone** on Device Setup.
4. Open **Settings → Privacy & Security → Developer Mode → Pair with Roam Control**.
5. Enter the six-digit code shown in Roam Control.
6. Choose a location or walking route, and approve the VPN configuration when iOS asks.

The pairing record is stored in the iPhone Keychain and is never uploaded.

## Privacy

Locations, coordinates, searches, favourites, history, walking routes and pairing records stay on the iPhone.

Anonymous usage statistics are optional and off by default. When enabled, a narrow first-party sender reports only a fixed set of activity events, the app version/build and a hashed random installation identifier. It never sends locations, searches, routes, pairing data, device names or diagnostics. No third-party analytics SDK is embedded.

The public project has no live analytics destination or Apple signing team. A checkout therefore sends no statistics unless the builder deliberately supplies a private local configuration.

Read [Privacy](Documentation/Privacy.md) for the exact event and retention disclosure.

## Responsible use

Roam Control is intended for development and testing on a device you own and control. Location simulation can affect every app using the iPhone's reported position. Restore the real location before using navigation, emergency, safety, transport or location-sharing features.

Do not use Roam Control to mislead another person, falsify evidence, access something you are not entitled to use, evade safeguards or breach a third-party service's rules. See [Responsible Use](Documentation/ResponsibleUse.md).

## Build from source

1. Clone the repository and open `RoamControl.xcodeproj` in Xcode 27 or newer.
2. Select the Roam Control target.
3. Choose your own Apple development team under **Signing & Capabilities**.
4. Select a connected iPhone and press **Run**.

The iPhone simulator is useful for interface work but cannot complete the physical pairing handshake or start a location session.

Normal builds use the included `Frameworks/RoamPairingFFI.xcframework`. The framework contains arm64 iPhone and Apple Silicon simulator slices. Rebuild it only after changing `Native/RoamPairingFFI`; instructions are in the [build and release guide](Documentation/BuildAndRelease.md).

## How it works

Roam Control generates or imports an RPPairing record for the same iPhone and stores it in the device-only Keychain. When a location starts, it brings up its own packet tunnel, discovers that iPhone's remote-pairing service, verifies the device identity and opens the encrypted developer session used to set or clear a simulated location.

The tunnel exists because iOS will not serve the remote-pairing service over loopback: a connection to any local address short-circuits through `lo0`, which `remoted` does not answer. The bundled `NEPacketTunnelProvider` takes `10.7.0.0` and advertises `10.7.0.1`, swaps the source and destination of each packet sent to that peer, and writes it straight back, so it arrives as ordinary inbound traffic on a real interface. Only `10.7.0.1` is routed into it.

The native engine is a narrow Rust-to-Swift bridge around the MIT-licensed [`idevice`](https://github.com/jkcoxson/idevice) library, pinned to an exact revision.

## Documentation

- [Installation](Documentation/Installation.md)
- [User guide](Documentation/UserGuide.md)
- [Privacy](Documentation/Privacy.md)
- [Responsible use](Documentation/ResponsibleUse.md)
- [Build and release guide](Documentation/BuildAndRelease.md)
- [Regression checklist](Documentation/RegressionChecklist.md)
- [0.9.1 release notes](https://github.com/seanhowarthdev/Roam-Control/releases/tag/v0.9.1)
- [Beta 1 release notes](Documentation/PublicBetaRelease.md)
- [Security policy](SECURITY.md)
- [Third-party notices](THIRD_PARTY_NOTICES.md)

## Community

For casual help, beta discussion and feature ideas, join the [Roam Control Discord](https://discord.gg/fJrNvQ2Vdh).

For bugs and reproducible issues, please use GitHub Issues. For security-sensitive reports, use GitHub Security Advisories.

## Contributing

Bug reports and focused improvements are welcome. Read [CONTRIBUTING.md](CONTRIBUTING.md) before opening an issue or pull request, and never upload pairing records, signing material, credentials or private location information.

## Licence

Roam Control's current source is available under the [PolyForm Noncommercial License 1.0.0](LICENSE). It may be used, modified and redistributed for non-commercial purposes under those terms. Commercial use requires separate permission from the project owner.

Roam Control 0.9.0 Beta 1 was released under the MIT Licence and remains available under those terms. The licence change applies to development after Beta 1 and does not revoke rights already granted for that release.

See [Licensing](LICENSING.md) for details. Bundled dependencies retain their own licences; see [Third-party notices](THIRD_PARTY_NOTICES.md).
