import SwiftUI

struct MacHeadApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    
    var body: some Scene {
        Settings {
            EmptyView() // Will be replaced by settings view in future phases
        }
    }
}
