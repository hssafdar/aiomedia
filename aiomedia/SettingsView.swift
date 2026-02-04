import SwiftUI

struct SettingsView: View {
    @StateObject private var viewModel = SearchViewModel.shared
    @StateObject private var vpnManager = VPNManager.shared
    @AppStorage("forceVPN") private var forceVPN: Bool = false
    
    var body: some View {
        NavigationView {
            List {
                // MARK: - Security
                Section(header: Text("Security")) {
                    Toggle("VPN Killswitch", isOn: $forceVPN)
                        .tint(.red)
                    
                    HStack {
                        Text("Status")
                        Spacer()
                        if vpnManager.isSecured {
                            Text("Secured").foregroundColor(.green).bold()
                        } else {
                            Text("Exposed").foregroundColor(.red).bold()
                        }
                    }
                }
                
                // MARK: - Search Providers
                Section(header: Text("Torrent Providers")) {
                    ForEach(viewModel.providerSettings) { provider in
                        Toggle(provider.name, isOn: Binding(
                            get: { provider.isEnabled },
                            set: { _ in viewModel.toggleProvider(provider.name) }
                        ))
                    }
                }
                
                // MARK: - Soulseek
                Section(header: Text("Soulseek Credentials")) {
                    TextField("Username", text: $viewModel.slskUser)
                        .autocapitalization(.none)
                    SecureField("Password", text: $viewModel.slskPass)
                }
                
                // MARK: - Storage
                                Section(header: Text("Storage")) {
                                    Button(action: {
                                        DownloadManager.shared.openDownloadsFolder()
                                    }) {
                                        Label("Open Files App", systemImage: "folder")
                                    }
                                    
                                    Text("Downloads are saved to: On My iPhone > aiomedia")
                                        .font(.caption).foregroundColor(.gray)
                                }
            }
            .navigationTitle("Settings")
        }
    }
}
