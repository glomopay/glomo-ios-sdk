Pod::Spec.new do |spec|
  spec.name         = "glomo-ios-sdk"
  spec.module_name  = "GlomoPaySDK"
  spec.version      = "0.0.1"
  spec.summary      = "Native iOS SDK for GlomoPay checkout."
  spec.description  = <<-DESC
    Native Swift SDK for integrating GlomoPay Standard and LRS checkout flows
    with a modal WKWebView, typed callbacks, device compliance checks, and
    Flutter-compatible payment events.
  DESC
  spec.homepage     = "https://github.com/glomopay/glomo-ios-sdk"
  spec.license      = { :type => "Apache-2.0", :file => "LICENSE" }
  spec.author       = { "GlomoPay" => "support@glomopay.com" }
  spec.source       = {
    :git => "https://github.com/glomopay/glomo-ios-sdk.git",
    :tag => spec.version.to_s
  }

  spec.ios.deployment_target = "15.0"
  spec.swift_version = "5.9"
  spec.source_files = "Sources/GlomoPaySDK/**/*.swift"
  spec.resource_bundles = {
    "GlomoPaySDKPrivacy" => ["Sources/GlomoPaySDK/Resources/PrivacyInfo.xcprivacy"]
  }
  spec.frameworks = "Foundation", "UIKit", "WebKit"
  spec.dependency "Sentry/Core", "8.58.4"
end
