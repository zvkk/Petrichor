//
// NowPlayingControlsView
//
// Compact, artwork-tinted transport row shared by the mini player and immersive
// mode. Reuses the same manager calls and button styling as PlayerView
// (ControlButtonStyle, hoverEffect).
//

import SwiftUI
import AppKit

struct NowPlayingControlsView: View {
    /// Host artwork tint retained for compatibility with the existing player composition.
    let tint: Color
    /// Legible, mode-adjusted color for the active shuffle/repeat states.
    var accent: Color
    /// Color for the prev/next transport icons.
    var transport: Color
    /// Base color for inactive/secondary icons (white on the mini player's dark
    /// scrim; adaptive in immersive mode).
    var neutral: Color = .white
    var scale: CGFloat = 1

    @EnvironmentObject var playbackManager: PlaybackManager
    @EnvironmentObject var playlistManager: PlaylistManager

    @State private var playButtonPressed = false

    /// A stream is not part of the queue these act on.
    private var transportDisabled: Bool {
        playbackManager.isTransportDisabled || playbackManager.isPreviewing
    }

    var body: some View {
        HStack(spacing: 20 * scale) {
            shuffleButton
            previousButton
            playPauseButton
            nextButton
            repeatButton
        }
    }

    private var shuffleButton: some View {
        Button(action: {
            playlistManager.toggleShuffle()
        }, label: {
            Image(systemName: Icons.shuffleFill)
                .font(.system(size: 13 * scale, weight: .medium))
                .foregroundColor(playlistManager.isShuffleEnabled ? accent : neutral.opacity(0.65))
                .frame(width: 24 * scale, height: 24 * scale)
                .activeControlIndicator(isActive: playlistManager.isShuffleEnabled, color: accent, scale: scale)
        })
        .buttonStyle(ControlButtonStyle())
        .hoverEffect(scale: 1.1)
        .opacity(transportDisabled ? ViewDefaults.disabledControlOpacity : 1)
        .disabled(transportDisabled)
        .help(playlistManager.isShuffleEnabled ? String(localized: "Disable Shuffle") : String(localized: "Enable Shuffle"))
    }

    private var previousButton: some View {
        Button(action: {
            playlistManager.playPreviousTrack()
        }, label: {
            Image(systemName: "backward.end")
                .font(.system(size: 16 * scale, weight: .medium))
                .foregroundColor(transport)
                .frame(width: 24 * scale, height: 24 * scale)

        })
        .buttonStyle(ControlButtonStyle())
        .hoverEffect(scale: 1.1)
        .opacity(transportDisabled ? ViewDefaults.disabledControlOpacity : 1)
        .disabled(transportDisabled)
        .help("Previous")
    }

    private var playPauseButton: some View {
        Button(action: {
            playbackManager.togglePlayPause()
        }, label: {
            PlayPauseIcon(isPlaying: playbackManager.isPlaying, stopInsteadOfPause: playbackManager.hasStation)
                .frame(width: 42 * scale, height: 42 * scale)
                .background(
                    Circle()
                        .fill(CrateStyle.paper)
                        .overlay(Circle().strokeBorder(CrateStyle.ink, lineWidth: 1))
                )
        })
        .buttonStyle(PlainButtonStyle())
        .hoverEffect(scale: 1.1)
        .scaleEffect(playButtonPressed ? 0.95 : 1.0)
        .animation(.easeInOut(duration: AnimationDuration.quickDuration), value: playButtonPressed)
        .onLongPressGesture(
            minimumDuration: 0,
            maximumDistance: .infinity,
            pressing: { pressing in
                playButtonPressed = pressing
            },
            perform: {}
        )
        .disabled(!playbackManager.hasPlayableContent)
        .help(playbackManager.playPauseActionTitle)
    }

    private var nextButton: some View {
        Button(action: {
            playlistManager.playNextTrack()
        }, label: {
            Image(systemName: "forward.end")
                .font(.system(size: 16 * scale, weight: .medium))
                .foregroundColor(transport)
                .frame(width: 24 * scale, height: 24 * scale)

        })
        .buttonStyle(ControlButtonStyle())
        .hoverEffect(scale: 1.1)
        .opacity(transportDisabled ? ViewDefaults.disabledControlOpacity : 1)
        .disabled(transportDisabled)
        .help("Next")
    }

    private var repeatButton: some View {
        Button(action: {
            playlistManager.toggleRepeatMode()
        }, label: {
            Image(systemName: Icons.repeatIcon(for: playlistManager.repeatMode))
                .font(.system(size: 13 * scale, weight: .medium))
                .foregroundColor(playlistManager.repeatMode != .off ? accent : neutral.opacity(0.65))
                .frame(width: 24 * scale, height: 24 * scale)
                .activeControlIndicator(isActive: playlistManager.repeatMode != .off, color: accent, scale: scale)
        })
        .buttonStyle(ControlButtonStyle())
        .hoverEffect(scale: 1.1)
        .opacity(transportDisabled ? ViewDefaults.disabledControlOpacity : 1)
        .disabled(transportDisabled)
        .help(playlistManager.repeatMode.tooltip)
    }
}
