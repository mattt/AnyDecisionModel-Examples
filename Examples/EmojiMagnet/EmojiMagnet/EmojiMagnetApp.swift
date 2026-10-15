import SwiftUI

@main
struct EmojiMagnetApp: App {
    @State private var controller = EmojiMagnetController.makeForLaunch()

    var body: some Scene {
        Window("Emoji Magnet", id: "emoji-magnet") {
            ContentView(controller: controller)
                .frame(minWidth: 720, minHeight: 560)
                #if DEBUG
                .task { await EmojiMagnetDebugAutomation.run(controller: controller) }
                #endif
        }
        .defaultSize(width: 1_000, height: 720)
    }
}

extension EmojiMagnetController {
    static func makeForLaunch() -> EmojiMagnetController {
        #if DEBUG
        if let fixture = EmojiMagnetFixture.current {
            return fixture.makeController()
        }
        // The app hosts the unit tests, which must not download the model.
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
            return EmojiMagnetFixture.loading.makeController()
        }
        #endif
        return EmojiMagnetController()
    }
}
