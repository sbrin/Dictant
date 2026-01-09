//
//  AppDelegate.swift
//  Dictant
//

import AppKit
import UserNotifications
import ApplicationServices

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    
    private var statusItemManager: StatusItemManager?
    private var mouseIndicatorManager: MouseIndicatorManager?
    
    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        alignPasteSettingWithAccessibilityPermission()
        // Initialize StatusItemManager
        statusItemManager = StatusItemManager.shared
        mouseIndicatorManager = MouseIndicatorManager.shared
        
        // Start Global Keyboard Monitoring
        KeyboardManager.shared.startMonitoring()
        
        setupNotificationCategories()
        setupNotifications()
    }
    
    private func alignPasteSettingWithAccessibilityPermission() {
        let settingsManager = SettingsManager.shared
        if !AXIsProcessTrusted() && settingsManager.pasteTranscribedTextIntoActiveInput {
            settingsManager.pasteTranscribedTextIntoActiveInput = false
        }
    }
    
    func setupNotificationCategories() {
        let openSettingsAction = UNNotificationAction(
            identifier: "OPEN_SETTINGS_ACTION",
            title: "Open Settings",
            options: [.foreground]
        )
        let openMicrophoneSettingsAction = UNNotificationAction(
            identifier: "OPEN_MICROPHONE_SETTINGS_ACTION",
            title: "Open Microphone Settings",
            options: [.foreground]
        )
        
        let accessibilityCategory = UNNotificationCategory(
            identifier: "ACCESSIBILITY_PERMISSION",
            actions: [openSettingsAction],
            intentIdentifiers: [],
            options: .customDismissAction
        )
        
        let microphoneCategory = UNNotificationCategory(
            identifier: "MICROPHONE_PERMISSION",
            actions: [openMicrophoneSettingsAction],
            intentIdentifiers: [],
            options: .customDismissAction
        )
        
        UNUserNotificationCenter.current().setNotificationCategories([accessibilityCategory, microphoneCategory])
    }
    
    func setupNotifications() {
        UNUserNotificationCenter.current().delegate = self
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, error in
            if let error = error {
                print("AppDelegate: Error requesting notification auth: \(error)")
            } else {
                print("AppDelegate: Notification auth granted: \(granted)")
            }
        }
    }
    
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
    
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        let actionIdentifier = response.actionIdentifier
        let categoryIdentifier = response.notification.request.content.categoryIdentifier
        
        if categoryIdentifier == "ACCESSIBILITY_PERMISSION" {
            // Either clicked the button OR the notification itself
            if actionIdentifier == "OPEN_SETTINGS_ACTION" || actionIdentifier == UNNotificationDefaultActionIdentifier {
                Task { @MainActor in
                    guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") else {
                        return
                    }
                    NSWorkspace.shared.open(url)
                }
            }
        } else if categoryIdentifier == "MICROPHONE_PERMISSION" {
            if actionIdentifier == "OPEN_MICROPHONE_SETTINGS_ACTION" || actionIdentifier == UNNotificationDefaultActionIdentifier {
                Task { @MainActor in
                    AudioPermissionManager.shared.openSystemPreferences()
                }
            }
        }
        
        completionHandler()
    }
}
