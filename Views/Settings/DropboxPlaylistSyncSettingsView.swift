import SwiftUI

struct DropboxPlaylistSyncSettingsView: View {
    @ObservedObject private var sync = DropboxPlaylistSyncCoordinator.shared
    @AppStorage("dropboxPlaylistAppKey") private var appKey = ""
    @AppStorage("dropboxPlaylistMusicPath") private var musicPath = ""
    var body: some View {
        Section {
            TextField("Dropbox app key", text: $appKey)
                .help("Public Dropbox application key. The registration must permit this native callback and read/write access to the music folder.")
            Text("Register redirect URI: \(sync.authentication.redirectURI)")
                .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            TextField("Dropbox music folder path", text: $musicPath)
                .help("Use / for the Crate App folder. For Full Dropbox access, use an existing folder path or id:. Pair the same folder on iPhone.")
            HStack {
                Button("Connect Dropbox") { Task { await sync.connect() } }
                Button("Pair Music Folder…") { Task { await sync.pair(remotePath: musicPath) } }
                Button("Sync Now") { Task { await sync.syncNow() } }.disabled(!sync.isPaired)
                Button("Disconnect") { sync.disconnect() }
                if sync.isWorking { ProgressView().controlSize(.small) }
            }
            .disabled(sync.isWorking)
            Text(sync.status).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            if !sync.states.isEmpty {
                ForEach(sync.states, id: \.localID) { state in
                    HStack {
                        let name = AppCoordinator.shared?.playlistManager.playlists.first { $0.id == state.localID }?.name ?? state.intent?.name ?? "Shared playlist"
                        Text(name)
                        Spacer()
                        let missing = state.members.filter { $0.localTrackID == nil }.count
                        if missing > 0 { Text("\(missing) unavailable").foregroundStyle(.secondary) }
                        if state.issue == "conflict" {
                            Button("Resolve…") { sync.resolve(state) }.disabled(sync.isWorking)
                        } else if state.issue == "mapping" { Text("Verify Dropbox songs").foregroundStyle(.secondary) }
                        else if state.issue == "invalid" { Text("Invalid revision retained").foregroundStyle(.secondary) }
                        else if state.issue == "incomplete" { Text("Waiting for revisions").foregroundStyle(.secondary) }
                        else if state.intent != nil { Text("Pending edit").foregroundStyle(.secondary) }
                    }.font(.caption)
                }
            }
        } header: { Text("Crate Playlist Sync — Dropbox") }
        .onAppear { sync.refreshStatus() }
    }
}
