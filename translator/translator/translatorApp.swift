//
//  translatorApp.swift
//  translator
//
//  Created by 徐力航 on 2025/11/27.
//

import SwiftUI

@main
struct translatorApp: App {
    @StateObject private var server = TranslationServer()
    
    var body: some Scene {
        WindowGroup {
            ContentView(server: server)
                .onAppear {
                    server.start()
                }
                .onDisappear {
                    server.stop()
                }
        }
        .windowStyle(.hiddenTitleBar)
    }
}
