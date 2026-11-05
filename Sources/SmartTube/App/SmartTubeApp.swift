import SwiftUI
import AppKit

@main
struct SmartTubeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var model = AppModel.shared
    @StateObject private var player = PlayerController.shared
    @StateObject private var settings = Settings.shared

    var body: some Scene {
        WindowGroup("SmartTube") {
            ContentView()
                .environmentObject(model)
                .environmentObject(player)
                .environmentObject(settings)
                .frame(minWidth: 900, minHeight: 560)
                .preferredColorScheme(settings.colorScheme == 1 ? .dark : settings.colorScheme == 2 ? .light : nil)
                .tint(AccentColors.color(settings.accentColor))
        }
        .windowStyle(.hiddenTitleBar)
        .commands { PlayerCommands(player: player, model: model) }

        SwiftUI.Settings {
            SettingsView()
                .environmentObject(model)
                .environmentObject(player)
                .environmentObject(settings)
                .frame(width: 720, height: 560)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        URLCache.shared = URLCache(memoryCapacity: 64 << 20, diskCapacity: 512 << 20)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        !Settings.shared.backgroundPlayback || !PlayerController.shared.isPlaying
    }

    /// Opens youtube links dropped on the dock icon / passed via `open`.
    func application(_ application: NSApplication, open urls: [URL]) {
        for u in urls { Task { @MainActor in AppModel.shared.open(url: u) } }
    }
}

enum AccentColors {
    static let names = ["Red", "Blue", "Green", "Orange", "Purple", "Pink", "Teal"]
    static func color(_ i: Int) -> Color {
        [Color.red, .blue, .green, .orange, .purple, .pink, .teal][max(0, min(i, 6))]
    }
}

struct PlayerCommands: Commands {
    @ObservedObject var player: PlayerController
    @ObservedObject var model: AppModel

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("Search") { model.focusSearch() }.keyboardShortcut("f", modifiers: .command)
            Button("Open YouTube Link…") { model.showOpenURL = true }.keyboardShortcut("o", modifiers: .command)
            Button("Back") { model.goBack() }.keyboardShortcut("[", modifiers: .command)
        }
        CommandMenu("Playback") {
            Button(player.isPlaying ? "Pause" : "Play") { player.togglePlay() }
                .keyboardShortcut(.space, modifiers: .command)
                .disabled(!player.isVisible)
            Button("Seek Forward") { player.seek(by: Settings.shared.seekIncrement) }
                .keyboardShortcut(.rightArrow, modifiers: .command).disabled(!player.isVisible)
            Button("Seek Backward") { player.seek(by: -Settings.shared.seekIncrement) }
                .keyboardShortcut(.leftArrow, modifiers: .command).disabled(!player.isVisible)
            Divider()
            Button("Next Video") { player.playNext() }.keyboardShortcut("n", modifiers: [.command, .shift]).disabled(!player.isVisible)
            Button("Previous Video") { player.playPrevious() }.keyboardShortcut("p", modifiers: [.command, .shift]).disabled(!player.isVisible)
            Divider()
            Button("Speed Up") { player.setSpeed(min(4, player.speed + 0.25)) }.keyboardShortcut(".", modifiers: [.command, .option]).disabled(!player.isVisible)
            Button("Slow Down") { player.setSpeed(max(0.25, player.speed - 0.25)) }.keyboardShortcut(",", modifiers: [.command, .option]).disabled(!player.isVisible)
            Button("Normal Speed") { player.setSpeed(1) }.disabled(!player.isVisible)
            Divider()
            Button("Toggle Subtitles") {
                if player.selectedCaption != nil { player.selectCaption(nil) }
                else if let t = player.captionTracks.first(where: { $0.languageCode == Settings.shared.subtitleLanguage }) ?? player.captionTracks.first { player.selectCaption(t) }
            }.keyboardShortcut("c", modifiers: [.command, .option]).disabled(!player.isVisible)
            Button("Skip Segment") { player.skipCurrentSegment() }.keyboardShortcut(.return, modifiers: [.command, .shift]).disabled(player.skipPrompt == nil)
            Button("Minimize Player") { player.isMinimized.toggle() }.keyboardShortcut("m", modifiers: [.command, .shift]).disabled(!player.isVisible)
            Button("Close Player") { player.close() }.keyboardShortcut("w", modifiers: [.command, .shift]).disabled(!player.isVisible)
        }
    }
}
