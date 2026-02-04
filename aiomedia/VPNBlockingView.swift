import SwiftUI

struct VPNBlockingView: View {
    @AppStorage("forceVPN") private var forceVPN: Bool = true
    @StateObject private var vpnManager = VPNManager.shared
    
    var body: some View {
        ZStack {
            Color.black.edgesIgnoringSafeArea(.all)
            
            VStack(spacing: 25) {
                Spacer()
                ZStack {
                    Circle()
                        .fill(vpnManager.isSecured ? Color.green.opacity(0.1) : Color.red.opacity(0.1))
                        .frame(width: 180, height: 180)
                    Image(systemName: vpnManager.isSecured ? "lock.fill" : "lock.shield.fill")
                        .font(.system(size: 80))
                        .foregroundColor(vpnManager.isSecured ? .green : .red)
                }
                
                VStack(spacing: 8) {
                    Text(vpnManager.isSecured ? "SECURED" : "EXPOSED")
                        .font(.largeTitle).bold()
                        .foregroundColor(vpnManager.isSecured ? .green : .red)
                    Text(vpnManager.statusMessage)
                        .font(.headline).foregroundColor(.white)
                    Text(vpnManager.publicIP).font(.monospaced(.body)())
                        .foregroundColor(.gray)
                }
                
                Spacer()
                
                Button("Refresh Status") { vpnManager.checkStatus(force: true) }
                    .padding()
                    .background(Color.white)
                    .foregroundColor(.black)
                    .cornerRadius(12)
                
                Button("Disable Killswitch") { forceVPN = false }
                    .foregroundColor(.red)
                    .padding()
            }
        }
        .onAppear { vpnManager.checkStatus() }
    }
}
