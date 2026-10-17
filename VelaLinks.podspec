Pod::Spec.new do |s|
  s.name             = 'VelaLinks'
  s.version          = '1.0.0'
  s.summary          = 'Deep links, deferred deep links, short links and in-app analytics for iOS apps.'
  s.description      = <<-DESC
    Opens the right screen from a tapped link, a QR code or a custom scheme (even right after install), creates short share
    links from inside the app, and reports screens, sign-ups and purchases credited to the link or campaign that brought each
    person. No third-party dependencies, no advertising id, no device id, no location.
  DESC
  s.homepage         = 'https://deeplinks.velaapps.in'
  s.license          = { :type => 'MIT', :file => 'LICENSE' }
  s.author           = { 'Vela Apps' => 'info@velaapps.in' }
  s.source           = { :git => 'https://github.com/velaapps/vela-links-ios.git', :tag => s.version.to_s }
  s.ios.deployment_target = '13.0'
  s.swift_versions   = ['5.9', '5.10']
  s.source_files     = 'Sources/VelaLinks/**/*.swift'
  s.frameworks       = 'Foundation', 'UIKit'
  s.weak_frameworks  = 'SwiftUI'
end
