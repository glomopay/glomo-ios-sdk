Pod::Spec.new do |spec|
  spec.name         = "GlomoPaySDK"
  spec.version      = "0.0.1"
  spec.summary      = "Native iOS SDK for GlomoPay checkout."
  spec.description  = <<-DESC
    Native Swift SDK for integrating GlomoPay Standard and LRS checkout flows
    with a modal WKWebView, typed callbacks, device compliance checks, and
    Flutter-compatible payment events.
  DESC
  spec.homepage     = "https://github.com/mayankmatkar/glomopay-ios-sdk"
  spec.license      = { :type => "MIT" }
  spec.author       = { "GlomoPay" => "support@glomopay.com" }
  spec.source       = {
    :git => "https://github.com/mayankmatkar/glomopay-ios-sdk.git",
    :tag => spec.version.to_s
  }

  spec.ios.deployment_target = "15.0"
  spec.swift_version = "5.9"
  spec.source_files = "Sources/GlomoPaySDK/**/*.swift"
  spec.frameworks = "Foundation", "UIKit", "WebKit"
end
