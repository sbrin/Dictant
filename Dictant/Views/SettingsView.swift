//
//  SettingsView.swift
//  Dictant
//

import SwiftUI
import AppKit

struct SettingsView: View {
    @StateObject private var settingsManager = SettingsManager.shared
    @StateObject private var speechViewModel = SimpleSpeechViewModel.shared
    
    var body: some View {
        HStack(spacing: 0) {
            List(selection: $settingsManager.selectedTab) {
                Label("General", systemImage: "gearshape")
                    .tag("General")
                
                Label("Processing", systemImage: "key.fill")
                    .tag("Processing")
                
                Label("History", systemImage: "recordingtape")
                    .tag("History")
            }
            .listStyle(.sidebar)
            .frame(width: 150)
            
            Divider()
            
            VStack(alignment: .leading) {
                switch settingsManager.selectedTab {
                case "General":
                    GeneralSettingsView()
                        .frame(maxWidth: .infinity, alignment: .leading)
                case "Processing":
                    CredentialsView()
                        .frame(maxWidth: .infinity, alignment: .leading)
                case "History":
                    RecordingsView()
                        .frame(maxWidth: .infinity, alignment: .leading)
                default:
                    GeneralSettingsView()
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Color(NSColor.windowBackgroundColor))
        }
        .frame(width: 600, height: 500)
    }
}

#if DEBUG
#Preview {
    SettingsView()
}
#endif
