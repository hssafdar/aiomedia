import Foundation
import Network
import Combine
import CryptoKit
import Compression

enum SoulseekSearchType: String, CaseIterable, Identifiable {
    case network = "Network (Code 26)"
    case wishlist = "Wishlist (Code 103)"
    case room = "Room (Code 120)"
    case user = "User (Code 42)"
    case similarUsers = "Similar Users (Code 110)"
    case recommendations = "Recommendations (Code 54)"
    case globalRecs = "Global Recs (Code 56)"
    
    var id: String { rawValue }
}

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
    
    // Search configuration
    @Published var searchType: SoulseekSearchType = .network
    @Published var targetUser: String = ""
    @Published var targetRoom: String = ""
    private var activeSearchTokens: Set<UInt32> = []
    
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
        log("🤝 Incoming peer connection", type: .info)
        connection.start(queue: queue)
        readPeerPacket(connection)
    }
    
    private func readPeerPacket(_ connection: NWConnection) {
        // Read 4-byte Length
        connection.receive(minimumIncompleteLength: 4, maximumLength: 4) { [weak self] data, _, _, error in
            guard let self = self else { return }
            
            if let error = error {
                self.log("⚠️ Peer receive error: \(error.localizedDescription)", type: .error)
                connection.cancel()
                return
            }
            
            guard let data = data, data.count == 4 else {
                self.log("⚠️ Peer connection closed or invalid length header", type: .error)
                connection.cancel()
                return
            }
            
            let len = data.withUnsafeBytes { $0.load(as: UInt32.self) }
            self.log("📥 Peer packet incoming: \(len) bytes", type: .traffic)
            
            // Read Body
            connection.receive(minimumIncompleteLength: Int(len), maximumLength: Int(len)) { body, _, _, error in
                if let error = error {
                    self.log("⚠️ Peer body receive error: \(error.localizedDescription)", type: .error)
                    connection.cancel()
                    return
                }
                
                if let body = body {
                    self.log("📥 Received \(body.count) bytes from peer", type: .traffic)
                    self.processPeerMessage(body)
                }
                // Keep connection open for more packets
                self.readPeerPacket(connection)
            }
        }
    }
    
    private func processPeerMessage(_ data: Data) {
        guard data.count >= 4 else { 
            log("⚠️ Peer message too short: \(data.count) bytes", type: .error)
            return 
        }
        
        // Code is first 4 bytes
        let code = data.prefix(4).withUnsafeBytes { $0.load(as: UInt32.self) }
        var content = data.dropFirst(4)
        
        log("📨 Peer message code: \(code), size: \(data.count) bytes", type: .traffic)
        
        switch code {
        case 1: // Peer Init
            log("🤝 Received PeerInit response", type: .info)
            break
            
        case 9: // Share Reply (Search Results)
            log("📦 Received ShareReply (code 9), attempting to parse...", type: .info)
            // Try decompression first (Zlib)
            if let decompressed = try? decompress(content) {
                log("✅ Decompressed \(content.count) -> \(decompressed.count) bytes", type: .success)
                parseShareReply(decompressed)
            } else {
                log("⚠️ Decompression failed, trying raw parse", type: .info)
                // Try parsing raw
                parseShareReply(content)
            }
            
        default:
            log("❓ Unknown peer message code: \(code)", type: .info)
            // Hex dump first 32 bytes for debugging
            let dumpSize = min(32, data.count)
            let hexDump = data.prefix(dumpSize).map { String(format: "%02x", $0) }.joined(separator: " ")
            log("📋 Hex dump: \(hexDump)", type: .traffic)
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
            guard offset + count <= data.count else { 
                log("⚠️ Parse error: tried to read \(count) bytes at offset \(offset), but data is only \(data.count) bytes", type: .error)
                return nil 
            }
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
        guard let username = readString() else { 
            log("⚠️ Failed to read username from ShareReply", type: .error)
            return 
        }
        guard let token = readUInt32() else { 
            log("⚠️ Failed to read token from ShareReply", type: .error)
            return 
        }
        guard let count = readUInt32() else { 
            log("⚠️ Failed to read count from ShareReply", type: .error)
            return 
        }
        
        log("📦 Parsing ShareReply from \(username): token=\(token), count=\(count)", type: .info)
        
        // Remove token from active searches once we receive results
        activeSearchTokens.remove(token)
        
        var results: [SearchResult] = []
        
        for i in 0..<count {
            guard let _ = readBytes(1) else { 
                log("⚠️ Failed to read code for file \(i+1)", type: .error)
                break 
            } // Code
            guard let filename = readString() else { 
                log("⚠️ Failed to read filename for file \(i+1)", type: .error)
                break 
            }
            guard let size = readUInt32() else { 
                log("⚠️ Failed to read size for file \(i+1)", type: .error)
                break 
            }
            guard let ext = readString() else { 
                log("⚠️ Failed to read extension for file \(i+1)", type: .error)
                break 
            }
            guard let attrCount = readUInt32() else { 
                log("⚠️ Failed to read attr count for file \(i+1)", type: .error)
                break 
            }
            
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
        } else {
            log("⚠️ No results extracted from ShareReply", type: .info)
        }
    }
    
    // MARK: - 3. Server Protocol
    
    func search(query: String) {
        guard isLoggedIn else { return }
        
        // Generate unique token
        var token: UInt32
        repeat {
            token = UInt32.random(in: 1...99999)
        } while activeSearchTokens.contains(token)
        activeSearchTokens.insert(token)
        
        switch searchType {
        case .network:
            searchNetwork(query: query, token: token)
        case .wishlist:
            searchWishlist(query: query, token: token)
        case .room:
            searchRoom(query: query, room: targetRoom, token: token)
        case .user:
            searchUser(query: query, username: targetUser, token: token)
        case .similarUsers:
            searchSimilarUsers(query: query, token: token)
        case .recommendations:
            searchRecommendations(query: query, token: token)
        case .globalRecs:
            searchGlobalRecommendations(query: query, token: token)
        }
    }
    
    private func searchNetwork(query: String, token: UInt32) {
        log("🔎 Broadcasting (Network): \(query)", type: .traffic)
        
        var packet = Data()
        packet.append(contentsOf: UInt32(0).littleEndianBytes)
        packet.append(contentsOf: UInt32(26).littleEndianBytes) // File Search
        packet.append(contentsOf: token.littleEndianBytes)
        packet.append(contentsOf: UInt32(query.count).littleEndianBytes)
        packet.append(query.data(using: .utf8) ?? Data())
        
        send(packet: packet)
    }
    
    private func searchWishlist(query: String, token: UInt32) {
        log("🔎 Adding Wishlist Search: \(query)", type: .traffic)
        
        // Note: Wishlist searches don't use tokens in the protocol packet,
        // but we track the token for consistency
        var packet = Data()
        packet.append(contentsOf: UInt32(0).littleEndianBytes)
        packet.append(contentsOf: UInt32(103).littleEndianBytes) // Add Wishlist Item
        packet.append(contentsOf: UInt32(query.count).littleEndianBytes)
        packet.append(query.data(using: .utf8) ?? Data())
        
        send(packet: packet)
    }
    
    private func searchRoom(query: String, room: String, token: UInt32) {
        guard !room.isEmpty else {
            log("⚠️ Room search requires a room name", type: .error)
            return
        }
        log("🔎 Searching Room '\(room)': \(query)", type: .traffic)
        
        var packet = Data()
        packet.append(contentsOf: UInt32(0).littleEndianBytes)
        packet.append(contentsOf: UInt32(120).littleEndianBytes) // Room Search
        packet.append(contentsOf: UInt32(room.count).littleEndianBytes)
        packet.append(room.data(using: .utf8) ?? Data())
        packet.append(contentsOf: token.littleEndianBytes)
        packet.append(contentsOf: UInt32(query.count).littleEndianBytes)
        packet.append(query.data(using: .utf8) ?? Data())
        
        send(packet: packet)
    }
    
    private func searchUser(query: String, username: String, token: UInt32) {
        guard !username.isEmpty else {
            log("⚠️ User search requires a username", type: .error)
            return
        }
        log("🔎 Searching User '\(username)': \(query)", type: .traffic)
        
        var packet = Data()
        packet.append(contentsOf: UInt32(0).littleEndianBytes)
        packet.append(contentsOf: UInt32(42).littleEndianBytes) // User Search
        packet.append(contentsOf: UInt32(username.count).littleEndianBytes)
        packet.append(username.data(using: .utf8) ?? Data())
        packet.append(contentsOf: token.littleEndianBytes)
        packet.append(contentsOf: UInt32(query.count).littleEndianBytes)
        packet.append(query.data(using: .utf8) ?? Data())
        
        send(packet: packet)
    }
    
    private func searchSimilarUsers(query: String, token: UInt32) {
        log("🔎 Searching Similar Users: \(query)", type: .traffic)
        
        var packet = Data()
        packet.append(contentsOf: UInt32(0).littleEndianBytes)
        packet.append(contentsOf: UInt32(110).littleEndianBytes) // Similar Users Search
        packet.append(contentsOf: token.littleEndianBytes)
        packet.append(contentsOf: UInt32(query.count).littleEndianBytes)
        packet.append(query.data(using: .utf8) ?? Data())
        
        send(packet: packet)
    }
    
    private func searchRecommendations(query: String, token: UInt32) {
        log("🔎 Searching Recommendations: \(query)", type: .traffic)
        
        var packet = Data()
        packet.append(contentsOf: UInt32(0).littleEndianBytes)
        packet.append(contentsOf: UInt32(54).littleEndianBytes) // Recommendations
        packet.append(contentsOf: token.littleEndianBytes)
        packet.append(contentsOf: UInt32(query.count).littleEndianBytes)
        packet.append(query.data(using: .utf8) ?? Data())
        
        send(packet: packet)
    }
    
    private func searchGlobalRecommendations(query: String, token: UInt32) {
        log("🔎 Searching Global Recommendations: \(query)", type: .traffic)
        
        var packet = Data()
        packet.append(contentsOf: UInt32(0).littleEndianBytes)
        packet.append(contentsOf: UInt32(56).littleEndianBytes) // Global Recommendations
        packet.append(contentsOf: token.littleEndianBytes)
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
        packet.append(contentsOf: UInt32(2).littleEndianBytes) // SetListenPort (correct code)
        packet.append(contentsOf: UInt32(portVal).littleEndianBytes)
        packet.append(contentsOf: UInt32(portVal + 1).littleEndianBytes) // Obfuscated port
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
    
    private func sendHaveNoParent() {
        log("📡 Sending HaveNoParent", type: .info)
        var packet = Data()
        packet.append(contentsOf: UInt32(0).littleEndianBytes)
        packet.append(contentsOf: UInt32(71).littleEndianBytes)
        packet.append(UInt8(1)) // true - we have no parent
        send(packet: packet)
    }
    
    private func sendCannotConnect(token: UInt32, username: String) {
        log("❌ Sending CannotConnect for \(username) (token: \(token))", type: .info)
        var packet = Data()
        packet.append(contentsOf: UInt32(0).littleEndianBytes)
        packet.append(contentsOf: UInt32(1001).littleEndianBytes)
        packet.append(contentsOf: token.littleEndianBytes)
        packet.append(contentsOf: UInt32(username.count).littleEndianBytes)
        packet.append(username.data(using: .utf8) ?? Data())
        send(packet: packet)
    }
    
    private func requestPeerAddress(username: String) {
        log("📍 Requesting peer address for \(username)", type: .info)
        var packet = Data()
        packet.append(contentsOf: UInt32(0).littleEndianBytes)
        packet.append(contentsOf: UInt32(3).littleEndianBytes) // GetPeerAddress
        packet.append(contentsOf: UInt32(username.count).littleEndianBytes)
        packet.append(username.data(using: .utf8) ?? Data())
        send(packet: packet)
    }
    
    // MARK: - Peer Connection Management
    
    private func handleConnectToPeer(_ data: Data) {
        var offset = 4 // Skip message code
        
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
        
        guard let username = readString(),
              let connType = readString(),
              let ip = readUInt32(),
              let port = readUInt32(),
              let token = readUInt32() else {
            log("⚠️ Failed to parse ConnectToPeer message", type: .error)
            return
        }
        
        // Convert IP from little-endian integer to dotted notation
        let ipString = String(format: "%d.%d.%d.%d",
                             ip & 0xFF,
                             (ip >> 8) & 0xFF,
                             (ip >> 16) & 0xFF,
                             (ip >> 24) & 0xFF)
        
        log("🔗 Server requests peer connection to \(username) at \(ipString):\(port) (type: \(connType), token: \(token))", type: .info)
        
        // Initiate connection to peer
        connectToPeer(ip: ipString, port: port, username: username, token: token, connType: connType)
    }
    
    private func connectToPeer(ip: String, port: UInt32, username: String, token: UInt32, connType: String) {
        log("🔗 Attempting peer connection to \(username) at \(ip):\(port) (type: '\(connType)', token: \(token))", type: .info)
        
        let params = NWParameters.tcp
        params.includePeerToPeer = true
        
        // Set connection timeout
        let tcpOptions = NWProtocolTCP.Options()
        tcpOptions.connectionTimeout = 30 // 30 seconds timeout
        params.defaultProtocolStack.transportProtocol = tcpOptions
        
        let host = NWEndpoint.Host(ip)
        let portEndpoint = NWEndpoint.Port(rawValue: UInt16(port)) ?? NWEndpoint.Port(integerLiteral: UInt16(port))
        
        let peerConnection = NWConnection(host: host, port: portEndpoint, using: params)
        
        // Create a timeout timer
        var connectionTimer: DispatchWorkItem? = nil
        
        peerConnection.stateUpdateHandler = { [weak self] state in
            guard let self = self else { return }
            
            switch state {
            case .preparing:
                self.log("🔄 Preparing connection to \(username)...", type: .info)
                
                // Set a timeout for the connection
                connectionTimer = DispatchWorkItem { [weak self, weak peerConnection] in
                    self?.log("⏱️ Connection timeout for \(username)", type: .error)
                    peerConnection?.cancel()
                    self?.sendCannotConnect(token: token, username: username)
                    self?.requestPeerAddress(username: username)
                }
                DispatchQueue.global().asyncAfter(deadline: .now() + 30, execute: connectionTimer!)
                
            case .ready:
                // Cancel the timeout timer
                connectionTimer?.cancel()
                connectionTimer = nil
                
                self.log("✅ Connected to peer \(username) - sending init for type '\(connType)'", type: .success)
                
                // Determine which initialization message to send based on connection type
                // Connection type 'P' (0x50 / 80 decimal) requires PeerInit
                // Connection type 'F' (0x46 / 70 decimal) requires PierceFirewall
                // Connection type 'D' (0x44 / 68 decimal) is for distributed network
                
                if connType == "P" {
                    // Send PeerInit for type 'P' connections
                    self.sendPeerInit(connection: peerConnection, username: username, connType: connType, token: token)
                } else {
                    // Send PierceFirewall for other types (F, D)
                    self.sendPierceFirewall(connection: peerConnection, token: token)
                }
                
                // Start reading from this peer connection
                self.readPeerPacket(peerConnection)
                
            case .failed(let error):
                connectionTimer?.cancel()
                connectionTimer = nil
                self.log("❌ Failed to connect to peer \(username): \(error.localizedDescription)", type: .error)
                peerConnection.cancel()
                // Notify server we couldn't connect
                self.sendCannotConnect(token: token, username: username)
                // Try to get peer address from server as fallback
                self.requestPeerAddress(username: username)
                
            case .waiting(let error):
                self.log("⏳ Waiting to connect to peer \(username): \(error.localizedDescription)", type: .info)
                
            case .cancelled:
                connectionTimer?.cancel()
                connectionTimer = nil
                self.log("🚫 Connection to \(username) cancelled", type: .info)
                
            default:
                break
            }
        }
        
        peerConnection.start(queue: queue)
    }
    
    private func sendPierceFirewall(connection: NWConnection, token: UInt32) {
        log("🔓 Sending PierceFirewall with token \(token)", type: .traffic)
        
        var packet = Data()
        packet.append(contentsOf: UInt32(0).littleEndianBytes) // Placeholder for length
        packet.append(contentsOf: UInt32(0).littleEndianBytes) // PierceFirewall code (0)
        packet.append(contentsOf: token.littleEndianBytes)
        
        // Update length
        let totalLen = UInt32(packet.count - 4)
        packet.replaceSubrange(0..<4, with: totalLen.littleEndianBytes)
        
        connection.send(content: packet, completion: .contentProcessed { error in
            if let error = error {
                self.log("⚠️ PierceFirewall send error: \(error)", type: .error)
            }
        })
    }
    
    private func sendPeerInit(connection: NWConnection, username: String, connType: String, token: UInt32) {
        log("🤝 Sending PeerInit for type '\(connType)' with token \(token)", type: .traffic)
        
        var packet = Data()
        // Length placeholder
        packet.append(contentsOf: UInt32(0).littleEndianBytes)
        // Code 1 = PeerInit
        packet.append(UInt8(1))
        // Our username
        let myUsername = UserDefaults.standard.string(forKey: "slsk_user") ?? ""
        packet.append(contentsOf: UInt32(myUsername.count).littleEndianBytes)
        packet.append(myUsername.data(using: .utf8) ?? Data())
        // Connection type
        packet.append(contentsOf: UInt32(connType.count).littleEndianBytes)
        packet.append(connType.data(using: .utf8) ?? Data())
        // Token
        packet.append(contentsOf: token.littleEndianBytes)
        
        // Fix length
        let len = UInt32(packet.count - 4)
        packet.replaceSubrange(0..<4, with: len.littleEndianBytes)
        
        connection.send(content: packet, completion: .contentProcessed { error in
            if let error = error {
                self.log("⚠️ PeerInit send error: \(error)", type: .error)
            } else {
                self.log("✅ PeerInit sent successfully", type: .success)
            }
        })
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
        
        log("📬 Server message code: \(code)", type: .traffic)
        
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
                    self.sendHaveNoParent()
                } else {
                    self.loginError = "Login Rejected"
                    self.log("⛔ Login Failed", type: .error)
                }
                
            case 18: // ConnectToPeer
                self.handleConnectToPeer(data)
            
            case 9: // FileSearchResult (relayed through server)
                self.log("📦 Received FileSearchResult from server", type: .info)
                // Skip the code (4 bytes) and parse the embedded peer message
                let peerData = data.dropFirst(4)
                if peerData.count >= 4 {
                    // Try decompression first (Zlib)
                    if let decompressed = try? self.decompress(peerData) {
                        self.parseShareReply(decompressed)
                    } else {
                        // Try parsing raw
                        self.parseShareReply(peerData)
                    }
                }
                
            case 93: // Embedded distributed message
                self.log("📦 Received embedded message", type: .info)
                // Extract and handle embedded message
                if data.count > 5 {
                    let embeddedData = data.dropFirst(5) // Skip code + 1 byte
                    if embeddedData.count >= 4 {
                        let embeddedCode = embeddedData.prefix(4).withUnsafeBytes { $0.load(as: UInt32.self) }
                        self.log("📦 Embedded message code: \(embeddedCode)", type: .traffic)
                        // Could be search results or other distributed messages
                    }
                }
                
            default:
                break
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
