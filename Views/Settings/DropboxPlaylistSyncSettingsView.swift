import SwiftUI

struct DropboxPlaylistSyncSettingsView: View {
    @ObservedObject private var sync = DropboxPlaylistSyncCoordinator.shared
    @AppStorage("dropboxPlaylistAppKey") private var appKey = ""
    var body: some View {
        Section {
            Text(sync.musicFolder).textSelection(.enabled)
            Text(sync.isConnected ? (sync.isPaired ? String(localized: "Dropbox connected") : String(localized: "Choose your shared music folder")) : String(localized: "Dropbox disconnected"))
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Connect Dropbox") { Task { await sync.connect() } }
                Button("Choose music folder…") { Task { await sync.chooseMusicFolder() } }.disabled(!sync.isConnected)
                Button("Sync now") { Task { await sync.syncNow() } }.disabled(!sync.isPaired || !sync.isConnected)
                Button("Disconnect") { sync.disconnect() }.disabled(!sync.isConnected)
                if sync.isWorking { ProgressView().controlSize(.small) }
            }.disabled(sync.isWorking)
            Text(sync.status).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            ForEach(sync.states, id: \.localID) { state in
                HStack {
                    Text(AppCoordinator.shared?.playlistManager.playlists.first { $0.id == state.localID }?.name ?? state.intent?.name ?? String(localized: "Shared crate"))
                    Spacer()
                    SharedCrateStatusButton(playlistID: state.localID)
                }.font(.caption)
            }
            DisclosureGroup("Details") {
                TextField("Dropbox app key", text: $appKey)
                Text("Register redirect URI: \(sync.authentication.redirectURI)")
                Text(sync.pairingDetails)
            }.font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
        } header: { Text("Crate connection") }
        .onAppear { sync.refreshStatus() }
    }
}

/// Quiet metadata beside the existing crate information; its sheet owns recovery actions.
struct SharedCrateStatusButton: View {
    let playlistID: UUID
    @ObservedObject private var sync = DropboxPlaylistSyncCoordinator.shared
    @State private var showingDetails = false
    var body: some View {
        Button(sync.summary(for: playlistID)) { showingDetails = true }
            .buttonStyle(.plain)
            .font(.caption).foregroundStyle(.secondary)
            .help("Crate connection details")
            .onAppear { sync.refreshStatus() }
            .sheet(isPresented: $showingDetails) {
                SharedCrateDetails(playlistID: playlistID)
            }
    }
}

private struct SharedCrateDetails: View {
    let playlistID: UUID
    @ObservedObject private var sync = DropboxPlaylistSyncCoordinator.shared
    @Environment(\.dismiss) private var dismiss
    private var state: SyncPlaylistState? { sync.states.first { $0.localID == playlistID } }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(sync.summary(for: playlistID)).font(.headline)
            Text(sync.musicFolder).font(.subheadline).foregroundStyle(.secondary)
            if let state {
                let members = state.intent?.members ?? state.members
                if CrateSyncPresentation.unavailable(state) > 0 {
                    Text("\(CrateSyncPresentation.unavailable(state)) tracks unavailable on this device")
                }
                if CrateSyncPresentation.needsAdding(state) > 0 {
                    Text("\(CrateSyncPresentation.needsAdding(state)) tracks need adding to shared music")
                    Text("Add these recordings to your paired Dropbox music folder, then sync again.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if members.contains(where: { $0.localTrackID == nil || $0.fileId == nil }) {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(Array(members.enumerated()), id: \.offset) { position, member in
                                if member.localTrackID == nil || member.fileId == nil {
                                    Text("\(position + 1). \(sync.trackLabel(member, position: position))")
                                }
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }.frame(maxHeight: 180)
                }
                if state.issue == "invalid" { Text("An invalid revision was retained. No changes were discarded.") }
                if state.issue == "incomplete" { Text("Waiting for missing revisions. Retry sync to download them.") }
                DisclosureGroup("Details") {
                    Text("Shared crate: \(state.sharedID)")
                    ForEach(Array(members.enumerated()), id: \.offset) { position, member in
                        Text("\(position + 1). \(member.fileId ?? String(localized: "Local recording"))")
                    }
                }.font(.caption).textSelection(.enabled)
            }
            Text(sync.status).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            HStack {
                if !sync.isConnected || !sync.isPaired || sync.recovery != nil {
                    Button(sync.recovery ?? (sync.isConnected ? String(localized: "Check music folder") : String(localized: "Connect Dropbox"))) { dismiss(); sync.openConnectionSettings() }
                } else if let state {
                    if state.issue == "conflict" {
                        Button("Review changes…") { sync.resolve(state) }.disabled(sync.isWorking)
                    } else {
                        Button("Sync now") { Task { await sync.syncNow() } }.disabled(sync.isWorking)
                    }
                } else {
                    Button("Share with iPhone") {
                        if let playlist = AppCoordinator.shared?.playlistManager.playlists.first(where: { $0.id == playlistID }) { sync.share(playlist) }
                    }.disabled(sync.isWorking)
                }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }.padding(24).frame(width: 500)
    }
}
