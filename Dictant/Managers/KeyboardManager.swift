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
    private let rightCommandKeyCode: UInt16 = 54
    private var isRightCommandPressed = false
    private var pttTimer: Timer?
    private var isPTTActive = false
    
    private override init() {
        super.init()
    }
    
    func startMonitoring() {
        checkAccessibilityPermissions()
        
        #if DEBUG
        print("KeyboardManager: Starting global and local monitoring...")
        #endif
        
        // Monitor flagsChanged events globally (outside the app)
        NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            guard let self, event.keyCode == self.rightCommandKeyCode else { return }
            #if DEBUG
            print("KeyboardManager: Global Right Command FlagsChanged - Flags: \(event.modifierFlags)")
            #endif
            Task { @MainActor in
                self?.handleFlagsChanged(event)
            }
        }
        
        // Also monitor locally (inside the app)
        NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            guard let self, event.keyCode == self.rightCommandKeyCode else { return event }
            #if DEBUG
            print("KeyboardManager: Local Right Command FlagsChanged - Flags: \(event.modifierFlags)")
            #endif
            self?.handleFlagsChanged(event)
            return event
        }
        
        #if DEBUG
        print("KeyboardManager: Monitoring active.")
        #endif
    }
    
    private func handleFlagsChanged(_ event: NSEvent) {
        // Only proceed if Push-to-Talk is enabled in settings
        guard settingsManager.holdRightCommandForPTT else { return }
        
        // Check if Command flag is set
        let isPressed = event.modifierFlags.contains(.command)
        #if DEBUG
        print("KeyboardManager: Right Command event detected. Pressed: \(isPressed)")
        #endif
        
        if isPressed {
            if !isRightCommandPressed {
                #if DEBUG
                print("KeyboardManager: Right Command DOWN")
                #endif
                isRightCommandPressed = true
                startPTTTimer()
            }
        } else {
            if isRightCommandPressed {
                #if DEBUG
                print("KeyboardManager: Right Command UP")
                #endif
                isRightCommandPressed = false
                stopPTT()
            }
        }
    }
    
    private func startPTTTimer() {
        #if DEBUG
        print("KeyboardManager: Starting 0.5s PTT timer...")
        #endif
        pttTimer?.invalidate()
        pttTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.activatePTT()
            }
        }
    }
    
    private func activatePTT() {
        guard isRightCommandPressed && !isPTTActive else {
            #if DEBUG
            print("KeyboardManager: PTT activation cancelled (key released or already active)")
            #endif
            return
        }
        
        // Don't start PTT if already recording or processing
        guard !SimpleSpeechViewModel.shared.isRecording && !SimpleSpeechViewModel.shared.isProcessing else {
            #if DEBUG
            print("KeyboardManager: PTT activation skipped (already recording or processing)")
            #endif
            return
        }
        
        isPTTActive = true
        #if DEBUG
        print("KeyboardManager: >>> PTT ACTIVATED (0.5s passed) <<<")
        #endif
        Task {
            await SimpleSpeechViewModel.shared.startRecording()
        }
    }
    
    private func stopPTT() {
        #if DEBUG
        print("KeyboardManager: Stopping PTT status...")
        #endif
        pttTimer?.invalidate()
        pttTimer = nil
        
        if isPTTActive {
            isPTTActive = false
            #if DEBUG
            print("KeyboardManager: <<< PTT DEACTIVATED >>>")
            #endif
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
