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
                    self.sendErrorResponse(connection, error: "无法解析请求数据", statusCode: 400)
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
            sendErrorResponse(connection, error: "无效的请求", statusCode: 400)
            receiveHTTPRequest(connection)
            return
        }
        
        let components = firstLine.components(separatedBy: " ")
        guard components.count >= 3 else {
            sendErrorResponse(connection, error: "无效的请求格式", statusCode: 400)
            receiveHTTPRequest(connection)
            return
        }
        
        let method = components[0]
        let path = components[1]
        
        // 处理 HEAD 请求
        if method == "HEAD" {
            handleHeadRequest(connection, path: path)
            return
        }
        
        // 处理 POST 翻译请求
        if method == "POST" && path == "/translate" {
            if let bodyRange = requestString.range(of: "\r\n\r\n") {
                let bodyString = String(requestString[bodyRange.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
                processTranslationRequest(bodyString, connection: connection)
            } else {
                sendErrorResponse(connection, error: "没有请求体", statusCode: 400)
                receiveHTTPRequest(connection)
            }
        } else {
            sendErrorResponse(connection, error: "不支持的端点或方法", statusCode: 404)
            receiveHTTPRequest(connection)
        }
    }
    
    private func handleHeadRequest(_ connection: NWConnection, path: String) {
        // 对于 HEAD 请求，只返回头部信息，不返回实际内容
        
        var response = """
            HTTP/1.1 404 Not Found
            Content-Type: application/json
            Access-Control-Allow-Origin: *
            Access-Control-Allow-Methods: POST, GET, OPTIONS, HEAD
            Access-Control-Allow-Headers: *
            Content-Length: 0
            
            """

        
        sendResponse(connection, response: response)
        receiveHTTPRequest(connection)
    }
    
    private func processTranslationRequest(_ bodyString: String, connection: NWConnection) {
        guard let bodyData = bodyString.data(using: .utf8) else {
            sendErrorResponse(connection, error: "无效的请求体编码", statusCode: 400)
            receiveHTTPRequest(connection)
            return
        }
        
        do {
            let json = try JSONSerialization.jsonObject(with: bodyData) as? [String: Any]
            guard let text = json?["text"] as? String,
                  let sourceLang = json?["source_language"] as? String,
                  let targetLang = json?["target_language"] as? String else {
                sendErrorResponse(connection, error: "无效的 JSON 数据", statusCode: 400)
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
            sendErrorResponse(connection, error: "JSON 解析错误: \(error.localizedDescription)", statusCode: 400)
            receiveHTTPRequest(connection)
        }
    }
    
    func normalizeNewlines(in text: String) -> String {
        // 先统一换行符为 \n
        var normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        normalized = normalized.replacingOccurrences(of: "\r", with: "\n")
        
        // 然后替换多个连续换行为一个
        return normalized.replacingOccurrences(of: "\n{2,}",
                                             with: "\n",
                                             options: .regularExpression)
    }
    
    func handleTranslationResult(_ result: Result<String, Error>) {
        guard let connection = currentConnection else { return }
        
        switch result {
        case .success(var translatedText):
            translatedText = normalizeNewlines(in: translatedText)
            DispatchQueue.main.async {
                self.lastResponse = translatedText
            }
            sendSuccessResponse(connection, translatedText: translatedText)
            
        case .failure(let error):
            sendErrorResponse(connection, error: "翻译错误: \(error.localizedDescription)", statusCode: 500)
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
            sendErrorResponse(connection, error: "无法生成响应", statusCode: 500)
            return
        }
        
        let response = """
        HTTP/1.1 200 OK
        Content-Type: application/json
        Access-Control-Allow-Origin: *
        Access-Control-Allow-Methods: POST, GET, OPTIONS, HEAD
        Access-Control-Allow-Headers: *
        Content-Length: \(jsonData.count)
        
        \(jsonString)
        """
        
        sendResponse(connection, response: response)
    }
    
    private func sendErrorResponse(_ connection: NWConnection, error: String, statusCode: Int = 400) {
        let jsonResponse = ["error": error]
        guard let jsonData = try? JSONSerialization.data(withJSONObject: jsonResponse),
              let jsonString = String(data: jsonData, encoding: .utf8) else {
            return
        }
        
        let response = """
        HTTP/1.1 \(statusCode) \(getStatusText(for: statusCode))
        Content-Type: application/json
        Access-Control-Allow-Origin: *
        Access-Control-Allow-Methods: POST, GET, OPTIONS, HEAD
        Access-Control-Allow-Headers: *
        Content-Length: \(jsonData.count)
        
        \(jsonString)
        """
        
        sendResponse(connection, response: response)
    }
    
    private func getStatusText(for statusCode: Int) -> String {
        switch statusCode {
        case 200: return "OK"
        case 400: return "Bad Request"
        case 404: return "Not Found"
        case 405: return "Method Not Allowed"
        case 500: return "Internal Server Error"
        default: return "Unknown"
        }
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
