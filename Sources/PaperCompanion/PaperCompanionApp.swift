import PaperCompanionCore
import SwiftUI

@main
struct PaperCompanionApp: App {
    @StateObject private var state = AppState()
    @StateObject private var updates = AppUpdates()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(state)
                .environmentObject(updates)
        }
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") { Task { await updates.check() } }
                    .disabled(updates.isChecking)
                Button("What’s New", action: updates.showWhatsNew)
            }
            CommandGroup(replacing: .help) {
                Button("Request a Feature…", action: updates.requestFeature)
            }

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
                Button("Save Comment", action: state.saveCommentFromKeyboard)
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(state.document == nil)
                Button("Save Page-only Comment") { state.addComment(linkToHighlight: false) }
                    .keyboardShortcut(.return, modifiers: [.command, .shift])
                    .disabled(state.document == nil)
                Button("Save Margin Note", action: state.addQuickNote)
                    .keyboardShortcut("m", modifiers: [.command, .shift])
                    .disabled(state.document == nil)
                Button("Save Reading Notes", action: state.saveNotes)
                    .keyboardShortcut("s", modifiers: .command)
                    .disabled(state.document == nil)
                Button("Export Comments…", action: state.exportComments)
                    .disabled(state.document == nil)
                Button("Reveal Annotated PDF", action: state.revealAnnotatedPDF)
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

            CommandMenu("Agent") {
                Picker("Reading Mode", selection: $state.readingMode) {
                    ForEach(ReadingMode.allCases, id: \.self) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .disabled(state.document == nil)
                Divider()
                Button("Copy Agent Prompt", action: state.copyAgentPrompt)
                    .disabled(state.document == nil)
                Button("Reveal Session Folder", action: state.revealSessionFolder)
                    .disabled(state.document == nil)
            }
        }

        Window("Reading Notes", id: "notes") {
            NotesWindowView()
                .environmentObject(state)
                .environmentObject(updates)
                .frame(minWidth: 440, minHeight: 580)
                .padding(4)
        }
    }
}
