//  DictantApp.swift
//  Dictant
//

import SwiftUI
@main
struct DictantApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    
    var body: some Scene {
        Settings {
            SettingsView()
        }
    }
}
