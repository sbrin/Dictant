//
//  MouseIndicatorManager.swift
//  Dictant
//

import AppKit
import Combine
import QuartzCore

@MainActor
final class MouseIndicatorManager: NSObject {
    static let shared = MouseIndicatorManager()

    private let viewModel = SimpleSpeechViewModel.shared
    private var cancellables = Set<AnyCancellable>()

    private var indicatorWindow: NSPanel?
    private var dotView: MouseIndicatorDotView?
    private var globalMouseMonitor: Any?
    private var localMouseMonitor: Any?

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
            startIndicatorAnimation(dotColor: .systemRed)
        } else if isProcessing {
            startIndicatorAnimation(dotColor: .systemGreen)
        } else {
            stopIndicatorAnimation()
            stopMouseTracking()
            hideIndicator()
        }
    }

    private func startIndicatorAnimation(dotColor: NSColor) {
        ensureIndicatorWindow()
        startMouseTracking()
        updateIndicatorPosition()

        dotView?.setIndicatorColor(dotColor)
        dotView?.startAnimating()
        showIndicator()
    }

    private func stopIndicatorAnimation() {
        dotView?.stopAnimating()
        dotView?.setIndicatorColor(nil)
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

        let frame = NSRect(
            x: 0,
            y: 0,
            width: Constants.UI.mouseIndicatorCanvasSize,
            height: Constants.UI.mouseIndicatorCanvasSize
        )
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
        let indicatorSize = Constants.UI.mouseIndicatorCanvasSize
        let origin = NSPoint(
            x: mouseLocation.x + Constants.UI.mouseIndicatorDotOffset.x - indicatorSize / 2,
            y: mouseLocation.y + Constants.UI.mouseIndicatorDotOffset.y - indicatorSize / 2
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
    private let centerDotLayer = CAShapeLayer()
    private let pulseLayerA = CAShapeLayer()
    private let pulseLayerB = CAShapeLayer()
    private var indicatorColor: NSColor?
    private var isAnimating = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupLayers()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupLayers()
    }

    override var isOpaque: Bool { false }

    override func layout() {
        super.layout()
        updateLayerGeometry()
    }

    func setIndicatorColor(_ color: NSColor?) {
        indicatorColor = color
        updateLayerColors()
    }

    func startAnimating() {
        guard indicatorColor != nil else { return }
        if isAnimating {
            return
        }

        isAnimating = true
        addPulseAnimation(to: pulseLayerA, beginTimeOffset: 0)
        addPulseAnimation(to: pulseLayerB, beginTimeOffset: Constants.UI.mouseIndicatorPulseStagger)
    }

    func stopAnimating() {
        isAnimating = false
        pulseLayerA.removeAllAnimations()
        pulseLayerB.removeAllAnimations()
        pulseLayerA.opacity = 0
        pulseLayerB.opacity = 0
    }

    private func setupLayers() {
        wantsLayer = true
        layer?.masksToBounds = false

        [pulseLayerA, pulseLayerB, centerDotLayer].forEach { shapeLayer in
            shapeLayer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
            shapeLayer.opacity = 0
            layer?.addSublayer(shapeLayer)
        }

        centerDotLayer.opacity = 1
        updateLayerGeometry()
        updateLayerColors()
    }

    private func updateLayerGeometry() {
        let dotSize = Constants.UI.mouseIndicatorDotSize
        let dotRect = CGRect(
            x: bounds.midX - (dotSize / 2),
            y: bounds.midY - (dotSize / 2),
            width: dotSize,
            height: dotSize
        )
        let circlePath = CGPath(ellipseIn: dotRect, transform: nil)

        [centerDotLayer, pulseLayerA, pulseLayerB].forEach { shapeLayer in
            shapeLayer.path = circlePath
            shapeLayer.frame = bounds
        }
    }

    private func updateLayerColors() {
        guard let indicatorColor else {
            centerDotLayer.fillColor = nil
            pulseLayerA.fillColor = nil
            pulseLayerB.fillColor = nil
            stopAnimating()
            return
        }

        centerDotLayer.fillColor = indicatorColor.cgColor
        let pulseColor = indicatorColor.withAlphaComponent(0.6).cgColor
        pulseLayerA.fillColor = pulseColor
        pulseLayerB.fillColor = pulseColor

        if !isAnimating {
            pulseLayerA.opacity = 0
            pulseLayerB.opacity = 0
        }
    }

    private func addPulseAnimation(to layer: CAShapeLayer, beginTimeOffset: TimeInterval) {
        layer.removeAllAnimations()
        layer.transform = CATransform3DIdentity
        layer.opacity = 0

        let duration = Constants.UI.mouseIndicatorPulseDuration

        let scale = CABasicAnimation(keyPath: "transform.scale")
        scale.fromValue = 1.0
        scale.toValue = Constants.UI.mouseIndicatorPulseMaxScale
        scale.duration = duration

        let opacity = CABasicAnimation(keyPath: "opacity")
        opacity.fromValue = Constants.UI.mouseIndicatorPulseOpacity
        opacity.toValue = 0.0
        opacity.duration = duration

        let group = CAAnimationGroup()
        group.animations = [scale, opacity]
        group.duration = duration
        group.timingFunction = CAMediaTimingFunction(name: .easeOut)
        group.repeatCount = .infinity
        group.isRemovedOnCompletion = false
        group.beginTime = CACurrentMediaTime() + beginTimeOffset

        layer.add(group, forKey: "pulse")
    }
}
