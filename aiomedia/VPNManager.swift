import Foundation
import Network
import Combine // ADD THIS
// ... rest of file

class VPNManager: ObservableObject {
    static let shared = VPNManager()
    
    // UI State
    @Published var isSecured: Bool = false
    @Published var statusMessage: String = "Initializing..."
    @Published var publicIP: String = "..."
    @Published var isChecking: Bool = false
    
    private var timer: Timer?
    private var lastCheckTime: Date?
    private let cooldown: TimeInterval = 2.0
    
    init() {
        startPolling()
    }
    
    func startPolling() {
        checkStatus()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            self?.checkStatus()
        }
    }
    
    func checkStatus(force: Bool = false) {
        if !force, let last = lastCheckTime, Date().timeIntervalSince(last) < cooldown { return }
        lastCheckTime = Date()
        
        DispatchQueue.main.async {
            self.isChecking = true
            self.statusMessage = "Verifying IP..."
        }
        
        guard let url = URL(string: "https://api.ipapi.is/") else { return }
        
        URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
            guard let self = self else { return }
            DispatchQueue.main.async {
                self.isChecking = false
                
                guard let data = data,
                      let response = try? JSONDecoder().decode(IPApiResponse.self, from: data) else {
                    self.performLocalFallbackCheck()
                    return
                }
                
                self.publicIP = response.ip
                let isVpn = response.is_vpn ?? false
                let isProxy = response.is_proxy ?? false
                let isTor = response.is_tor ?? false
                
                if isVpn || isProxy || isTor {
                    self.isSecured = true
                    self.statusMessage = "VPN Detected (\(response.company?.name ?? "Secure"))"
                } else {
                    self.isSecured = false
                    self.statusMessage = "Exposed: ISP Connection"
                }
            }
        }.resume()
    }
    
    private func performLocalFallbackCheck() {
        // Simple interface check if API fails
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0 else { return }
        var ptr = ifaddr
        var found = false
        
        while ptr != nil {
            defer { ptr = ptr?.pointee.ifa_next }
            guard let interface = ptr?.pointee else { continue }
            let name = String(cString: interface.ifa_name)
            let flags = interface.ifa_flags
            let isUp = (flags & UInt32(IFF_UP)) == UInt32(IFF_UP)
            
            if isUp && (name.hasPrefix("utun") || name.hasPrefix("ppp") || name.hasPrefix("ipsec")) {
                found = true
                break
            }
        }
        freeifaddrs(ifaddr)
        self.isSecured = found
        self.statusMessage = found ? "VPN Detected (Local)" : "Connection Failed"
    }
}

struct IPApiResponse: Decodable {
    let ip: String
    let is_vpn: Bool?
    let is_proxy: Bool?
    let is_tor: Bool?
    let company: CompanyInfo?
    struct CompanyInfo: Decodable { let name: String? }
}
