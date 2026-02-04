import Foundation
import Network
import Combine
import CryptoKit
import Compression

class SoulseekClient: ObservableObject {
    static let shared = SoulseekClient()
    
    // Config
    private let serverHost = "server.slsknet.org"
    private let serverPort: NWEndpoint.Port = 2242
    private var listeningPort: NWEndpoint.Port = 2234
    
    // State
    private var connection: NWConnection?
    private var listener: NWListener?
    
    @Published var isConnected: Bool = false
    @Published var isLoggedIn: Bool = false
    @Published var loginError: String? = nil
    @Published var logs: [ConsoleLog] = []
    
    // Results Stream
    let searchResultsSubject = PassthroughSubject<[SearchResult], Never>()
    
    // Queues
    private let queue = DispatchQueue(label: "SoulseekQueue", qos: .userInitiated)
    
    struct ConsoleLog: Identifiable {
        let id = UUID(); let time = Date(); let message: String; let type: LogType
    }
    enum LogType { case info, success, error, traffic }
    
    // MARK: - Lifecycle
    
    func autoConnect() {
        guard !isConnected else { return }
        let user = UserDefaults.standard.string(forKey: "slsk_user") ?? ""
        let pass = UserDefaults.standard.string(forKey: "slsk_pass") ?? ""
        if !user.isEmpty && !pass.isEmpty { connect(user: user, pass: pass) }
    }
    
    func connect(user: String, pass: String) {
        disconnect()
        log("🔄 Starting Client...", type: .info)
        
        // 1. Start Listener (Get Port)
        startListening { [weak self] success in
            guard success, let self = self else { return }
            
            // 2. Try UPnP (FIXED SYNTAX)
            let portVal = self.listeningPort.rawValue
            self.log("🌐 Attempting UPnP Map for \(portVal)...", type: .info)
            UPnPManager.shared.mapPort(portVal)
            
            // 3. Connect Server
            self.connectToServer(user: user, pass: pass)
        }
    }
    
    private func connectToServer(user: String, pass: String) {
        let params = NWParameters.tcp
        connection = NWConnection(host: NWEndpoint.Host(serverHost), port: serverPort, using: params)
        
        connection?.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                self?.log("✅ Server Handshake OK", type: .success)
                DispatchQueue.main.async { self?.isConnected = true }
                self?.performLogin(user: user, pass: pass)
                self?.receiveNextPacket()
            case .failed(let error):
                self?.log("❌ Server Failed: \(error)", type: .error)
                DispatchQueue.main.async { self?.loginError = error.localizedDescription }
            default: break
            }
        }
        connection?.start(queue: queue)
    }
    
    func disconnect() {
        connection?.cancel()
        listener?.cancel()
        connection = nil
        listener = nil
        DispatchQueue.main.async {
            self.isConnected = false
            self.isLoggedIn = false
        }
    }
    
    // MARK: - 1. P2P Listener & NAT Traversal
    
    private func startListening(completion: @escaping (Bool) -> Void) {
        do {
            let params = NWParameters.tcp
            params.allowLocalEndpointReuse = true
            // This attempts basic NAT-PMP / PCP if the router supports it (Apple's built-in effort)
            params.includePeerToPeer = true
            
            // Randomize port slightly to avoid "Address in use" errors on restart
            let port = NWEndpoint.Port(integerLiteral: UInt16.random(in: 2234...2240))
            
            self.listener = try NWListener(using: params, on: port)
            
            self.listener?.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if let p = self.listener?.port {
                        self.listeningPort = p
                        self.log("👂 Listening on Port \(p)", type: .success)
                        completion(true)
                    }
                case .failed(let error):
                    self.log("⚠️ Listener Error: \(error)", type: .error)
                    completion(false)
                default: break
                }
            }
            
            self.listener?.newConnectionHandler = { [weak self] newConn in
                self?.handlePeerConnection(newConn)
            }
            
            self.listener?.start(queue: queue)
            
        } catch {
            log("❌ Listener Init Failed: \(error)", type: .error)
            completion(false)
        }
    }
    
    // MARK: - 2. Peer Handling (The Results Engine)
    
    private func handlePeerConnection(_ connection: NWConnection) {
        connection.start(queue: queue)
        readPeerPacket(connection)
    }
    
    private func readPeerPacket(_ connection: NWConnection) {
        // Read 4-byte Length
        connection.receive(minimumIncompleteLength: 4, maximumLength: 4) { [weak self] data, _, _, error in
            guard let self = self, let data = data, data.count == 4 else {
                connection.cancel(); return
            }
            
            let len = data.withUnsafeBytes { $0.load(as: UInt32.self) }
            
            // Read Body
            connection.receive(minimumIncompleteLength: Int(len), maximumLength: Int(len)) { body, _, _, _ in
                if let body = body {
                    self.processPeerMessage(body)
                }
                // Keep connection open for more packets
                self.readPeerPacket(connection)
            }
        }
    }
    
    private func processPeerMessage(_ data: Data) {
        guard data.count >= 4 else { return }
        
        // Code is first 4 bytes
        let code = data.prefix(4).withUnsafeBytes { $0.load(as: UInt32.self) }
        var content = data.dropFirst(4)
        
        switch code {
        case 1: // Peer Init
            break
            
        case 9: // Share Reply (Search Results)
            // Try decompression first (Zlib)
            if let decompressed = try? decompress(content) {
                parseShareReply(decompressed)
            } else {
                // Try parsing raw
                parseShareReply(content)
            }
            
        default:
            break
        }
    }
    
    private func decompress(_ data: Data) throws -> Data {
        let pageSize = 128 * 1024
        var decompressed = Data()
        
        try data.withUnsafeBytes { rawBuffer in
            let bufferPointer = rawBuffer.bindMemory(to: UInt8.self)
            guard let sourceBase = bufferPointer.baseAddress else { return }
            
            let scratchBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: pageSize)
            defer { scratchBuffer.deallocate() }
            
            let streamPtr = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
            defer { streamPtr.deallocate() }
            
            var stream = streamPtr.pointee
            var status = compression_stream_init(&stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB)
            guard status != COMPRESSION_STATUS_ERROR else { throw CompressionError.initFail }
            defer { compression_stream_destroy(&stream) }
            
            stream.src_ptr = sourceBase
            stream.src_size = data.count
            stream.dst_ptr = scratchBuffer
            stream.dst_size = pageSize
            
            while status == COMPRESSION_STATUS_OK {
                status = compression_stream_process(&stream, 0)
                let bytesWritten = pageSize - stream.dst_size
                if bytesWritten > 0 {
                    decompressed.append(scratchBuffer, count: bytesWritten)
                }
                stream.dst_ptr = scratchBuffer
                stream.dst_size = pageSize
            }
        }
        return decompressed
    }
    enum CompressionError: Error { case initFail }
    
    private func parseShareReply(_ data: Data) {
        var offset = 0
        
        func readBytes(_ count: Int) -> Data? {
            guard offset + count <= data.count else { return nil }
            let d = data.subdata(in: offset..<offset+count)
            offset += count
            return d
        }
        
        func readUInt32() -> UInt32? {
            guard let d = readBytes(4) else { return nil }
            return d.withUnsafeBytes { $0.load(as: UInt32.self) }
        }
        
        func readString() -> String? {
            guard let len = readUInt32() else { return nil }
            guard let d = readBytes(Int(len)) else { return nil }
            return String(data: d, encoding: .utf8)
        }
        
        // Protocol: [User] [Token] [Count] [ [File]... ]
        guard let username = readString() else { return }
        guard let token = readUInt32() else { return }
        guard let count = readUInt32() else { return }
        
        var results: [SearchResult] = []
        
        for _ in 0..<count {
            guard let _ = readBytes(1) else { break } // Code
            guard let filename = readString() else { break }
            guard let size = readUInt32() else { break }
            guard let ext = readString() else { break }
            guard let attrCount = readUInt32() else { break }
            
            for _ in 0..<attrCount {
                guard let _ = readUInt32() else { break }
                guard let _ = readUInt32() else { break }
            }
            
            let cleanName = filename.replacingOccurrences(of: "\\", with: "/")
            let title = cleanName.components(separatedBy: "/").last ?? cleanName
            
            let result = SearchResult(
                title: title,
                displayTitle: "\(title) (\(username))",
                size: ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file),
                seeders: 1,
                leechers: 0,
                magnetLink: "slsk://\(username)/\(filename.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? "")",
                pageUrl: nil,
                source: "Soulseek",
                pubDate: Date()
            )
            results.append(result)
        }
        
        if !results.isEmpty {
            log("⚡ Found \(results.count) files from \(username)", type: .success)
            searchResultsSubject.send(results)
        }
    }
    
    // MARK: - 3. Server Protocol
    
    func search(query: String) {
        guard isLoggedIn else { return }
        log("🔎 Broadcasting: \(query)", type: .traffic)
        
        var packet = Data()
        packet.append(contentsOf: UInt32(0).littleEndianBytes)
        packet.append(contentsOf: UInt32(26).littleEndianBytes) // File Search
        packet.append(contentsOf: UInt32.random(in: 1...99999).littleEndianBytes)
        packet.append(contentsOf: UInt32(query.count).littleEndianBytes)
        packet.append(query.data(using: .utf8) ?? Data())
        
        send(packet: packet)
    }
    
    private func performLogin(user: String, pass: String) {
        log("🔑 Authenticating...", type: .info)
        var packet = Data()
        packet.append(contentsOf: UInt32(0).littleEndianBytes)
        packet.append(contentsOf: UInt32(1).littleEndianBytes) // Login
        packet.append(contentsOf: UInt32(user.count).littleEndianBytes); packet.append(user.data(using: .utf8)!)
        packet.append(contentsOf: UInt32(pass.count).littleEndianBytes); packet.append(pass.data(using: .utf8)!)
        packet.append(contentsOf: UInt32(157).littleEndianBytes) // Ver
        let hash = Insecure.MD5.hash(data: (user+pass).data(using: .utf8)!).map{String(format:"%02hhx",$0)}.joined()
        packet.append(contentsOf: UInt32(hash.count).littleEndianBytes); packet.append(hash.data(using: .utf8)!)
        packet.append(contentsOf: UInt32(17).littleEndianBytes) // Minor
        send(packet: packet)
    }
    
    private func sendSetListenPort() {
        let portVal = listeningPort.rawValue
        log("📡 Reporting Port \(portVal)", type: .info)
        var packet = Data()
        packet.append(contentsOf: UInt32(0).littleEndianBytes)
        packet.append(contentsOf: UInt32(32).littleEndianBytes)
        packet.append(contentsOf: UInt32(portVal).littleEndianBytes)
        send(packet: packet)
    }
    
    private func sendSetStatus() {
        var packet = Data()
        packet.append(contentsOf: UInt32(0).littleEndianBytes)
        packet.append(contentsOf: UInt32(28).littleEndianBytes)
        packet.append(contentsOf: UInt32(2).littleEndianBytes) // Online
        send(packet: packet)
    }
    
    private func sendSetSharedCounts() {
        var packet = Data()
        packet.append(contentsOf: UInt32(0).littleEndianBytes)
        packet.append(contentsOf: UInt32(35).littleEndianBytes)
        packet.append(contentsOf: UInt32(0).littleEndianBytes)
        packet.append(contentsOf: UInt32(0).littleEndianBytes)
        send(packet: packet)
    }
    
    // MARK: - Helpers
    private func send(packet: Data) {
        var data = packet
        let totalLen = UInt32(data.count - 4)
        data.replaceSubrange(0..<4, with: totalLen.littleEndianBytes)
        connection?.send(content: data, completion: .contentProcessed { _ in })
    }
    
    private func receiveNextPacket() {
        connection?.receive(minimumIncompleteLength: 4, maximumLength: 4) { [weak self] data, _, _, _ in
            guard let self = self, let data = data, data.count == 4 else { return }
            let len = data.withUnsafeBytes { $0.load(as: UInt32.self) }
            self.connection?.receive(minimumIncompleteLength: Int(len), maximumLength: Int(len)) { body, _, _, _ in
                if let body = body { self.handleServerMessage(body) }
                self.receiveNextPacket()
            }
        }
    }
    
    private func handleServerMessage(_ data: Data) {
        guard data.count >= 4 else { return }
        let code = data.prefix(4).withUnsafeBytes { $0.load(as: UInt32.self) }
        DispatchQueue.main.async {
            switch code {
            case 1: // Login Reply
                let success = data.count > 4 && data[4] == 1
                if success {
                    self.isLoggedIn = true
                    self.log("🚀 Login Success", type: .success)
                    self.sendSetListenPort()
                    self.sendSetStatus()
                    self.sendSetSharedCounts()
                } else {
                    self.loginError = "Login Rejected"
                    self.log("⛔ Login Failed", type: .error)
                }
            default: break
            }
        }
    }
    
    private func log(_ msg: String, type: LogType) {
        print("[SLSK] \(msg)")
        DispatchQueue.main.async { self.logs.append(ConsoleLog(message: msg, type: type)) }
    }
}

extension UInt32 {
    var littleEndianBytes: Data {
        var val = self.littleEndian
        return Data(bytes: &val, count: MemoryLayout<UInt32>.size)
    }
}
