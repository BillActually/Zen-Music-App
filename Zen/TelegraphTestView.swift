import SwiftUI

struct TelegraphTestView: View {
    @ObservedObject var serverManager: TelegraphServerManager
    
    var body: some View {
            VStack(spacing: 24) {
                // Status Card
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Circle()
                            .fill(serverManager.isRunning ? Color.yellow : Color.red)
                            .frame(width: 12, height: 12)
                        Text(serverManager.isRunning ? "Server Running" : "Server Stopped")
                            .font(.headline)
                    }
                    
                    if serverManager.isRunning {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Server URL:")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Text(serverManager.serverURL)
                                .font(.system(.body, design: .monospaced))
                                .textSelection(.enabled)
                                .padding(8)
                                .background(Color.gray.opacity(0.1))
                                .cornerRadius(6)
                        }
                        
                        VStack(alignment: .leading, spacing: 8) {
                            Text("IP Address:")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Text(serverManager.localIPAddress)
                                .font(.system(.body, design: .monospaced))
                                .textSelection(.enabled)
                        }
                    }
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(.systemBackground))
                .cornerRadius(12)
                .shadow(color: .black.opacity(0.1), radius: 5, x: 0, y: 2)
                
                // Instructions
                if serverManager.isRunning {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("How to Use:")
                            .font(.headline)
                        
                        VStack(alignment: .leading, spacing: 8) {
                            InstructionStep(number: "1", text: "Make sure your iPhone and computer are on the same WiFi network")
                            InstructionStep(number: "2", text: "Open a web browser on your computer")
                            InstructionStep(number: "3", text: "Go to the Server URL shown above")
                            InstructionStep(number: "4", text: "Upload or download music files")
                        }
                    }
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(.systemBackground))
                    .cornerRadius(12)
                    .shadow(color: .black.opacity(0.1), radius: 5, x: 0, y: 2)
                }
                
                // Error Message
                if !serverManager.errorMessage.isEmpty {
                    Text(serverManager.errorMessage)
                        .font(.caption)
                        .foregroundColor(.red)
                        .padding()
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.red.opacity(0.1))
                        .cornerRadius(8)
                }
                
                Spacer()
                
                // Control Button
                Button(action: {
                    if serverManager.isRunning {
                        serverManager.stopServer()
                    } else {
                        serverManager.startServer()
                    }
                }) {
                    Text(serverManager.isRunning ? "Stop Server" : "Start Server")
                        .font(.headline)
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(serverManager.isRunning ? Color.red : Color.yellow)
                        .cornerRadius(12)
                }
            }
            .padding()
            .navigationTitle("File Sharing")
            .navigationBarTitleDisplayMode(.inline)
    }
}

struct InstructionStep: View {
    let number: String
    let text: String
    
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text(number)
                .font(.headline)
                .foregroundColor(.white)
                .frame(width: 24, height: 24)
                .background(Color.blue)
                .clipShape(Circle())
            Text(text)
                .font(.body)
                .foregroundColor(.primary)
            Spacer()
        }
    }
}

#Preview {
    TelegraphTestView(serverManager: TelegraphServerManager())
}
