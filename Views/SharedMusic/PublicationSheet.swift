import SwiftUI

struct PublicationSheet: View {
    @ObservedObject var coordinator: PublicationCoordinator
    @State private var copyConsent = false
    private var valid: Bool { coordinator.canSubmit(copyConsent: copyConsent) }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Add to shared music").font(.headline)
            Text("\(coordinator.selection.count) tracks · \(ByteCountFormatter.string(fromByteCount: coordinator.selection.compactMap(\.size).reduce(0, +), countStyle: .file)) known")
                .font(.subheadline).foregroundStyle(.secondary)
            Text(coordinator.destinationFolder).textSelection(.enabled)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach($coordinator.selection) { $entry in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(entry.title).font(.system(size: 14, weight: .medium))
                            if entry.rejectedDestination != nil {
                                if entry.outsideRoot { Text("Approve a different destination path to retry.").foregroundStyle(.secondary) }
                                else { Text("Rename or move the original inside your paired folder, then select it again.").foregroundStyle(.secondary) }
                            }
                            if entry.outsideRoot {
                                TextField("Destination relative path", text: $entry.destination)
                            } else { Text(entry.destination).font(.caption).foregroundStyle(.secondary) }
                        }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.frame(height: min(CGFloat(coordinator.selection.count) * 72, 220))
            Text("Existing files are never overwritten. Identical bytes may already be shared; different bytes need a new name.")
            Text("Phone playback depends on decoder support. Adding a file does not confirm it will play.")
            Text("Original files and crate memberships are preserved. Audio is copied without conversion or tag changes.")
            if coordinator.selection.contains(where: \.outsideRoot) {
                Toggle("I approve copying the selected outside-folder recordings into the paired music folder at these paths.", isOn: $copyConsent)
            }
            HStack {
                Spacer()
                Button("Cancel") { coordinator.dismissConfirmation() }.keyboardShortcut(.cancelAction)
                Button("Add \(coordinator.selection.count) tracks") { coordinator.submit(copyConsent: copyConsent) }
                    .keyboardShortcut(.defaultAction).disabled(!valid)
            }
        }.font(.system(size: 12)).padding(24).frame(width: 520)
    }
}

struct PublicationResults: View {
    @ObservedObject var coordinator: PublicationCoordinator
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Shared music").font(.headline)
            let added = coordinator.rows.filter { $0.state == .completed && $0.uploadSession != nil }.count
            let reused = coordinator.rows.filter { $0.state == .completed && $0.uploadSession == nil }.count
            let failed = coordinator.rows.filter { $0.state == .failed }.count
            Text("\(added) added · \(reused) already shared · \(failed) failed")
                .font(.caption).foregroundStyle(.secondary)
            ForEach(coordinator.rows.reversed(), id: \.id) { row in
                VStack(alignment: .leading, spacing: 4) {
                    Text(URL(fileURLWithPath: row.snapshot.sourcePath).lastPathComponent).lineLimit(2)
                    Text(PublicationCoordinator.result(row)).foregroundStyle(.secondary)
                    if let explanation = PublicationCoordinator.explanation(row) { Text(explanation).font(.caption) }
                    Text(row.destination).font(.caption).foregroundStyle(.secondary)
                    if row.state == .uploading || row.state == .verifying, let size = row.snapshot.sourceIdentity?.size {
                        ProgressView(value: min(Double(row.uploadSession?.offset ?? 0), Double(size)), total: max(Double(size), 1))
                    }
                    HStack {
                        if row.state != .completed {
                            if row.error == .auth || row.error == .root {
                                Button("Set up connection…") { coordinator.setUpConnection() }
                            }
                            if !coordinator.activeIDs.contains(row.id) {
                            Button(row.error == .finishUncertain ? String(localized: "Check outcome") : String(localized: "Retry…")) { coordinator.recover(row) }
                            }
                            if row.state != .cancelled && row.state != .failed {
                                Button("Cancel") { coordinator.cancel(row.id) }
                            }
                        }
                    }.controlSize(.small)
                }.font(.system(size: 12))
                Divider()
            }
            if let issue = coordinator.issue { Text(issue).foregroundStyle(.secondary) }
        }.padding(10)
    }
}
