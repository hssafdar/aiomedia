import SwiftUI
import Combine // ADDED

@main
struct aiomediaApp: App {
    @AppStorage("forceVPN") private var forceVPN: Bool = false
    @StateObject private var vpnManager = VPNManager.shared
    
    var body: some Scene {
        WindowGroup {
            ZStack {
                ContentView()
                
                // Global Killswitch Overlay
                if forceVPN && !vpnManager.isSecured {
                    VPNBlockingView()
                        .zIndex(999) // Always on top
                        .transition(.opacity)
                }
            }
            .animation(.easeInOut, value: vpnManager.isSecured)
        }
    }
}
