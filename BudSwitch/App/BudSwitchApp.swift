import SwiftUI

@main
struct BudSwitchApp: App {
    @StateObject private var state = AppState()

    var body: some Scene {
        MenuBarExtra {
            MenuView(state: state)
        } label: {
            // One constant silhouette, dimmed when the buds aren't here, so state reads as
            // brightness rather than a shape swap you have to decode.
            //
            // `headphones` over any earbud symbol on purpose: at 16pt the earbud glyphs
            // are all thin stems and fiddly detail that turn to mush, while this stays a
            // bold closed shape. Override with `defaults write com.budswitch.mac
            // menubarSymbol -string "<sf-symbol-name>"` if you prefer another.
            Image(systemName: state.menubarSymbol)
                .opacity(state.isRouted ? 1.0 : 0.5)
        }
        // A window, not a menu: the route line can't be drawn with native menu items.
        .menuBarExtraStyle(.window)
    }
}
