# Installation

This fork bundles its own packet tunnel, so it cannot be installed the way upstream Roam Control is. A Network Extension needs the `com.apple.developer.networking.networkextension` entitlement, which only a paid Apple Developer Program membership can sign. Free Apple accounts, SideStore and AltStore cannot install this build.

## Requirements

- An iPhone running iOS 27 or newer.
- Developer Mode enabled under **Settings → Privacy & Security**.
- Xcode 27 or newer on a Mac.
- A paid Apple Developer Program membership.

No companion app is required. Earlier versions needed LocalDevVPN; the tunnel now ships inside Roam Control.

## Build and install

1. Clone the repository and open `RoamControl.xcodeproj`.
2. Copy `Configuration/Local.private.xcconfig.example` to `Configuration/Local.private.xcconfig` and set `DEVELOPMENT_TEAM` to your team ID.
3. Confirm both targets — `RoamControl` and `RoamControlTunnel` — show **Network Extensions** under **Signing & Capabilities**. Automatic signing registers the capability for both App IDs.
4. Select a connected iPhone and press **Run**.

The bundle identifiers are `com.clover.RoamControl` and `com.clover.RoamControl.tunnel`. The extension identifier must stay prefixed by the app's, because the app derives it at runtime.

## First run

1. Complete the introduction and pair this iPhone.
2. Choose a location and tap **Start Location**.
3. Approve **"Roam Control Would Like to Add VPN Configurations"** when iOS asks. This happens once per install and requires Face ID, Touch ID or the passcode.

The tunnel then appears under **Settings → General → VPN & Device Management**. It carries nothing but traffic addressed to `10.7.0.1`, which is this iPhone's own developer service; it sets no DNS and no default route, so the rest of the device's networking is untouched.

## Notes

- Do not commit signing material or `Configuration/Local.private.xcconfig`.
- The tracked build configuration has no Apple team and no telemetry destination.
- iOS runs one packet tunnel at a time, so another active VPN will conflict with a location session.
