//
//  KeyboardManager.swift
//  Dictant
//

import AppKit
import Combine
import UserNotifications

@MainActor
class KeyboardManager: NSObject {
    static let shared = KeyboardManager()
    
    private let settingsManager = SettingsManager.shared
    private var isRightCommandPressed = false
    private var pttTimer: Timer?
    private var isPTTActive = false
    
    private override init() {
        super.init()
    }
    
    func startMonitoring() {
        checkAccessibilityPermissions()
        
        print("KeyboardManager: Starting global and local monitoring...")
        
        // Monitor flagsChanged events globally (outside the app)
        NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            print("KeyboardManager: Global FlagsChanged - KeyCode: \(event.keyCode), Flags: \(event.modifierFlags)")
            Task { @MainActor in
                self?.handleFlagsChanged(event)
            }
        }
        
        // Also monitor locally (inside the app)
        NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            print("KeyboardManager: Local FlagsChanged - KeyCode: \(event.keyCode), Flags: \(event.modifierFlags)")
            self?.handleFlagsChanged(event)
            return event
        }
        
        print("KeyboardManager: Monitoring active.")
    }
    
    private func handleFlagsChanged(_ event: NSEvent) {
        // Only proceed if Push-to-Talk is enabled in settings
        guard settingsManager.holdRightCommandForPTT else { return }
        
        // Key code for Right Command is 54
        if event.keyCode == 54 {
            // Check if Command flag is set
            let isPressed = event.modifierFlags.contains(.command)
            print("KeyboardManager: Right Command event detected. Pressed: \(isPressed)")
            
            if isPressed {
                if !isRightCommandPressed {
                    print("KeyboardManager: Right Command DOWN")
                    isRightCommandPressed = true
                    startPTTTimer()
                }
            } else {
                if isRightCommandPressed {
                    print("KeyboardManager: Right Command UP")
                    isRightCommandPressed = false
                    stopPTT()
                }
            }
        }
    }
    
    private func startPTTTimer() {
        print("KeyboardManager: Starting 1.0s PTT timer...")
        pttTimer?.invalidate()
        pttTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.activatePTT()
            }
        }
    }
    
    private func activatePTT() {
        guard isRightCommandPressed && !isPTTActive else {
            print("KeyboardManager: PTT activation cancelled (key released or already active)")
            return
        }
        
        // Don't start PTT if already recording or processing
        guard !SimpleSpeechViewModel.shared.isRecording && !SimpleSpeechViewModel.shared.isProcessing else {
            print("KeyboardManager: PTT activation skipped (already recording or processing)")
            return
        }
        
        isPTTActive = true
        print("KeyboardManager: >>> PTT ACTIVATED (1s passed) <<<")
        Task {
            await SimpleSpeechViewModel.shared.startRecording()
        }
    }
    
    private func stopPTT() {
        print("KeyboardManager: Stopping PTT status...")
        pttTimer?.invalidate()
        pttTimer = nil
        
        if isPTTActive {
            isPTTActive = false
            print("KeyboardManager: <<< PTT DEACTIVATED >>>")
            Task {
                await SimpleSpeechViewModel.shared.stopRecording()
            }
        }
    }

    private func checkAccessibilityPermissions() {
        let options: CFDictionary = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        let isTrusted = AXIsProcessTrustedWithOptions(options)
        
        #if DEBUG
        print("KeyboardManager: Accessibility permissions - \(isTrusted ? "Granted" : "Not Granted")")
        #endif
        
        if !isTrusted {
            // Show a system notification
            let content = UNMutableNotificationContent()
            content.title = "Accessibility Access Required"
            content.body = "Please enable Accessibility for Dictant in System Settings to use the global Push-to-Talk hotkey."
            content.categoryIdentifier = "ACCESSIBILITY_PERMISSION"
            content.sound = .default
            
            let request = UNNotificationRequest(identifier: "accessibility_warning", content: content, trigger: nil)
            UNUserNotificationCenter.current().add(request)
            
            SimpleSpeechViewModel.shared.error = "Accessibility access is required for the global Push-to-Talk hotkey."
        }
    }
}
