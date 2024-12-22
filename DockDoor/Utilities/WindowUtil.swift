import ApplicationServices
import Cocoa
import Defaults
import ScreenCaptureKit

let filteredBundleIdentifiers: [String] = ["com.apple.notificationcenterui", NSRunningApplication.current.bundleIdentifier!] // filters desktop widgets

struct WindowInfo: Identifiable, Hashable {
    let id: CGWindowID
    let window: SCWindow
    let app: NSRunningApplication
    var windowName: String?
    var image: CGImage?
    var axElement: AXUIElement
    var appAxElement: AXUIElement
    var closeButton: AXUIElement?
    var isMinimized: Bool
    var isHidden: Bool
    var date: Date

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
        hasher.combine(app.bundleIdentifier ?? String(app.processIdentifier))
    }

    static func == (lhs: WindowInfo, rhs: WindowInfo) -> Bool {
        lhs.id == rhs.id &&
            lhs.app.processIdentifier == rhs.app.processIdentifier &&
            lhs.isMinimized == rhs.isMinimized &&
            lhs.isHidden == rhs.isHidden
    }
}

enum WindowAction {
    case quit, close, minimize, toggleFullScreen, hide
}

struct CachedImage {
    let image: CGImage
    let timestamp: Date
    let windowname: String?
}

enum WindowUtil {
    private static var imageCache: [CGWindowID: CachedImage] = [:]
    private static let cacheQueue = DispatchQueue(label: "com.dockdoor.cacheQueue", attributes: .concurrent)
    private static var cacheExpirySeconds: Double = Defaults[.screenCaptureCacheLifespan]

    private static let desktopSpaceWindowCacheManager = SpaceWindowCacheManager()

    // MARK: - Cache Management

    static func clearExpiredCache() {
        let now = Date()
        cacheQueue.async(flags: .barrier) {
            imageCache = imageCache.filter { now.timeIntervalSince($0.value.timestamp) <= cacheExpirySeconds }
        }
    }

    static func resetCache() {
        cacheQueue.async(flags: .barrier) {
            imageCache.removeAll()
        }
    }

    static func clearWindowCache(for app: NSRunningApplication) {
        desktopSpaceWindowCacheManager.writeCache(pid: app.processIdentifier, windowSet: [])
    }

    static func updateWindowCache(for app: NSRunningApplication, update: @escaping (inout Set<WindowInfo>) -> Void) {
        desktopSpaceWindowCacheManager.updateCache(pid: app.processIdentifier, update: update)
    }

    // MARK: - Helper Functions

    /// Captures an image of a window using legacy methods for macOS versions earlier than 14.0.
    /// This function is used as a fallback when the ScreenCaptureKit's captureScreenshot API are not available.
    private static func captureImageLegacy(of window: SCWindow) async throws -> CGImage {
        let windowRect = CGRect(
            x: window.frame.origin.x,
            y: window.frame.origin.y,
            width: window.frame.width,
            height: window.frame.height
        )

        let options: CGWindowImageOption = [
            .bestResolution,
            .nominalResolution,
        ]

        guard var cgImage = CGWindowListCreateImage(windowRect, .optionIncludingWindow, window.windowID, options) else {
            throw NSError(domain: "WindowCaptureError", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to create image for window"])
        }

        let previewScale = Int(Defaults[.windowPreviewImageScale])

        // Only scale down if previewScale is greater than 1
        if previewScale > 1 {
            let newWidth = Int(cgImage.width) / previewScale
            let newHeight = Int(cgImage.height) / previewScale

            let colorSpace = cgImage.colorSpace ?? CGColorSpaceCreateDeviceRGB()
            let bitmapInfo = cgImage.bitmapInfo

            guard let context = CGContext(data: nil,
                                          width: newWidth,
                                          height: newHeight,
                                          bitsPerComponent: cgImage.bitsPerComponent,
                                          bytesPerRow: 0,
                                          space: colorSpace,
                                          bitmapInfo: bitmapInfo.rawValue)
            else {
                throw NSError(domain: "WindowCaptureError", code: 2, userInfo: [NSLocalizedDescriptionKey: "Failed to create graphics context for resizing"])
            }

            context.interpolationQuality = .high
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: newWidth, height: newHeight))

            if let resizedImage = context.makeImage() {
                cgImage = resizedImage
            }
        }

        return cgImage
    }

    /// Captures an image of a window using ScreenCaptureKit's for macOS versions 14.0 and later.
    @available(macOS 14.0, *)
    private static func captureImageModern(of window: SCWindow) async throws -> CGImage {
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let config = SCStreamConfiguration()

        let nativeScaleFactor = getScaleFactorForWindow(window: window)
        let previewScale = Int(Defaults[.windowPreviewImageScale])

        // Calculate the window's true dimensions in its native screen space
        let nativeWidth = window.frame.width * nativeScaleFactor
        let nativeHeight = window.frame.height * nativeScaleFactor

        // Apply the user's preview scale while preserving the window's native proportions
        let width = Int(nativeWidth) / previewScale
        let height = Int(nativeHeight) / previewScale

        config.width = width
        config.height = height
        config.scalesToFit = false
        config.backgroundColor = .clear
        config.captureResolution = .best
        config.ignoreGlobalClipDisplay = true
        config.ignoreShadowsDisplay = true
        config.shouldBeOpaque = false
        config.showsCursor = false

        if #available(macOS 14.2, *) {
            config.includeChildWindows = false
        }

        // Capture the image
        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
    }

    /// Main function to capture a window image using ScreenCaptureKit, with fallback to legacy methods for older macOS versions.
    static func captureWindowImage(window: SCWindow) async throws -> CGImage {
        clearExpiredCache()

        if let cachedImage = getCachedImage(window: window) {
            return cachedImage
        }

        // Use ScreenCaptureKit's API if available, otherwise fall back to a legacy (deprecated) API

        let image = try await captureImageLegacy(of: window)

        let cachedImage = CachedImage(image: image, timestamp: Date(), windowname: window.title)
        imageCache[window.windowID] = cachedImage

        return image
    }

    // Helper function to get the scale factor for a given window
    private static func getScaleFactorForWindow(window: SCWindow) -> CGFloat {
        let windowFrame = window.frame

        // Find the specific screen containing this window
        guard let containingScreen = NSScreen.screens.first(where: { screen in
            screen.frame.intersects(windowFrame)
        }) else {
            return NSScreen.main?.backingScaleFactor ?? 2.0
        }

        // Get this screen's native backing scale factor
        return containingScreen.backingScaleFactor
    }

    private static func getCachedImage(window: SCWindow) -> CGImage? {
        if let cachedImage = imageCache[window.windowID], cachedImage.windowname == window.title, Date().timeIntervalSince(cachedImage.timestamp) <= cacheExpirySeconds {
            return cachedImage.image
        }
        return nil
    }

    static func isValidElement(_ element: AXUIElement) -> Bool {
        do {
            // Try to get the window's position
            let position = try element.position()

            // Try to get the window's size
            let size = try element.size()

            // If we can get both position and size, the window likely still exists
            return position != nil && size != nil
        } catch AxError.runtimeError {
            // If we get a runtime error, the app might be unresponsive, so we consider the element invalid
            return false
        } catch {
            // For any other errors, we also consider the element invalid
            return false
        }
    }

    static func findWindow(matchingWindow window: SCWindow, in axWindows: [AXUIElement]) -> AXUIElement? {
        if let matchedWindow = axWindows.first(where: { axWindow in
            (try? axWindow.cgWindowId()) == window.windowID
        }) {
            return matchedWindow
        }

        // Fallback metohd
        for axWindow in axWindows {
            if let windowTitle = window.title, let axTitle = try? axWindow.title(), isFuzzyMatch(windowTitle: windowTitle, axTitleString: axTitle) {
                return axWindow
            }

            if let axPosition = try? axWindow.position(), let axSize = try? axWindow.size(), axPosition != .zero, axSize != .zero {
                let positionThreshold: CGFloat = 10
                let sizeThreshold: CGFloat = 10

                let positionMatch = abs(axPosition.x - window.frame.origin.x) <= positionThreshold &&
                    abs(axPosition.y - window.frame.origin.y) <= positionThreshold

                let sizeMatch = abs(axSize.width - window.frame.size.width) <= sizeThreshold &&
                    abs(axSize.height - window.frame.size.height) <= sizeThreshold

                if positionMatch, sizeMatch {
                    return axWindow
                }
            }
        }

        return nil
    }

    static func isFuzzyMatch(windowTitle: String, axTitleString: String) -> Bool {
        let axTitleWords = axTitleString.lowercased().split(separator: " ")
        let windowTitleWords = windowTitle.lowercased().split(separator: " ")

        let matchingWords = axTitleWords.filter { windowTitleWords.contains($0) }
        let matchPercentage = Double(matchingWords.count) / Double(windowTitleWords.count)

        return matchPercentage >= 0.90 || matchPercentage.isNaN || axTitleString.lowercased().contains(windowTitle.lowercased())
    }

    static func findRunningApplicationByName(named applicationName: String) -> NSRunningApplication? {
        NSWorkspace.shared.runningApplications.first { $0.localizedName == applicationName }
    }

    static func toggleMinimize(windowInfo: WindowInfo) -> Bool? {
        if windowInfo.isMinimized {
            if windowInfo.app.isHidden {
                windowInfo.app.unhide()
            }
            do {
                try windowInfo.axElement.setAttribute(kAXMinimizedAttribute, false)
                windowInfo.app.activate()
                bringWindowToFront(windowInfo: windowInfo)
                updateWindowDateTime(windowInfo)
                return false // Successfully un-minimized
            } catch {
                print("Error un-minimizing window")
                return nil
            }
        } else {
            do {
                try windowInfo.axElement.setAttribute(kAXMinimizedAttribute, true)
                updateWindowDateTime(windowInfo)
                return true // Successfully minimized
            } catch {
                print("Error minimizing window")
                return nil
            }
        }
    }

    static func toggleHidden(windowInfo: WindowInfo) -> Bool? {
        let newHiddenState = !windowInfo.isHidden

        do {
            try windowInfo.appAxElement.setAttribute(kAXHiddenAttribute, newHiddenState)
            if !newHiddenState {
                windowInfo.app.activate()
                bringWindowToFront(windowInfo: windowInfo)
            }
            updateWindowDateTime(windowInfo)
            return newHiddenState // Successfully toggled hidden state
        } catch {
            print("Error toggling hidden state of application")
            return nil // Failed to toggle hidden state
        }
    }

    static func toggleFullScreen(windowInfo: WindowInfo) {
        if let isCurrentlyInFullScreen = try? windowInfo.axElement.isFullscreen() {
            do {
                try windowInfo.axElement.setAttribute(kAXFullscreenAttribute, !isCurrentlyInFullScreen)
            } catch {
                print("Failed to toggle full screen")
            }
        } else {
            print("Failed to determine current full screen state")
        }
    }

    static func bringWindowToFront(windowInfo: WindowInfo) {
        if let appDelegate = NSApplication.shared.delegate as? AppDelegate { // clean up lingering settings pane windows which interfere with AX actions
            appDelegate.settingsWindowController.close()
        }

        do {
            // Attempt to raise and focus the specific window
            try windowInfo.axElement.performAction(kAXRaiseAction)
            try windowInfo.axElement.performAction(kAXPressAction)
            try windowInfo.axElement.setAttribute(kAXMainAttribute, true)
            try windowInfo.axElement.setAttribute(kAXFocusedAttribute, true)
            try windowInfo.axElement.setAttribute(kAXFrontmostAttribute, true)

            if !windowInfo.app.activate() {
                // if individual windows cannot be activated, we activate and order forward the entire application
                try windowInfo.appAxElement.setAttribute(kAXFocusedAttribute, true)
                try windowInfo.appAxElement.setAttribute(kAXFrontmostAttribute, true)
                throw NSError(domain: "FailedToActivate", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to activate application"])
            }

            // If we've reached this point without throwing an error, consider it a success
            updateWindowDateTime(windowInfo)

        } catch {
            print("Failed to bring window to front: \(error)")
            // Check if the error is AxError.runtimeError
            if error is AxError {
                removeWindowFromDesktopSpaceCache(with: windowInfo.id, in: windowInfo.app.processIdentifier)
            }
        }
    }

    static func updateWindowDateTime(_ windowInfo: WindowInfo) {
        guard Defaults[.sortWindowsByDate] else { return }
        desktopSpaceWindowCacheManager.updateCache(pid: windowInfo.app.processIdentifier) { windowSet in
            if let index = windowSet.firstIndex(where: { $0.id == windowInfo.id }) {
                var updatedWindow = windowSet[index]
                updatedWindow.date = Date()
                windowSet.remove(at: index)
                windowSet.insert(updatedWindow)
            }
        }
    }

    static func updateWindowDateTime(for app: NSRunningApplication) {
        guard Defaults[.sortWindowsByDate] else { return }
        desktopSpaceWindowCacheManager.updateCache(pid: app.processIdentifier) { windowSet in
            if windowSet.isEmpty {
                return
            }
            let appElement = AXUIElementCreateApplication(app.processIdentifier)
            if let windows = try? appElement.windows() {
                for window in windows {
                    if let cgWindowId = try? window.cgWindowId(), let index = windowSet.firstIndex(where: { $0.id == cgWindowId }) {
                        var updatedWindow = windowSet[index]
                        updatedWindow.date = Date()
                        windowSet.remove(at: index)
                        windowSet.insert(updatedWindow)
                        return
                    }
                }
            }
        }
    }

    static func updateStatusOfWindowCache(pid: pid_t, isParentAppHidden: Bool) {
        let appElement = AXUIElementCreateApplication(pid)
        desktopSpaceWindowCacheManager.updateCache(pid: pid) { cachedWindows in
            if let windows = try? appElement.windows() {
                for window in windows {
                    if let cgWindowId = try? window.cgWindowId() {
                        let isMinimized: Bool = (try? window.isMinimized()) ?? false
                        cachedWindows = Set(cachedWindows.map { windowInfo in
                            var updatedWindow = windowInfo
                            if windowInfo.id == cgWindowId {
                                updatedWindow.isMinimized = isMinimized
                                updatedWindow.isHidden = isParentAppHidden
                            }
                            return updatedWindow
                        })
                    }
                }
            }

            // Always update for parent app hidden status, which can be blanket applied
            cachedWindows = Set(cachedWindows.map { windowInfo in
                var updatedWindow = windowInfo
                updatedWindow.isHidden = isParentAppHidden
                return updatedWindow
            })
        }
    }

    static func closeWindow(windowInfo: WindowInfo) {
        guard windowInfo.closeButton != nil else {
            print("Error: closeButton is nil.")
            return
        }

        do {
            try windowInfo.closeButton?.performAction(kAXPressAction)
            removeWindowFromDesktopSpaceCache(with: windowInfo.id, in: windowInfo.app.processIdentifier)
        } catch {
            print("Error closing window")
            return
        }
    }

    static func quitApp(windowInfo: WindowInfo, force: Bool) {
        if force {
            windowInfo.app.forceTerminate()
        } else {
            windowInfo.app.terminate()
        }
        purgeAppCache(with: windowInfo.app.processIdentifier)
    }

    // MARK: - Active Window Handling

    static func getAllWindowsOfAllApps() -> [WindowInfo] {
        var windows = desktopSpaceWindowCacheManager.getAllWindows()

        if !Defaults[.includeHiddenWindowsInSwitcher] {
            var windowsCopy: [WindowInfo] = []
            for window in windows {
                if !window.isHidden, !window.isMinimized {
                    windowsCopy.append(window)
                }
            }

            windows = windowsCopy
        }

        // If there are at least two windows, swap the first and second
        if windows.count >= 2, Defaults[.sortWindowsByDate] {
            var modifiedWindows = windows
            modifiedWindows.swapAt(0, 1)
            return modifiedWindows
        } else {
            return windows
        }
    }

    static func getActiveWindows(of app: NSRunningApplication) async throws -> [WindowInfo] {
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)

        let group = LimitedTaskGroup<Void>(maxConcurrentTasks: 4)

        for window in content.windows where window.owningApplication?.processID == app.processIdentifier {
            await group.addTask { try await captureAndCacheWindowInfo(window: window, app: app) }
        }

        // Wait for all tasks to complete
        _ = try await group.waitForAll()

        if let purifiedWindows = await WindowUtil.purifyAppCache(with: app.processIdentifier, removeAll: false) {
            let windows = purifiedWindows.sorted(by: { $0.date > $1.date })
            guard !Defaults[.ignoreAppsWithSingleWindow] || windows.count > 1 else { return [] }
            return windows
        }

        return []
    }

    static func updateAllWindowsInCurrentSpace() async {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false)

            let group = LimitedTaskGroup<Void>(maxConcurrentTasks: 4)

            for window in content.windows {
                guard let scApp = window.owningApplication,
                      !filteredBundleIdentifiers.contains(scApp.bundleIdentifier)
                else {
                    continue
                }

                // Convert SCRunningApplication to NSRunningApplication
                if let nsApp = NSRunningApplication(processIdentifier: scApp.processID) {
                    await group.addTask { try? await captureAndCacheWindowInfo(window: window, app: nsApp) }
                }
            }

            // Wait for all tasks to complete
            _ = try await group.waitForAll()

        } catch {
            print("Error updating windows: \(error)")
        }
    }

    static func captureAndCacheWindowInfo(window: SCWindow, app: NSRunningApplication) async throws {
        let windowID = window.windowID

        guard window.owningApplication != nil,
              window.isOnScreen,
              window.windowLayer == 0,
              window.frame.size.width >= 0,
              window.frame.size.height >= 0,
              app.bundleIdentifier == nil || !filteredBundleIdentifiers.contains(app.bundleIdentifier!),
              !(window.frame.size.width < 100 || window.frame.size.height < 100) || window.title?.isEmpty == false
        else {
            return
        }

        let appElement = AXUIElementCreateApplication(app.processIdentifier)

        guard let axWindows = try? appElement.windows(), !axWindows.isEmpty else {
            return
        }

        guard let windowRef = findWindow(matchingWindow: window, in: axWindows) else {
            return
        }

        let closeButton = try? windowRef.closeButton()

        var windowInfo = WindowInfo(id: windowID,
                                    window: window,
                                    app: app,
                                    windowName: window.title,
                                    image: nil,
                                    axElement: windowRef,
                                    appAxElement: appElement,
                                    closeButton: closeButton,
                                    isMinimized: false,
                                    isHidden: false,
                                    date: Date.now)

        do {
            windowInfo.image = try await captureWindowImage(window: window)
            updateDesktopSpaceWindowCache(with: windowInfo)
        } catch {
            print("Error capturing window image: \(error)")
        }
    }

    static func updateDesktopSpaceWindowCache(with windowInfo: WindowInfo) {
        desktopSpaceWindowCacheManager.updateCache(pid: windowInfo.app.processIdentifier) { windowSet in
            if let matchingWindow = windowSet.first(where: { $0.id == windowInfo.id }) {
                var matchingWindowCopy = matchingWindow
                matchingWindowCopy.windowName = windowInfo.windowName
                matchingWindowCopy.image = windowInfo.image
                matchingWindowCopy.isHidden = windowInfo.isHidden
                matchingWindowCopy.isMinimized = windowInfo.isMinimized
                windowSet.remove(matchingWindow)
                windowSet.insert(matchingWindowCopy)
            } else {
                windowSet.insert(windowInfo)
            }
        }
    }

    static func removeWindowFromDesktopSpaceCache(with windowId: CGWindowID, in pid: pid_t) {
        desktopSpaceWindowCacheManager.removeFromCache(pid: pid, windowId: windowId)
    }

    static func purifyAppCache(with pid: pid_t, removeAll: Bool) async -> Set<WindowInfo>? {
        if removeAll {
            desktopSpaceWindowCacheManager.writeCache(pid: pid, windowSet: [])
            return nil
        } else {
            let existingWindowsSet = desktopSpaceWindowCacheManager.readCache(pid: pid)
            if existingWindowsSet.isEmpty {
                return nil
            }

            var purifiedSet = existingWindowsSet
            for window in existingWindowsSet {
                if !isValidElement(window.axElement) {
                    purifiedSet.remove(window)
                    desktopSpaceWindowCacheManager.removeFromCache(pid: pid, windowId: window.id)
                }
            }
            return purifiedSet
        }
    }

    static func purgeAppCache(with pid: pid_t) {
        desktopSpaceWindowCacheManager.writeCache(pid: pid, windowSet: [])
    }
}
