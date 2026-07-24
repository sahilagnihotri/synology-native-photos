import SwiftUI
import PhotosCore

@main
struct SynologyPhotosApp: App {
    var body: some Scene {
        WindowGroup { ContentView() }
    }
}

struct ContentView: View {
    var body: some View {
        VStack {
            Text("Synology Photos").font(.title)
            Text("core \(coreVersion())").font(.caption).foregroundStyle(.secondary)
        }
        .padding()
        .frame(minWidth: 480, minHeight: 320)
    }
}
