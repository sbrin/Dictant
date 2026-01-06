//
//  GeneralSettingsView.swift
//  Dictant
//

import SwiftUI
import Combine
import AppKit
import ApplicationServices

struct GeneralSettingsView: View {
    @StateObject private var settingsManager = SettingsManager.shared
    @State private var accessibilityTrusted = AXIsProcessTrusted()
    
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("General")
                .font(.title2)
                .fontWeight(.bold)
            
            VStack(alignment: .leading, spacing: 6) {
                SettingToggleRow(
                    title: "Run at system startup",
                    isOn: $settingsManager.launchAtLogin
                )
                
                Divider()
                
                SettingToggleRow(
                    title: "Copy transcribed text to clipboard",
                    isOn: $settingsManager.copyTranscribedTextToClipboard
                )
                
                Divider()
                
                SettingToggleRow(
                    title: "Hold right Command key for Push-to-Talk",
                    isOn: $settingsManager.holdRightCommandForPTT
                )
                
                Divider()
                
                SettingToggleRow(
                    title: "Paste transcribed text into active input",
                    isOn: $settingsManager.pasteTranscribedTextIntoActiveInput,
                    onChange: handlePasteToggleChange
                )
            }
            
            if !accessibilityTrusted {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Accessibility access is required to paste transcriptions into the active input. Enable it in System Settings.")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    
                    Button("Open Accessibility Settings") {
                        openAccessibilitySettings()
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            
            Spacer()
        }
        .padding(20)
        .onAppear(perform: refreshAccessibilityStatus)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshAccessibilityStatus()
        }
    }
    
    private func refreshAccessibilityStatus() {
        accessibilityTrusted = AXIsProcessTrusted()
    }
    
    private func handlePasteToggleChange(isEnabled: Bool) {
        guard isEnabled else { return }
        
        if AXIsProcessTrusted() {
            accessibilityTrusted = true
            return
        }
        
        let options: CFDictionary = [
            kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true
        ] as CFDictionary
        accessibilityTrusted = AXIsProcessTrustedWithOptions(options)
    }
    
    private func openAccessibilitySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") else {
            return
        }
        NSWorkspace.shared.open(url)
    }
}

struct SettingToggleRow: View {
    let title: String
    @Binding var isOn: Bool
    var onChange: ((Bool) -> Void)?
    
    var body: some View {
        HStack(spacing: 12) {
            Text(title)
                .frame(maxWidth: .infinity, alignment: .leading)
            
            Toggle("", isOn: $isOn)
                .labelsHidden()
                .toggleStyle(SwitchToggleStyle(tint: .accentColor))
                .scaleEffect(0.7, anchor: .center)
                .onChange(of: isOn) { _, newValue in
                    onChange?(newValue)
                }
        }
    }
}
