//  StatusItemManager.swift
//  Dictant
//

import AppKit
import SwiftUI
import Combine

@MainActor
class StatusItemManager: NSObject, NSMenuDelegate, NSWindowDelegate {
    static let shared = StatusItemManager()
    
    private var statusItem: NSStatusItem?
    private let viewModel = SimpleSpeechViewModel.shared
    private var cancellables = Set<AnyCancellable>()
    private var flashTimer: Timer?
    private var isFlashedOn = true
    private var flashDotColor: NSColor?
    private weak var activeMenu: NSMenu?
    private var settingsWindow: NSWindow?
    private let statusIconSize = NSSize(width: 22, height: 22)
    private var appearanceObservation: NSKeyValueObservation?
    
    private func applyAppearance(to menu: NSMenu) {
        // Keep the menu in sync with the system appearance (light/dark/high contrast).
        let appearance = statusItem?.button?.effectiveAppearance ?? NSApp.effectiveAppearance
        let darkAppearances: [NSAppearance.Name] = [
            .darkAqua,
            .vibrantDark,
            .accessibilityHighContrastDarkAqua,
            .accessibilityHighContrastVibrantDark
        ]
        let lightAppearances: [NSAppearance.Name] = [
            .aqua,
            .vibrantLight,
            .accessibilityHighContrastAqua,
            .accessibilityHighContrastVibrantLight
        ]
        let bestMatch = appearance.bestMatch(from: darkAppearances + lightAppearances)
        let isDark = bestMatch.map { darkAppearances.contains($0) } ?? false
        menu.appearance = NSAppearance(named: isDark ? .vibrantDark : .vibrantLight)
    }
    
    private override init() {
        super.init()
        setupStatusItem()
        setupBindings()
    }
    
    func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        
        if let button = statusItem?.button {
            button.image = drawStatusIcon()
            button.target = self
            button.action = #selector(handleStatusItemAction(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        observeAppearanceChanges()
    }
    
    private func statusIconAsset() -> NSImage? {
        if let image = NSImage(named: "logo-icon")?.copy() as? NSImage {
            return image
        }
        return nil
    }
    
    private func resolvedBaseColor(for appearance: NSAppearance) -> NSColor {
        // Resolve the label color in the context of the status bar button appearance so the icon
        // follows the actual menu bar tint (e.g., dark wallpaper while the system is in Light mode).
        var resolvedColor = NSColor.labelColor
        appearance.performAsCurrentDrawingAppearance {
            resolvedColor = NSColor.labelColor
        }
        return resolvedColor
    }
    
    private func statusIconRect(for image: NSImage) -> NSRect {
        let scale = min(statusIconSize.width / image.size.width, statusIconSize.height / image.size.height)
        let drawSize = NSSize(width: image.size.width * scale, height: image.size.height * scale)
        
        return NSRect(
            x: (statusIconSize.width - drawSize.width) / 2,
            y: (statusIconSize.height - drawSize.height) / 2,
            width: drawSize.width,
            height: drawSize.height
        )
    }
    
    private func drawStatusIcon(dotColor: NSColor? = nil) -> NSImage? {
        guard let baseImage = statusIconAsset() else { return nil }
        
        let image = NSImage(size: statusIconSize)
        image.lockFocus()
        
        let appearance = statusItem?.button?.effectiveAppearance ?? NSApp.effectiveAppearance
        appearance.performAsCurrentDrawingAppearance {
            let drawRect = statusIconRect(for: baseImage)
            
            let baseColor = resolvedBaseColor(for: appearance)
            baseColor.setFill()
            drawRect.fill()
            baseImage.draw(in: drawRect, from: NSRect(origin: .zero, size: baseImage.size), operation: .destinationIn, fraction: 1.0)
            
            if let dotColor = dotColor {
                let dotSize: CGFloat = 11.0
                let dotRect = NSRect(x: (statusIconSize.width - dotSize) / 2, y: 9, width: dotSize, height: dotSize)
                dotColor.setFill()
                let path = NSBezierPath(ovalIn: dotRect)
                path.fill()
            }
        }
        
        image.unlockFocus()
        image.isTemplate = false
        
        return image
    }
    
    @objc private func handleStatusItemAction(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp {
            let menu = constructMenu()
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 5), in: sender)
        } else {
            statusItemClicked()
        }
    }
    
    private func constructMenu() -> NSMenu {
        let menu = NSMenu()
        menu.delegate = self
        applyAppearance(to: menu)
        
        // 1. Action item
        let actionItem = NSMenuItem()
        actionItem.tag = 101
        updateActionItem(actionItem)
        actionItem.target = self
        menu.addItem(actionItem)
        
        // 2. Status item
        let statusItemMenu = NSMenuItem()
        statusItemMenu.tag = 100
        updateStatusItem(statusItemMenu)
        statusItemMenu.isEnabled = false
        menu.addItem(statusItemMenu)
        
        menu.addItem(NSMenuItem.separator())
        
        // 3. Settings
        let settingsItem = NSMenuItem(title: "Settings...", action: #selector(menuSettings), keyEquivalent: "")
        settingsItem.target = self
        menu.addItem(settingsItem)
        
        // 4. History
        let recordingsItem = NSMenuItem(title: "History...", action: #selector(menuRecordings), keyEquivalent: "")
        recordingsItem.target = self
        menu.addItem(recordingsItem)
        
        menu.addItem(NSMenuItem.separator())
        
        // 5. Quit
        let quitItem = NSMenuItem(title: "Quit", action: #selector(menuQuit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
        
        return menu
    }
    
    
    private func updateActionItem(_ item: NSMenuItem) {
        if viewModel.isRecording {
            item.title = "Stop Recording"
            item.action = #selector(menuStopRecording)
        } else if viewModel.isProcessing {
            item.title = "Cancel Processing"
            item.action = #selector(menuCancelProcessing)
        } else {
            item.title = "Start Recording"
            item.action = #selector(menuStartRecording)
        }
    }
    
    private func updateStatusItem(_ item: NSMenuItem) {
        if viewModel.isRecording {
            item.title = "Recording: \(viewModel.recordingDuration)"
            item.isHidden = false
        } else if viewModel.isProcessing {
            item.title = "Processing..."
            item.isHidden = false
        } else {
            item.isHidden = true
        }
    }
    
    // MARK: - NSMenuDelegate
    func menuWillOpen(_ menu: NSMenu) {
        applyAppearance(to: menu)
        activeMenu = menu
    }
    
    func menuDidClose(_ menu: NSMenu) {
        if activeMenu == menu {
            activeMenu = nil
        }
    }
    
    @objc private func menuStartRecording() {
        Task { await viewModel.startRecording() }
    }
    
    @objc private func menuStopRecording() {
        Task { await viewModel.stopRecording() }
    }
    
    @objc private func menuCancelProcessing() {
        viewModel.cancelProcessing()
    }
    
    @objc private func menuSettings() {
        SettingsManager.shared.selectedTab = "General"
        showSettingsWindow()
    }
    
    @objc private func menuRecordings() {
        SettingsManager.shared.selectedTab = "History"
        showSettingsWindow()
    }
    
    func showSettingsWindow() {
        NSApp.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
        
        if let existingWindow = settingsWindow ?? NSApp.windows.first(where: { $0.identifier?.rawValue == "dictant_settings_window" }) {
            settingsWindow = existingWindow
            existingWindow.makeKeyAndOrderFront(nil)
            return
        }
        
        // Create a new settings window
        let settingsView = SettingsView()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 550),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        
        window.identifier = NSUserInterfaceItemIdentifier("dictant_settings_window")
        window.title = "Dictant Settings"
        window.center()
        window.contentView = NSHostingView(rootView: settingsView)
        window.isReleasedWhenClosed = false
        window.delegate = self
        settingsWindow = window
        window.makeKeyAndOrderFront(nil)
    }
    
    func windowWillClose(_ notification: Notification) {
        guard
            let closingWindow = notification.object as? NSWindow,
            closingWindow == settingsWindow
        else { return }
        
        settingsWindow = nil
        NSApp.setActivationPolicy(.accessory)
    }
    
    @objc private func menuQuit() {
        NSApplication.shared.terminate(nil)
    }
    
    func setupBindings() {
        viewModel.$isRecording
            .combineLatest(viewModel.$isProcessing, viewModel.$recordingDuration)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isRecording, isProcessing, _ in
                guard let self = self else { return }
                self.updateUIState(isRecording: isRecording, isProcessing: isProcessing)
                
                // Update active menu if visible
                if let menu = self.activeMenu {
                    if let statusItem = menu.item(withTag: 100) {
                        self.updateStatusItem(statusItem)
                    }
                    if let actionItem = menu.item(withTag: 101) {
                        self.updateActionItem(actionItem)
                    }
                }
            }
            .store(in: &cancellables)
    }
    
    private func updateUIState(isRecording: Bool, isProcessing: Bool) {
        if isRecording {
            startFlashing(dotColor: .systemRed)
            statusItem?.button?.toolTip = "Recording. Click to stop."
        } else if isProcessing {
            startFlashing(dotColor: .systemGreen)
            statusItem?.button?.toolTip = "Processing..."
        } else {
            stopFlashing()
            setIdleIcon()
            statusItem?.button?.toolTip = "Click to start transcribing"
        }
    }
    
    private func startFlashing(dotColor: NSColor) {
        let colorChanged = flashDotColor != dotColor
        flashDotColor = dotColor
        
        if flashTimer == nil {
            isFlashedOn = true
            setStatusIcon(dotColor: dotColor)
            
            let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    self.isFlashedOn.toggle()
                    let currentColor = self.isFlashedOn ? self.flashDotColor : nil
                    self.setStatusIcon(dotColor: currentColor)
                }
            }
            RunLoop.main.add(timer, forMode: .common)
            flashTimer = timer
        } else if colorChanged {
            isFlashedOn = true
            setStatusIcon(dotColor: dotColor)
        }
    }
    
    private func stopFlashing() {
        flashTimer?.invalidate()
        flashTimer = nil
        isFlashedOn = true
        flashDotColor = nil
    }
    
    private func setIdleIcon() {
        updateStatusIcon()
    }
    
    private func updateStatusIcon() {
        setStatusIcon(dotColor: nil)
    }
    
    private func setStatusIcon(dotColor: NSColor?) {
        guard let button = statusItem?.button else { return }
        guard let image = drawStatusIcon(dotColor: dotColor) else { return }
        button.image = image
        button.contentTintColor = nil
    }

    private func observeAppearanceChanges() {
        appearanceObservation?.invalidate()

        // Track system appearance changes (light/dark/high contrast) so the icon and menu stay in sync across macOS versions, including Sequoia and wallpaper-tinted menu bars.
        if let button = statusItem?.button {
            appearanceObservation = button.observe(\.effectiveAppearance, options: [.initial, .new]) { [weak self] _, _ in
                Task { @MainActor in
                    guard let self else { return }
                    self.updateStatusIcon()
                    if let menu = self.activeMenu {
                        self.applyAppearance(to: menu)
                        menu.update()
                    }
                }
            }
        } else {
            appearanceObservation = NSApp.observe(\.effectiveAppearance, options: [.initial, .new]) { [weak self] _, _ in
                Task { @MainActor in
                    guard let self else { return }
                    self.updateStatusIcon()
                    if let menu = self.activeMenu {
                        self.applyAppearance(to: menu)
                        menu.update()
                    }
                }
            }
        }
    }
    
    private func statusItemClicked() {
        Task {
            await viewModel.toggleRecording()
        }
    }
}
