import SwiftUI

@main
struct ChessApp: App {
    @State private var controller = ChessGameController.makeForLaunch()
    @AppStorage("ShowsInspector") private var showsInspector = true

    var body: some Scene {
        Window("Chess", id: "chess") {
            ContentView(controller: controller, showsInspector: $showsInspector)
                .frame(minWidth: 900, minHeight: 620)
                #if DEBUG
                .task { await ChessDebugAutomation.run() }
                #endif
        }
        .defaultSize(width: 1_100, height: 760)
        .commands {
            ChessCommands(controller: controller, showsInspector: $showsInspector)
        }
    }
}

extension ChessGameController {
    static func makeForLaunch() -> ChessGameController {
        #if DEBUG
        if let fixture = ChessFixture.current {
            return fixture.makeController()
        }
        #endif
        return ChessGameController()
    }
}
