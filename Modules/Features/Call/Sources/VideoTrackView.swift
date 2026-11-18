// VideoTrackView (Plan 4 Task 13 part 2, LNK-39): the WebRTC metal
// renderer bound to a VideoTrackHandle — RTCMTLVideoView on iOS,
// RTCMTLNSVideoView on macOS (the vendored WebRTC 155's per-platform
// renderer classes). The track attaches when the view is created/updated
// and detaches when it goes away; rendering the track's frames is the
// whole behavior — no state machine knowledge of its own.

import CallEngine
import SwiftUI
import WebRTC

/// Renders one video track handle through the platform's metal renderer.
public struct VideoTrackView: View {
    private let handle: any VideoTrackHandle

    public init(handle: any VideoTrackHandle) {
        self.handle = handle
    }

    public var body: some View {
        TrackRendererView(track: handle.renderable)
    }
}

#if os(iOS)
    struct TrackRendererView: UIViewRepresentable {
        let track: RTCVideoTrack?

        func makeCoordinator() -> Coordinator {
            Coordinator()
        }

        func makeUIView(context: Context) -> RTCMTLVideoView {
            let view = RTCMTLVideoView()
            view.videoContentMode = .scaleAspectFill
            attach(track, to: view)
            context.coordinator.track = track
            return view
        }

        func updateUIView(_ view: RTCMTLVideoView, context: Context) {
            guard context.coordinator.track !== track else { return }
            context.coordinator.track?.remove(view)
            attach(track, to: view)
            context.coordinator.track = track
        }

        static func dismantleUIView(_ view: RTCMTLVideoView, coordinator: Coordinator) {
            coordinator.track?.remove(view)
        }

        final class Coordinator {
            var track: RTCVideoTrack?
        }

        private func attach(_ track: RTCVideoTrack?, to view: RTCMTLVideoView) {
            guard let track else { return }
            track.add(view)
        }
    }
#else
    struct TrackRendererView: NSViewRepresentable {
        let track: RTCVideoTrack?

        func makeCoordinator() -> Coordinator {
            Coordinator()
        }

        func makeNSView(context: Context) -> RTCMTLNSVideoView {
            let view = RTCMTLNSVideoView()
            attach(track, to: view)
            context.coordinator.track = track
            return view
        }

        func updateNSView(_ view: RTCMTLNSVideoView, context: Context) {
            guard context.coordinator.track !== track else { return }
            context.coordinator.track?.remove(view)
            attach(track, to: view)
            context.coordinator.track = track
        }

        static func dismantleNSView(_ view: RTCMTLNSVideoView, coordinator: Coordinator) {
            coordinator.track?.remove(view)
        }

        final class Coordinator {
            var track: RTCVideoTrack?
        }

        private func attach(_ track: RTCVideoTrack?, to view: RTCMTLNSVideoView) {
            guard let track else { return }
            track.add(view)
        }
    }
#endif
