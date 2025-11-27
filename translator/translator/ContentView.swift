//
//  ContentView.swift
//  translator
//
//  Created by 徐力航 on 2025/11/27.
//

import SwiftUI
import Translation

struct ContentView: View {
    @ObservedObject var server: TranslationServer
    @State private var requestedPort: String = "5308"
    
    var body: some View {
        VStack(spacing: 20) {
            Text("🌐 翻译 HTTP 服务器")
                .font(.title2)
                .fontWeight(.bold)
            
            if !server.errorMessage.isEmpty {
                VStack {
                    HStack {
                        Image(systemName: "exclamationmark.triangle")
                        Text("错误")
                            .fontWeight(.bold)
                        Spacer()
                    }
                    Text(server.errorMessage)
                        .font(.caption)
                        .foregroundColor(.red)
                }
                .padding()
                .background(Color.red.opacity(0.1))
                .cornerRadius(8)
            }
            
            HStack {
                Text("请求端口:")
                TextField("0 = 自动分配", text: $requestedPort)
                    .textFieldStyle(RoundedBorderTextFieldStyle())
                    .frame(width: 100)
                    .onChange(of: requestedPort) { oldValue, newValue in
                        if !newValue.isEmpty && UInt16(newValue) == nil {
                            requestedPort = oldValue
                        }
                    }
                
                Button(server.isRunning ? "停止服务器" : "启动服务器") {
                    if server.isRunning {
                        server.stop()
                    } else {
                        let port = UInt16(requestedPort) ?? 0
                        server.start(port: port)
                    }
                }
                .buttonStyle(.borderedProminent)
            }
            
            if server.isRunning && server.actualPort != 0 {
                HStack {
                    Text("实际端口:")
                    Text("\(server.actualPort)")
                        .fontWeight(.bold)
                        .foregroundColor(.green)
                    Spacer()
                }
            }
            
            HStack {
                StatusIndicator(isRunning: server.isRunning)
                Text(server.isRunning ? "运行中" : "已停止")
                    .foregroundColor(server.isRunning ? .green : .red)
                
                Spacer()
                
                VStack(alignment: .trailing) {
                    Text("连接数: \(server.connectedClients)")
                    Text("请求数: \(server.requestCount)")
                }
                .foregroundColor(.secondary)
                .font(.caption)
            }
            
            Divider()
            
            VStack(alignment: .leading, spacing: 10) {
                Text("最后请求:")
                    .font(.headline)
                
                ScrollView {
                    Text(server.lastRequest)
                        .font(.system(.body, design: .monospaced))
                        .padding()
                        .background(Color.gray.opacity(0.1))
                        .cornerRadius(8)
                }
                .frame(height: 120)
                
                Text("最后响应:")
                    .font(.headline)
                
                Text(server.lastResponse)
                    .padding()
                    .background(Color.blue.opacity(0.1))
                    .cornerRadius(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            
            Divider()
            
            VStack(alignment: .leading, spacing: 8) {
                Text("使用示例:")
                    .font(.headline)
                
                if server.isRunning && server.actualPort != 0 {
                    Text("""
                    curl -X POST http://localhost:\(server.actualPort)/translate \\
                      -H "Content-Type: application/json" \\
                      -d '{
                        "text": "Hello, World!",
                        "source_language": "en",
                        "target_language": "zh-Hans"
                      }'
                    """)
                    .font(.system(.caption, design: .monospaced))
                    .padding()
                    .background(Color.black.opacity(0.8))
                    .foregroundColor(.white)
                    .cornerRadius(8)
                } else {
                    Text("启动服务器后显示使用示例")
                        .foregroundColor(.secondary)
                        .italic()
                }
            }
            
            Spacer()
        }
        .padding()
        .frame(width: 600, height: 700)
        // 修复：使用 translationSessionId 来确保每次重新触发
        .translationTask(server.translationConfig) { session in
            await performTranslation(with: session)
        }
        .id(server.translationSessionId) // 添加这个来强制视图刷新
    }
    
    private func performTranslation(with session: TranslationSession) async {
        let textToTranslate = server.currentTranslationText
        
        // 确保有文本需要翻译
        guard !textToTranslate.isEmpty else { return }
        
        do {
            let response = try await session.translate(textToTranslate)
            await MainActor.run {
                server.handleTranslationResult(.success(response.targetText))
            }
        } catch {
            await MainActor.run {
                server.handleTranslationResult(.failure(error))
            }
        }
    }
}

struct StatusIndicator: View {
    let isRunning: Bool
    
    var body: some View {
        Circle()
            .fill(isRunning ? Color.green : Color.red)
            .frame(width: 10, height: 10)
    }
}
