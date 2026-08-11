import SwiftUI

@main
struct PaperCompanionApp: App {
    @StateObject private var state = AppState()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(state)
        }
        .commands {
            CommandGroup(replacing: .undoRedo) {
                Button("Undo", action: state.performUndo)
                    .keyboardShortcut("z", modifiers: .command)
                Button("Redo", action: state.performRedo)
                    .keyboardShortcut("z", modifiers: [.command, .shift])
            }

            CommandGroup(after: .newItem) {
                Button("Open PDF…", action: state.openPDF)
                    .keyboardShortcut("o", modifiers: .command)
                Divider()
                Button("Save Reading Notes", action: state.saveNotes)
                    .keyboardShortcut("s", modifiers: .command)
                    .disabled(state.document == nil)
                Button("Export Comments…", action: state.exportComments)
                    .disabled(state.document == nil)
            }

            CommandMenu("Highlights") {
                Button("Highlight Selection", action: state.addHighlight)
                    .keyboardShortcut("h", modifiers: [.command, .shift])
                    .disabled(state.currentSelection == nil)

                Toggle("Auto-highlight Selections", isOn: $state.autoHighlightEnabled)
                    .disabled(state.document == nil)

                Divider()
                Button("Remove Selected Highlight", action: state.deleteSelectedHighlight)
                    .disabled(state.selectedHighlight == nil)
            }
        }

        Window("Reading Notes", id: "notes") {
            NotesView()
                .environmentObject(state)
                .frame(minWidth: 440, minHeight: 580)
                .padding(4)
        }
    }
}
