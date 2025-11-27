//
//  TranslationServer.swift
//  translator
//
//  Created by 徐力航 on 2025/11/27.
//

import Foundation
import Network
import Translation

class TranslationServer: ObservableObject {
    private var listener: NWListener?
    private var port: UInt16 = 5308
    private let queue = DispatchQueue(label: "TranslationServer")
    
    @Published var isRunning = false
    @Published var lastRequest: String = ""
    @Published var lastResponse: String = ""
    @Published var connectedClients: Int = 0
    @Published var errorMessage: String = ""
    @Published var actualPort: UInt16 = 0
    @Published var requestCount: Int = 0
    
    // 修复：添加唯一标识符确保每次重新触发
    @Published var translationSessionId: UUID?
    @Published var translationConfig: TranslationSession.Configuration?
    @Published var currentTranslationText: String = ""
    @Published var currentConnection: NWConnection?
    
    private var activeConnections: [ObjectIdentifier: NWConnection] = [:]
    
    func start(port: UInt16 = 5308) {
        self.port = port
        
        do {
            let parameters = NWParameters.tcp
            parameters.allowLocalEndpointReuse = true
            parameters.serviceClass = .background
            parameters.includePeerToPeer = true
            
            listener = try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: port)!)
            
            listener?.stateUpdateHandler = { [weak self] state in
                DispatchQueue.main.async {
                    switch state {
                    case .ready:
                        if let actualPort = self?.listener?.port?.rawValue {
                            print("🚀 翻译服务器启动在端口 \(actualPort)")
                            self?.actualPort = actualPort
                            self?.isRunning = true
                            self?.errorMessage = ""
                        }
                    case .failed(let error):
                        print("❌ 服务器启动失败: \(error)")
                        self?.isRunning = false
                        self?.errorMessage = "启动失败: \(error.localizedDescription)"
                    case .cancelled:
                        print("🛑 服务器已取消")
                        self?.isRunning = false
                    default:
                        break
                    }
                }
            }
            
            listener?.newConnectionHandler = { [weak self] connection in
                self?.handleNewConnection(connection)
            }
            
            listener?.start(queue: queue)
            
        } catch {
            print("❌ 启动服务器错误: \(error)")
            DispatchQueue.main.async {
                self.errorMessage = "启动错误: \(error.localizedDescription)"
            }
        }
    }
    
    private func handleNewConnection(_ connection: NWConnection) {
        let connectionId = ObjectIdentifier(connection)
        activeConnections[connectionId] = connection
        
        DispatchQueue.main.async {
            self.connectedClients = self.activeConnections.count
        }
        
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .cancelled, .failed:
                self?.removeConnection(connection)
            default:
                break
            }
        }
        
        connection.start(queue: queue)
        receiveHTTPRequest(connection)
    }
    
    private func removeConnection(_ connection: NWConnection) {
        let connectionId = ObjectIdentifier(connection)
        activeConnections.removeValue(forKey: connectionId)
        
        DispatchQueue.main.async {
            self.connectedClients = self.activeConnections.count
        }
    }
    
    private func receiveHTTPRequest(_ connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, context, isComplete, error in
            guard let self = self else { return }
            
            if let data = data, !data.isEmpty {
                if let requestString = String(data: data, encoding: .utf8) {
                    self.processRequest(requestString, connection: connection)
                } else {
                    self.sendErrorResponse(connection, error: "无法解析请求数据")
                    self.receiveHTTPRequest(connection)
                }
            } else if let error = error {
                print("接收数据错误: \(error)")
                self.removeConnection(connection)
            } else {
                self.receiveHTTPRequest(connection)
            }
        }
    }
    
    private func processRequest(_ requestString: String, connection: NWConnection) {
        DispatchQueue.main.async {
            self.lastRequest = String(requestString.prefix(1000))
            self.requestCount += 1
        }
        
        let lines = requestString.components(separatedBy: "\r\n")
        guard let firstLine = lines.first else {
            sendErrorResponse(connection, error: "无效的请求")
            receiveHTTPRequest(connection)
            return
        }
        
        let components = firstLine.components(separatedBy: " ")
        guard components.count >= 3, components[0] == "POST", components[1] == "/translate" else {
            sendErrorResponse(connection, error: "只支持 POST /translate 端点")
            receiveHTTPRequest(connection)
            return
        }
        
        if let bodyRange = requestString.range(of: "\r\n\r\n") {
            let bodyString = String(requestString[bodyRange.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            processTranslationRequest(bodyString, connection: connection)
        } else {
            sendErrorResponse(connection, error: "没有请求体")
            receiveHTTPRequest(connection)
        }
    }
    
    private func processTranslationRequest(_ bodyString: String, connection: NWConnection) {
        guard let bodyData = bodyString.data(using: .utf8) else {
            sendErrorResponse(connection, error: "无效的请求体编码")
            receiveHTTPRequest(connection)
            return
        }
        
        do {
            let json = try JSONSerialization.jsonObject(with: bodyData) as? [String: Any]
            guard let text = json?["text"] as? String,
                  let sourceLang = json?["source_language"] as? String,
                  let targetLang = json?["target_language"] as? String else {
                sendErrorResponse(connection, error: "无效的 JSON 数据")
                receiveHTTPRequest(connection)
                return
            }
            
            // 修复：重置配置以确保重新触发翻译任务
            DispatchQueue.main.async {
                // 先清除之前的配置
                self.translationConfig = nil
                self.translationSessionId = nil
                
                // 短暂延迟后设置新配置，确保 SwiftUI 检测到变化
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.01) {
                    self.currentConnection = connection
                    self.currentTranslationText = text
                    self.translationConfig = TranslationSession.Configuration(
                        source: Locale.Language(identifier: sourceLang),
                        target: Locale.Language(identifier: targetLang)
                    )
                    self.translationSessionId = UUID() // 每次生成新的 ID
                }
            }
            
        } catch {
            sendErrorResponse(connection, error: "JSON 解析错误: \(error.localizedDescription)")
            receiveHTTPRequest(connection)
        }
    }
    
    func handleTranslationResult(_ result: Result<String, Error>) {
        guard let connection = currentConnection else { return }
        
        switch result {
        case .success(let translatedText):
            DispatchQueue.main.async {
                self.lastResponse = translatedText
            }
            sendSuccessResponse(connection, translatedText: translatedText)
            
        case .failure(let error):
            sendErrorResponse(connection, error: "翻译错误: \(error.localizedDescription)")
        }
        
        // 修复：在翻译完成后立即清理状态，准备下一次请求
        DispatchQueue.main.async {
            self.currentConnection = nil
            self.currentTranslationText = ""
            // 注意：不要在这里清除 translationConfig，因为 SwiftUI 可能还在使用它
        }
        
        receiveHTTPRequest(connection)
    }
    
    private func sendSuccessResponse(_ connection: NWConnection, translatedText: String) {
        let jsonResponse = ["translated_text": translatedText]
        guard let jsonData = try? JSONSerialization.data(withJSONObject: jsonResponse),
              let jsonString = String(data: jsonData, encoding: .utf8) else {
            sendErrorResponse(connection, error: "无法生成响应")
            return
        }
        
        let response = """
        HTTP/1.1 200 OK
        Content-Type: application/json
        Access-Control-Allow-Origin: *
        Access-Control-Allow-Methods: POST, GET, OPTIONS
        Access-Control-Allow-Headers: *
        Content-Length: \(jsonData.count)
        
        \(jsonString)
        """
        
        sendResponse(connection, response: response)
    }
    
    private func sendErrorResponse(_ connection: NWConnection, error: String) {
        let jsonResponse = ["error": error]
        guard let jsonData = try? JSONSerialization.data(withJSONObject: jsonResponse),
              let jsonString = String(data: jsonData, encoding: .utf8) else {
            return
        }
        
        let response = """
        HTTP/1.1 400 Bad Request
        Content-Type: application/json
        Access-Control-Allow-Origin: *
        Access-Control-Allow-Methods: POST, GET, OPTIONS
        Access-Control-Allow-Headers: *
        Content-Length: \(jsonData.count)
        
        \(jsonString)
        """
        
        sendResponse(connection, response: response)
    }
    
    private func sendResponse(_ connection: NWConnection, response: String) {
        guard let data = response.data(using: .utf8) else { return }
        
        connection.send(content: data, completion: .contentProcessed { error in
            if let error = error {
                print("发送响应错误: \(error)")
            }
        })
    }
    
    func stop() {
        for connection in activeConnections.values {
            connection.cancel()
        }
        activeConnections.removeAll()
        
        listener?.cancel()
        listener = nil
        DispatchQueue.main.async {
            self.isRunning = false
            self.errorMessage = ""
            self.actualPort = 0
            self.connectedClients = 0
            self.requestCount = 0
            self.translationConfig = nil
            self.translationSessionId = nil
        }
        print("🛑 服务器已停止")
    }
}
