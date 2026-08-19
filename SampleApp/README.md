# GlomoPay iOS SDK Sample App

This SwiftUI sample app demonstrates a local integration of the GlomoPay iOS SDK. It validates the public key and order/subscription ID, lets the SDK automatically detect the checkout type, presents the native checkout, and displays payment callbacks and bridge events.

## Run

1. Open `GlomoPaySample.xcodeproj` in Xcode.
2. Select the `GlomoPaySample` scheme.
3. Select an iOS Simulator or connected iPhone.
4. If running on a physical device, select your development team under **Signing & Capabilities**.
5. Build and run with `Cmd + R`.

The project uses the SDK package from the repository root through the local package path `..`.

Mixpanel and Sentry client configuration is owned by the SDK. The sample app does not require telemetry keys in its `Info.plist` or Xcode build settings.
