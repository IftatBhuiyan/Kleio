import Foundation

import AppKit

enum PlatformPresentationResolver {
    @MainActor
    static func keyWindow() -> NSWindow? {
        NSApp.keyWindow ?? NSApp.mainWindow ?? NSApp.windows.first
    }
}
