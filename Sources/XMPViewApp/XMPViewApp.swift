import AppKit
import SwiftUI

@main
@MainActor
struct XMPViewApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = EditorModel()

    var body: some Scene {
        Window("XMP View", id: "main") {
            ContentView(model: model)
                .frame(minWidth: 880, minHeight: 660)
                .onAppear { appDelegate.model = model }
                .onOpenURL { model.open($0) }
                .background(WindowCloseGuard(model: model))
        }
        .defaultSize(width: 1120, height: 820)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("打开图片…") { model.chooseFile() }
                    .keyboardShortcut("o")
                    .disabled(model.isBusy)
            }
            CommandGroup(replacing: .saveItem) {
                Button("保存") { model.save() }
                    .keyboardShortcut("s")
                    .disabled(!model.canSave)
                Button("另存为…") { model.saveAs() }
                    .keyboardShortcut("s", modifiers: [.command, .shift])
                    .disabled(!model.canSaveAs)
            }
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var model: EditorModel?

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model else { return .terminateNow }
        if model.isBusy { return .terminateCancel }
        return model.closeApproved || model.confirmDiscardChanges() ? .terminateNow : .terminateCancel
    }
}

@MainActor
private struct WindowCloseGuard: NSViewRepresentable {
    let model: EditorModel

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    func makeNSView(context: Context) -> GuardView {
        let view = GuardView()
        view.guardDelegate = context.coordinator
        return view
    }

    func updateNSView(_ view: GuardView, context: Context) {
        view.installGuard()
    }

    static func dismantleNSView(_ view: GuardView, coordinator: Coordinator) {
        if let window = view.window, window.delegate === coordinator {
            window.delegate = coordinator.previousDelegate
        }
    }

    @MainActor
    final class GuardView: NSView {
        weak var guardDelegate: Coordinator?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            installGuard()
        }

        func installGuard() {
            guard let window, let guardDelegate, window.delegate !== guardDelegate else { return }
            guardDelegate.previousDelegate = window.delegate
            window.delegate = guardDelegate
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSWindowDelegate {
        let model: EditorModel
        weak var previousDelegate: NSWindowDelegate?

        init(model: EditorModel) { self.model = model }

        func windowShouldClose(_ sender: NSWindow) -> Bool {
            guard !model.isBusy, model.confirmDiscardChanges() else { return false }
            model.closeApproved = true
            return true
        }

        nonisolated override func responds(to selector: Selector!) -> Bool {
            if super.responds(to: selector) { return true }
            guard Thread.isMainThread else { return false }
            return MainActor.assumeIsolated {
                previousDelegate?.responds(to: selector) ?? false
            }
        }

        nonisolated override func forwardingTarget(for selector: Selector!) -> Any? {
            if Thread.isMainThread {
                let target: Any? = MainActor.assumeIsolated {
                    previousDelegate?.responds(to: selector) == true ? previousDelegate : nil
                }
                if let target { return target }
            }
            return super.forwardingTarget(for: selector)
        }
    }
}
