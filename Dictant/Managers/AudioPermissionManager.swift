//
//  AudioPermissionManager.swift
//  Dictant
//

import AVFoundation
#if os(macOS)
import AppKit
#endif

@MainActor
class AudioPermissionManager: ObservableObject {
    static let shared = AudioPermissionManager()
    
    @Published var hasPermission = false
    @Published var error: String?
    
    private init() {}
    
    func checkMicrophonePermission() {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        switch status {
        case .authorized:
            hasPermission = true
            error = nil
        case .denied, .restricted:
            hasPermission = false
            error = "Microphone access denied. Click 'Open Settings' to grant permission."
        case .notDetermined:
            hasPermission = false
            error = "Microphone permission not determined. Click 'Start Recording' to request permission."
        @unknown default:
            hasPermission = false
            error = "Unknown microphone permission status."
        }
    }
    
    func requestMicrophonePermission() async -> Bool {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        
        switch status {
        case .authorized:
            await MainActor.run {
                hasPermission = true
                error = nil
            }
            return true
            
        case .denied:
            await MainActor.run {
                hasPermission = false
                error = "Microphone access denied. Please check System Preferences > Privacy & Security > Microphone and enable access for this app."
            }
            return false
            
        case .restricted:
            await MainActor.run {
                hasPermission = false
                error = "Microphone access is restricted on this device."
            }
            return false
            
        case .notDetermined:
            let granted = await AVCaptureDevice.requestAccess(for: .audio)
            await MainActor.run {
                hasPermission = granted
                if !granted {
                    error = "Microphone access denied. Please check System Preferences > Privacy & Security > Microphone and enable access for this app."
                } else {
                    error = nil
                }
            }
            return granted
            
        @unknown default:
            await MainActor.run {
                hasPermission = false
                error = "Unknown microphone permission status."
            }
            return false
        }
    }
    
    func openSystemPreferences() {
        #if os(macOS)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
            NSWorkspace.shared.open(url)
        }
        #endif
    }
}
