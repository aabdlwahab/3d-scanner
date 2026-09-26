import AppKit
import SwiftUI

@main
struct StudioApp: App {
    @NSApplicationDelegateAdaptor(StudioAppDelegate.self) private var appDelegate
    @State private var library = ProjectLibrary.shared
    @State private var showImporter = false

    var body: some Scene {
        Window("ScanSpace Studio", id: "main") {
            ContentView(showImporter: $showImporter)
                .environment(library)
                .frame(minWidth: 1040, minHeight: 660)
        }
        .defaultSize(width: 1440, height: 900)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Import…") { showImporter = true }
                    .keyboardShortcut("o")
                Button("New Sample Apartment") { library.createSampleApartment() }
            }
            CommandGroup(replacing: .undoRedo) {
                Button("Undo \(library.session?.edits.last?.title ?? "")") {
                    Task { await library.session?.undo() }
                }
                .keyboardShortcut("z")
                .disabled(library.session?.edits.isEmpty ?? true)
                Button("Redo") {
                    Task { await library.session?.redo() }
                }
                .keyboardShortcut("z", modifiers: [.command, .shift])
                .disabled(library.session?.redoStack.isEmpty ?? true)
            }
            CommandMenu("View") {
                Button("Reset View") { library.session?.cameraCommand = CameraCommand(kind: .reset) }
                    .keyboardShortcut("r")
                Button("Top View") { library.session?.cameraCommand = CameraCommand(kind: .top) }
                    .keyboardShortcut("t")
                Divider()
                ForEach(Array(ViewportTool.allCases.enumerated()), id: \.element) { index, tool in
                    Button(tool.title) { library.session?.tool = tool }
                        .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")))
                }
                Divider()
                Button("3D Model") { library.session?.mode = .model }
                    .keyboardShortcut("1", modifiers: [.command, .option])
                Button("Floor Plan") { library.session?.mode = .plan }
                    .keyboardShortcut("2", modifiers: [.command, .option])
            }
        }
        Settings {
            StudioSettingsView()
        }
    }
}

final class StudioAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        if CommandLine.arguments.contains("--light") { NSApp.appearance = NSAppearance(named: .aqua) }
        if CommandLine.arguments.contains("--snapshot") {
            Task { @MainActor in await SnapshotRunner.run() }
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        Task { @MainActor in ProjectLibrary.shared.importFiles(urls) }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

struct ContentView: View {
    @Binding var showImporter: Bool
    @Environment(ProjectLibrary.self) private var library
    @State private var dropTargeted = false

    var body: some View {
        @Bindable var library = library
        NavigationSplitView {
            SidebarView(showImporter: $showImporter)
                .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 340)
        } detail: {
            if let session = library.session {
                EditorView(session: session)
                    .id(session.id)
            } else {
                WelcomeView(showImporter: $showImporter)
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            library.importDropped(providers)
            return true
        }
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [10, 6]))
                    .padding(8)
                    .allowsHitTesting(false)
            }
        }
        .overlay(alignment: .bottom) {
            if let job = library.job {
                JobBanner(job: job).padding(.bottom, 18)
            }
        }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: ProjectLibrary.importableTypes, allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { library.importFiles(urls) }
        }
        .alert("Something went wrong", isPresented: Binding(get: { library.errorMessage != nil }, set: { if !$0 { library.errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(library.errorMessage ?? "")
        }
    }
}

struct JobBanner: View {
    let job: LibraryJob

    var body: some View {
        HStack(spacing: 12) {
            if let progress = job.progress {
                ProgressView(value: progress).frame(width: 140)
            } else {
                ProgressView().controlSize(.small)
            }
            Text(job.title).font(.callout.weight(.medium))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.separator))
        .shadow(radius: 12, y: 4)
    }
}

struct StudioSettingsView: View {
    @AppStorage("units") private var units = MeasurementSystem.preferred

    var body: some View {
        Form {
            Picker("Measurements", selection: $units) {
                ForEach(MeasurementSystem.allCases) { Text($0.title).tag($0) }
            }
            LabeledContent("Library") {
                Button("Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([ProjectLibrary.shared.rootURL])
                }
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}
