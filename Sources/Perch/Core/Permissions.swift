import Foundation
import AppKit
import ApplicationServices
import CoreGraphics

public final class PermissionService {
    public init() {}

    public var hasAccessibility: Bool { AXIsProcessTrusted() }

    public var hasScreenRecording: Bool { CGPreflightScreenCaptureAccess() }

    @discardableResult
    public func requestAccessibility() -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    @discardableResult
    public func requestScreenRecording() -> Bool {
        CGRequestScreenCaptureAccess()
    }

    public func openAccessibilitySettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }

    public func openScreenRecordingSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
        NSWorkspace.shared.open(url)
    }
}
