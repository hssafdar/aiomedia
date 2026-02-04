import Foundation
import Network
import Combine // ADDED THIS

class UPnPManager: ObservableObject {
    static let shared = UPnPManager()
    
    @Published var isMapped = false
    @Published var status = "Initializing UPnP..."
    
    private let multicastGroup = "239.255.255.250"
    private let multicastPort: NWEndpoint.Port = 1900
    private var connection: NWConnection?
    
    // The port we want to map (Must match SoulseekClient)
    private var internalPort: UInt16 = 2234
    private var internalIP: String = ""
    
    func mapPort(_ port: UInt16) {
        self.internalPort = port
        self.status = "Discovering Router..."
        findRouter()
    }
    
    // 1. Find the Router via SSDP (Simple Service Discovery Protocol)
    private func findRouter() {
        let params = NWParameters.udp
        params.allowLocalEndpointReuse = true
        
        // We broadcast to the multicast group
        let connection = NWConnection(host: NWEndpoint.Host(multicastGroup), port: multicastPort, using: params)
        self.connection = connection
        
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                self.sendDiscoveryPacket()
                self.receiveResponse()
            case .failed(let err):
                print("UPnP Discovery Failed: \(err)")
                self.status = "Discovery Failed"
            default: break
            }
        }
        connection.start(queue: .global())
    }
    
    private func sendDiscoveryPacket() {
        let msg = """
        M-SEARCH * HTTP/1.1\r
        HOST: 239.255.255.250:1900\r
        MAN: "ssdp:discover"\r
        MX: 3\r
        ST: urn:schemas-upnp-org:service:WANIPConnection:1\r
        \r
        """
        connection?.send(content: msg.data(using: .utf8), completion: .contentProcessed { _ in })
    }
    
    // 2. Parse Router Response to get Control URL
    private func receiveResponse() {
        connection?.receiveMessage { data, context, isComplete, error in
            if let data = data, let response = String(data: data, encoding: .utf8) {
                // Look for LOCATION: header
                if let location = self.extractValue(from: response, key: "LOCATION") {
                    print("UPnP: Router found at \(location)")
                    self.connection?.cancel() // Stop listening
                    self.parseRouterDescription(url: location)
                }
            }
        }
    }
    
    // 3. Download Router Description XML to find Control URL
    private func parseRouterDescription(url: String) {
        guard let urlObj = URL(string: url) else { return }
        
        // Use local IP logic here if needed, but for now assuming we just need to send the add port command
        // We need our own local IP to tell the router where to forward traffic
        self.internalIP = getWiFiAddress() ?? ""
        
        URLSession.shared.dataTask(with: urlObj) { data, _, _ in
            guard let data = data, let xml = String(data: data, encoding: .utf8) else { return }
            
            // Hacky regex parsing because XMLParser is verbose
            // We look for the controlURL for WANIPConnection
            if let controlURL = self.extractControlURL(from: xml),
               let baseURL = urlObj.host {
                
                let fullControlURL = "http://\(baseURL):\(urlObj.port ?? 80)\(controlURL)"
                self.sendAddPortMapping(to: fullControlURL)
            }
        }.resume()
    }
    
    // 4. Send "AddPortMapping" SOAP Command
    private func sendAddPortMapping(to urlString: String) {
        guard let url = URL(string: urlString) else { return }
        
        let soapBody = """
        <?xml version="1.0"?>
        <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
        <s:Body>
        <u:AddPortMapping xmlns:u="urn:schemas-upnp-org:service:WANIPConnection:1">
        <NewRemoteHost></NewRemoteHost>
        <NewExternalPort>\(internalPort)</NewExternalPort>
        <NewProtocol>TCP</NewProtocol>
        <NewInternalPort>\(internalPort)</NewInternalPort>
        <NewInternalClient>\(internalIP)</NewInternalClient>
        <NewEnabled>1</NewEnabled>
        <NewPortMappingDescription>SoulseekiOS</NewPortMappingDescription>
        <NewLeaseDuration>0</NewLeaseDuration>
        </u:AddPortMapping>
        </s:Body>
        </s:Envelope>
        """
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = soapBody.data(using: .utf8)
        request.setValue("text/xml; charset=\"utf-8\"", forHTTPHeaderField: "Content-Type")
        request.setValue("\"urn:schemas-upnp-org:service:WANIPConnection:1#AddPortMapping\"", forHTTPHeaderField: "SOAPACTION")
        
        URLSession.shared.dataTask(with: request) { _, response, error in
            DispatchQueue.main.async {
                if let httpResp = response as? HTTPURLResponse, httpResp.statusCode == 200 {
                    self.isMapped = true
                    self.status = "Port \(self.internalPort) Opened via UPnP"
                    print("✅ UPnP Success: Port \(self.internalPort) is open!")
                } else {
                    self.status = "UPnP Failed (Router might not support it)"
                    print("❌ UPnP Failed: \(String(describing: response))")
                }
            }
        }.resume()
    }
    
    // MARK: - Helpers
    private func extractValue(from text: String, key: String) -> String? {
        let regex = try? NSRegularExpression(pattern: "\(key):\\s*(.*)", options: .caseInsensitive)
        let nsString = text as NSString
        let results = regex?.matches(in: text, range: NSRange(location: 0, length: nsString.length))
        return results?.first.map { nsString.substring(with: $0.range(at: 1)).trimmingCharacters(in: .whitespacesAndNewlines) }
    }
    
    private func extractControlURL(from xml: String) -> String? {
        // Very basic XML search
        if let range = xml.range(of: "<controlURL>") {
            let start = range.upperBound
            if let endRange = xml.range(of: "</controlURL>", range: start..<xml.endIndex) {
                return String(xml[start..<endRange.lowerBound])
            }
        }
        return nil
    }
    
    // Get Local IP Address (Needed for UPnP)
    private func getWiFiAddress() -> String? {
        var address: String?
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        if getifaddrs(&ifaddr) == 0 {
            var ptr = ifaddr
            while ptr != nil {
                defer { ptr = ptr?.pointee.ifa_next }
                let interface = ptr?.pointee
                let addrFamily = interface?.ifa_addr.pointee.sa_family
                if addrFamily == UInt8(AF_INET) {
                    let name = String(cString: (interface?.ifa_name)!)
                    if name == "en0" { // en0 is usually WiFi
                        var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                        getnameinfo(interface?.ifa_addr, socklen_t((interface?.ifa_addr.pointee.sa_len)!),
                                    &hostname, socklen_t(hostname.count),
                                    nil, socklen_t(0), NI_NUMERICHOST)
                        address = String(cString: hostname)
                    }
                }
            }
            freeifaddrs(ifaddr)
        }
        return address
    }
}
