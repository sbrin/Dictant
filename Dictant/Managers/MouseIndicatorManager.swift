//
//  MouseIndicatorManager.swift
//  Dictant
//

import AppKit
import Combine

@MainActor
final class MouseIndicatorManager: NSObject {
    static let shared = MouseIndicatorManager()

    private let viewModel = SimpleSpeechViewModel.shared
    private var cancellables = Set<AnyCancellable>()

    private var indicatorWindow: NSPanel?
    private var dotView: MouseIndicatorDotView?
    private var flashTimer: Timer?
    private var isFlashedOn = true
    private var flashDotColor: NSColor?
    private var globalMouseMonitor: Any?
    private var localMouseMonitor: Any?

    private let dotSize: CGFloat = 10
    private let dotOffset = CGPoint(x: 15, y: -15)

    private override init() {
        super.init()
        setupBindings()
    }

    private func setupBindings() {
        viewModel.$isRecording
            .combineLatest(viewModel.$isProcessing)
            .receive(on: RunLoop.main)
            .sink { [weak self] isRecording, isProcessing in
                self?.updateIndicatorState(isRecording: isRecording, isProcessing: isProcessing)
            }
            .store(in: &cancellables)
    }

    private func updateIndicatorState(isRecording: Bool, isProcessing: Bool) {
        if isRecording {
            startFlashing(dotColor: .systemRed)
        } else if isProcessing {
            startFlashing(dotColor: .systemGreen)
        } else {
            stopFlashing()
            stopMouseTracking()
            hideIndicator()
        }
    }

    private func startFlashing(dotColor: NSColor) {
        ensureIndicatorWindow()
        startMouseTracking()
        updateIndicatorPosition()

        let colorChanged = flashDotColor != dotColor
        flashDotColor = dotColor
        dotView?.dotColor = dotColor

        if flashTimer == nil {
            isFlashedOn = true
            showIndicator()
            let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    self.isFlashedOn.toggle()
                    self.indicatorWindow?.alphaValue = self.isFlashedOn ? 1 : 0
                }
            }
            RunLoop.main.add(timer, forMode: .common)
            flashTimer = timer
        } else if colorChanged {
            isFlashedOn = true
            showIndicator()
        }
    }

    private func stopFlashing() {
        flashTimer?.invalidate()
        flashTimer = nil
        isFlashedOn = true
        flashDotColor = nil
        dotView?.dotColor = nil
    }

    private func showIndicator() {
        guard let indicatorWindow else { return }
        indicatorWindow.alphaValue = 1
        indicatorWindow.orderFrontRegardless()
    }

    private func hideIndicator() {
        indicatorWindow?.alphaValue = 0
        indicatorWindow?.orderOut(nil)
    }

    private func ensureIndicatorWindow() {
        guard indicatorWindow == nil else { return }

        let frame = NSRect(x: 0, y: 0, width: dotSize, height: dotSize)
        let dotView = MouseIndicatorDotView(frame: frame)

        let panel = NSPanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.contentView = dotView
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.isReleasedWhenClosed = false
        panel.alphaValue = 0

        indicatorWindow = panel
        self.dotView = dotView
    }

    private func updateIndicatorPosition() {
        guard indicatorWindow != nil else { return }
        let mouseLocation = NSEvent.mouseLocation
        let origin = NSPoint(
            x: mouseLocation.x + dotOffset.x - dotSize / 2,
            y: mouseLocation.y + dotOffset.y - dotSize / 2
        )
        indicatorWindow?.setFrameOrigin(origin)
    }

    private func startMouseTracking() {
        if globalMouseMonitor == nil {
            globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(
                matching: [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged]
            ) { [weak self] _ in
                Task { @MainActor in
                    self?.updateIndicatorPosition()
                }
            }
        }

        if localMouseMonitor == nil {
            localMouseMonitor = NSEvent.addLocalMonitorForEvents(
                matching: [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged]
            ) { [weak self] event in
                Task { @MainActor in
                    self?.updateIndicatorPosition()
                }
                return event
            }
        }
    }

    private func stopMouseTracking() {
        if let monitor = globalMouseMonitor {
            NSEvent.removeMonitor(monitor)
            globalMouseMonitor = nil
        }

        if let monitor = localMouseMonitor {
            NSEvent.removeMonitor(monitor)
            localMouseMonitor = nil
        }
    }
}

final class MouseIndicatorDotView: NSView {
    var dotColor: NSColor? {
        didSet {
            needsDisplay = true
        }
    }

    override var isOpaque: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let dotColor else { return }
        dotColor.setFill()
        let path = NSBezierPath(ovalIn: bounds)
        path.fill()
    }
}
