import SwiftUI

@main
struct HelloShipiOSApp: App {
    var body: some Scene {
        WindowGroup {
            VStack(spacing: 16) {
                Image(systemName: "hammer.circle.fill")
                    .font(.system(size: 56))
                    .foregroundStyle(.blue)
                Text("Hello, ShipiOS")
                    .font(.title)
                Text("Local build fixture")
                    .foregroundStyle(.secondary)
            }
            .padding()
        }
    }
}
