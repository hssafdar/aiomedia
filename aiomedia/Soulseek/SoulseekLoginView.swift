import SwiftUI
import Combine // ADDED

struct SoulseekLoginView: View {
    @StateObject private var client = SoulseekClient.shared
    @AppStorage("slsk_user") var user: String = ""
    @AppStorage("slsk_pass") var pass: String = ""
    @State private var isConnecting = false
    
    var body: some View {
        ZStack {
            Color(.systemGroupedBackground).edgesIgnoringSafeArea(.all)
            
            VStack(spacing: 24) {
                // Logo / Icon
                VStack(spacing: 12) {
                    Image(systemName: "bird.fill")
                        .font(.system(size: 60))
                        .foregroundColor(.blue)
                        .padding()
                        .background(Circle().fill(Color.white).shadow(radius: 5))
                    
                    Text("Soulseek Login")
                        .font(.largeTitle.bold())
                }
                .padding(.bottom, 20)
                
                // Form Fields
                VStack(spacing: 16) {
                    TextField("Username", text: $user)
                        .textContentType(.username)
                        .autocapitalization(.none)
                        .padding()
                        .background(Color(.secondarySystemGroupedBackground))
                        .cornerRadius(12)
                    
                    SecureField("Password", text: $pass)
                        .textContentType(.password)
                        .padding()
                        .background(Color(.secondarySystemGroupedBackground))
                        .cornerRadius(12)
                }
                .padding(.horizontal)
                
                // Error Message
                if let error = client.loginError {
                    Text(error)
                        .font(.caption)
                        .foregroundColor(.red)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }
                
                // Login Button
                Button(action: performLogin) {
                    HStack {
                        if isConnecting {
                            ProgressView()
                                .progressViewStyle(CircularProgressViewStyle(tint: .white))
                        } else {
                            Text("Connect")
                                .bold()
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(user.isEmpty || pass.isEmpty ? Color.gray : Color.blue)
                    .foregroundColor(.white)
                    .cornerRadius(12)
                }
                .disabled(user.isEmpty || pass.isEmpty || isConnecting)
                .padding(.horizontal)
                
                Spacer()
                
                Text("Soulseek® is a registered trademark of Soulseek, LLC.\nThis client is unofficial.")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.bottom)
            }
            .padding(.top, 50)
        }
        .onChange(of: client.isLoggedIn) { loggedIn in
            if loggedIn {
                isConnecting = false
            }
        }
        .onChange(of: client.loginError) { error in
            if error != nil {
                isConnecting = false
            }
        }
    }
    
    private func performLogin() {
        isConnecting = true
        client.connect(user: user, pass: pass)
    }
}
