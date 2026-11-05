import Foundation
import AppKit
import CoreGraphics
import ScreenCaptureKit

public final class AXScreenCapture: ScreenSense {
    private let reader = AXTreeReader()

    public init() {}

    public func captureWindowPNG(_ target: ScreenTarget) async throws -> Data {
        try AXPermissionGate.requireScreenRecording()

        let content: SCShareableContent
        do {
            content = try await SCShareableContent.current
        } catch {
            throw AXAutomationError.captureFailed("无法枚举可共享内容：\(error.localizedDescription)")
        }

        guard let window = content.windows.first(where: { $0.windowID == target.id }) else {
            throw AXAutomationError.windowNotFound(target.id)
        }

        let filter = SCContentFilter(desktopIndependentWindow: window)
        let configuration = SCStreamConfiguration()
        let scale = CGFloat(filter.pointPixelScale > 0 ? filter.pointPixelScale : 1)
        let rect = filter.contentRect.width > 0 && filter.contentRect.height > 0 ? filter.contentRect : window.frame
        configuration.width = max(1, Int((rect.width * scale).rounded()))
        configuration.height = max(1, Int((rect.height * scale).rounded()))
        configuration.showsCursor = false
        configuration.scalesToFit = false

        let image: CGImage
        do {
            image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
        } catch {
            throw AXAutomationError.captureFailed("SCScreenshotManager 返回错误：\(error.localizedDescription)")
        }
        return try AXPNG.encode(image)
    }

    public func captureFullScreenPNG() async throws -> Data {
        try AXPermissionGate.requireScreenRecording()

        let content: SCShareableContent
        do {
            content = try await SCShareableContent.current
        } catch {
            throw AXAutomationError.captureFailed("无法枚举可共享内容：\(error.localizedDescription)")
        }

        let mainDisplayID = CGMainDisplayID()
        guard let display = content.displays.first(where: { $0.displayID == mainDisplayID }) ?? content.displays.first else {
            throw AXAutomationError.displayNotFound
        }

        let filter = SCContentFilter(display: display, excludingWindows: [])
        let configuration = SCStreamConfiguration()
        let pixelWidth = CGDisplayPixelsWide(display.displayID)
        let pixelHeight = CGDisplayPixelsHigh(display.displayID)
        let scale = CGFloat(filter.pointPixelScale > 0 ? filter.pointPixelScale : 1)
        if pixelWidth > 0, pixelHeight > 0 {
            configuration.width = pixelWidth
            configuration.height = pixelHeight
        } else {
            let bounds = CGDisplayBounds(display.displayID)
            configuration.width = max(1, Int((bounds.width * scale).rounded()))
            configuration.height = max(1, Int((bounds.height * scale).rounded()))
        }
        configuration.showsCursor = false
        configuration.scalesToFit = false

        let image: CGImage
        do {
            image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
        } catch {
            throw AXAutomationError.captureFailed("SCScreenshotManager 返回错误：\(error.localizedDescription)")
        }
        return try AXPNG.encode(image)
    }

    public func accessibilityTree(_ target: ScreenTarget, maxNodes: Int) throws -> String {
        try reader.accessibilityTree(target, maxNodes: maxNodes)
    }
}
