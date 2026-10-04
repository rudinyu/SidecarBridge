import SwiftUI

enum ScreenDockPalette {
    static let backgroundTop = Color(red: 0.018, green: 0.023, blue: 0.11)
    static let backgroundBottom = Color(red: 0.065, green: 0.055, blue: 0.22)
    static let panel = Color(red: 0.085, green: 0.09, blue: 0.23).opacity(0.66)
    static let border = Color(red: 0.38, green: 0.34, blue: 0.82).opacity(0.3)

    static let blue = Color(red: 0.31, green: 0.59, blue: 1.0)
    static let violet = Color(red: 0.68, green: 0.43, blue: 1.0)
    static let warmAccent = Color(red: 1.0, green: 0.68, blue: 0.31)

    static let backgroundGradient = [backgroundTop, backgroundBottom]
}
