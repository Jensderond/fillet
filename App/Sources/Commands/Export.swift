import FilletCore
import FilletKernel
import SwiftUI
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
#endif

enum ExportFormat: String, CaseIterable, Identifiable {
    case threeMF, stl, step
    var id: String { rawValue }

    var title: String {
        switch self {
        case .threeMF: "3MF (Bambu Studio, PrusaSlicer…)"
        case .stl: "STL"
        case .step: "STEP (other CAD apps)"
        }
    }

    var contentType: UTType {
        switch self {
        case .threeMF: .threeMF
        case .stl: .stl
        case .step: .step
        }
    }

    var fileExtension: String {
        switch self {
        case .threeMF: "3mf"
        case .stl: "stl"
        case .step: "step"
        }
    }
}

/// Raw bytes handed to `fileExporter`.
struct ExportedFile: FileDocument {
    static let readableContentTypes: [UTType] = [.threeMF, .stl, .step]
    var data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}

extension DesignSession {
    /// Visible bodies, the ones that get exported.
    var exportBodies: [EvaluatedBody] { model.bodies.filter { !hiddenBodies.contains($0.ref) } }

    var exportName: String { documentName ?? "Fillet Design" }

    /// Builds the export off the main thread (fine tessellation can take a moment).
    func exportData(_ format: ExportFormat) async throws -> Data {
        let bodies = exportBodies
        guard !bodies.isEmpty else { throw KernelError("There is nothing to export yet") }
        let preset = document.printerPreset
        let title = exportName
        return try await Task.detached(priority: .userInitiated) {
            switch format {
            case .threeMF:
                let objects = try bodies.map { (name: $0.name, mesh: try $0.shape.tessellate(linearDeflection: 0.01, angularDeflection: 0.1)) }
                return try ThreeMFWriter.write(objects: objects, preset: preset, title: title)
            case .stl:
                let meshes = try bodies.map { try $0.shape.tessellate(linearDeflection: 0.01, angularDeflection: 0.1) }
                return STLWriter.binary(meshes: meshes)
            case .step:
                let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).step")
                defer { try? FileManager.default.removeItem(at: url) }
                try Shape.exportSTEP(bodies.map { ($0.shape, $0.name) }, url: url)
                return try Data(contentsOf: url)
            }
        }.value
    }

    #if os(macOS)
    /// Writes a 3MF to a temporary file and opens it in Bambu Studio (or the default 3MF app).
    func openInBambuStudio() async {
        do {
            let data = try await exportData(.threeMF)
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("Fillet Exports", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let url = dir.appendingPathComponent("\(exportName).3mf")
            try data.write(to: url)
            let workspace = NSWorkspace.shared
            if let app = workspace.urlForApplication(withBundleIdentifier: "com.bambulab.bambu-studio") {
                _ = try await workspace.open([url], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
            } else {
                workspace.open(url)
            }
        } catch {
            message = .error("Couldn't export: \(error.userMessage)")
        }
    }
    #endif
}

extension Error {
    /// A sentence for the user: the kernel's own message, or the system's description, never a type dump.
    var userMessage: String {
        (self as? KernelError)?.message ?? localizedDescription
    }
}

struct ExportMenu: View {
    @Bindable var session: DesignSession
    @State private var exporting: ExportedFile?
    @State private var format: ExportFormat = .threeMF
    @State private var busy = false

    var body: some View {
        Menu {
            #if os(macOS)
            Button {
                Task { await session.openInBambuStudio() }
            } label: { Label("Open in Bambu Studio", systemImage: "printer") }
            Divider()
            #endif
            ForEach(ExportFormat.allCases) { f in
                Button(f.title) { export(f) }
            }
        } label: {
            if busy { ProgressView().controlSize(.small) } else { Label("Export", systemImage: "square.and.arrow.up") }
        }
        .automationFrame("export-menu")
        #if DEBUG && os(iOS)
        .onReceive(NotificationCenter.default.publisher(for: .demoExport)) { _ in export(.threeMF) }
        #endif
        .disabled(session.model.bodies.isEmpty)
        .fileExporter(
            isPresented: Binding(get: { exporting != nil }, set: { if !$0 { exporting = nil } }),
            document: exporting, contentType: format.contentType,
            defaultFilename: "\(session.exportName).\(format.fileExtension)"
        ) { result in
            if case .failure(let error) = result { session.message = .error("Couldn't export: \(error.userMessage)") }
        }
    }

    private func export(_ f: ExportFormat) {
        format = f
        busy = true
        Task {
            defer { busy = false }
            do {
                exporting = ExportedFile(data: try await session.exportData(f))
            } catch {
                session.message = .error("Couldn't export: \(error.userMessage)")
            }
        }
    }
}

struct PrinterMenu: View {
    @Bindable var session: DesignSession

    var body: some View {
        Menu {
            Picker("Printer", selection: Binding(
                get: { session.document.printer },
                set: { id in session.perform("Change Printer") { $0.printer = id } })) {
                ForEach(PrinterPreset.all, id: \.id) { p in
                    Text("\(p.name) — \(Int(p.bedSize.x))×\(Int(p.bedSize.y))×\(Int(p.bedSize.z))").tag(p.id)
                }
            }
            Divider()
            Toggle("Show overhangs", isOn: $session.showOverhangs)
            Picker("Overhang angle", selection: $session.overhangAngle) {
                ForEach([35.0, 40, 45, 50, 55, 60], id: \.self) { Text("\(Int($0))°").tag($0) }
            }
        } label: {
            Label(session.document.printerPreset.name, systemImage: "printer")
        }
    }
}
