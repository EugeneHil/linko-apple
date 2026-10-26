import Foundation
import SwiftUI
import WebRTC

/// Throwaway WebRTC session: camera + mic, one data channel "ctl", stats line.
@MainActor
final class PeerSession: NSObject, ObservableObject {
    static let factory: RTCPeerConnectionFactory = {
        RTCInitializeSSL()
        return RTCPeerConnectionFactory(encoderFactory: RTCDefaultVideoEncoderFactory(),
                                        decoderFactory: RTCDefaultVideoDecoderFactory())
    }()

    @Published var status = "idle"
    @Published var stats = ""
    @Published var log: [String] = []
    @Published var remoteVideo: RTCVideoTrack?
    @Published var localVideo: RTCVideoTrack?

    let signaling = SignalingClient()
    var iceServers: [RTCIceServer] = [RTCIceServer(urlStrings: ["stun:stun.l.google.com:19302"])]
    var relayOnly = false
    var onRemoteHangup: (() -> Void)?

    private var pc: RTCPeerConnection?
    private var capturer: RTCCameraVideoCapturer?
    private var localAudio: RTCAudioTrack?
    private var dataChannel: RTCDataChannel?
    private var statsTask: Task<Void, Never>?
    private var lastBytes: (bytes: Int, at: Date)?

    func note(_ line: String) {
        log.append(line)
        if log.count > 12 { log.removeFirst() }
    }

    func setMuted(_ muted: Bool) { localAudio?.isEnabled = !muted }

    /// Creates the peer connection and starts capture. The caller also creates the offer.
    func start(isCaller: Bool) {
        let config = RTCConfiguration()
        config.iceServers = iceServers
        config.sdpSemantics = .unifiedPlan
        config.iceTransportPolicy = relayOnly ? .relay : .all
        config.continualGatheringPolicy = .gatherContinually
        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        guard let pc = Self.factory.peerConnection(with: config, constraints: constraints, delegate: self) else {
            status = "pc failed"; return
        }
        self.pc = pc

        let audio = Self.factory.audioTrack(with: Self.factory.audioSource(with: constraints), trackId: "a0")
        pc.add(audio, streamIds: ["s0"])
        localAudio = audio

        let source = Self.factory.videoSource()
        let capturer = RTCCameraVideoCapturer(delegate: source)
        self.capturer = capturer
        let video = Self.factory.videoTrack(with: source, trackId: "v0")
        pc.add(video, streamIds: ["s0"])
        localVideo = video
        startCapture(capturer)

        if isCaller {
            let dcConfig = RTCDataChannelConfiguration()
            dataChannel = pc.dataChannel(forLabel: "ctl", configuration: dcConfig)
            dataChannel?.delegate = self
            pc.offer(for: constraints) { [weak self] sdp, error in
                guard let sdp else { return }
                Task { @MainActor in
                    guard let self, let pc = self.pc else { return }
                    try? await pc.setLocalDescription(sdp)
                    self.signaling.send(Signal(type: "offer", sdp: sdp.sdp))
                    self.note("offer sent \(error?.localizedDescription ?? "")")
                }
            }
        }
        status = "connecting"
        startStats()
    }

    func handle(_ signal: Signal) {
        guard let pc else { return }
        switch signal.type {
        case "offer":
            Task {
                try? await pc.setRemoteDescription(RTCSessionDescription(type: .offer, sdp: signal.sdp ?? ""))
                let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
                guard let answer = try? await pc.answer(for: constraints) else { note("answer failed"); return }
                try? await pc.setLocalDescription(answer)
                signaling.send(Signal(type: "answer", sdp: answer.sdp))
                note("answer sent")
            }
        case "answer":
            Task { try? await pc.setRemoteDescription(RTCSessionDescription(type: .answer, sdp: signal.sdp ?? "")) }
        case "ice":
            let candidate = RTCIceCandidate(sdp: signal.candidate ?? "", sdpMLineIndex: signal.sdpMLineIndex ?? 0,
                                            sdpMid: signal.sdpMid)
            Task { try? await pc.add(candidate) }
        case "hangup":
            stop()
            onRemoteHangup?()
        default:
            break
        }
    }

    func hangup() {
        signaling.send(Signal(type: "hangup"))
        dataChannel?.sendData(RTCDataBuffer(data: Data("bye".utf8), isBinary: false))
        stop()
    }

    func stop() {
        statsTask?.cancel()
        capturer?.stopCapture()
        pc?.close()
        pc = nil
        dataChannel = nil
        remoteVideo = nil
        localVideo = nil
        status = "ended"
    }

    private func startCapture(_ capturer: RTCCameraVideoCapturer) {
        let devices = RTCCameraVideoCapturer.captureDevices()
        guard let device = devices.first(where: { $0.position == .front }) ?? devices.first else {
            note("no camera"); return
        }
        let formats = RTCCameraVideoCapturer.supportedFormats(for: device)
        let format = formats.last { CMVideoFormatDescriptionGetDimensions($0.formatDescription).width <= 1280 }
            ?? formats.first
        guard let format else { return }
        let fps = min(30, Int(format.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 30))
        capturer.startCapture(with: device, format: format, fps: fps)
    }

    private func startStats() {
        statsTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                await self?.pollStats()
            }
        }
    }

    private func pollStats() async {
        guard let pc else { return }
        let report = await withCheckedContinuation { cont in pc.statistics { cont.resume(returning: $0) } }
        var pairType = "?", rtt = "?", resolution = "?"
        var bytes = 0
        let all = report.statistics
        for (_, s) in all {
            let v = s.values
            if s.type == "candidate-pair", (v["state"] as? String) == "succeeded", (v["nominated"] as? Bool) == true {
                if let r = v["currentRoundTripTime"] as? Double { rtt = "\(Int(r * 1000))ms" }
                if let lid = v["localCandidateId"] as? String, let local = all[lid] {
                    pairType = local.values["candidateType"] as? String ?? "?"
                }
            }
            if s.type == "outbound-rtp", (v["kind"] as? String) == "video" {
                bytes += (v["bytesSent"] as? NSNumber)?.intValue ?? 0
                if let w = v["frameWidth"] as? NSNumber, let h = v["frameHeight"] as? NSNumber { resolution = "\(w)x\(h)" }
            }
        }
        var kbps = "?"
        let now = Date()
        if let last = lastBytes, now > last.at {
            kbps = "\(Int(Double(bytes - last.bytes) * 8 / 1000 / now.timeIntervalSince(last.at)))kbps"
        }
        lastBytes = (bytes, now)
        stats = "pair \(pairType) · rtt \(rtt) · out \(kbps) · \(resolution)"
    }
}

extension PeerSession: RTCPeerConnectionDelegate {
    nonisolated func peerConnection(_ pc: RTCPeerConnection, didChange state: RTCSignalingState) {}
    nonisolated func peerConnection(_ pc: RTCPeerConnection, didAdd stream: RTCMediaStream) {}
    nonisolated func peerConnection(_ pc: RTCPeerConnection, didRemove stream: RTCMediaStream) {}
    nonisolated func peerConnectionShouldNegotiate(_ pc: RTCPeerConnection) {}
    nonisolated func peerConnection(_ pc: RTCPeerConnection, didChange state: RTCIceGatheringState) {}
    nonisolated func peerConnection(_ pc: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}

    nonisolated func peerConnection(_ pc: RTCPeerConnection, didChange state: RTCIceConnectionState) {
        let name = ["new", "checking", "connected", "completed", "failed", "disconnected", "closed", "count"][state.rawValue]
        Task { @MainActor in self.status = "ice \(name)"; self.note("ice \(name)") }
    }

    nonisolated func peerConnection(_ pc: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
        let signal = Signal(type: "ice", candidate: candidate.sdp, sdpMid: candidate.sdpMid,
                            sdpMLineIndex: candidate.sdpMLineIndex)
        Task { @MainActor in self.signaling.send(signal) }
    }

    nonisolated func peerConnection(_ pc: RTCPeerConnection, didStartReceivingOn transceiver: RTCRtpTransceiver) {
        guard let track = transceiver.receiver.track as? RTCVideoTrack else { return }
        Task { @MainActor in self.remoteVideo = track }
    }

    nonisolated func peerConnection(_ pc: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {
        // Assign synchronously: the remote side may already be sending.
        dataChannel.delegate = self
        if dataChannel.readyState == .open {
            dataChannel.sendData(RTCDataBuffer(data: Data("hello over data channel".utf8), isBinary: false))
        }
        Task { @MainActor in self.dataChannel = dataChannel }
    }
}

extension PeerSession: RTCDataChannelDelegate {
    nonisolated func dataChannelDidChangeState(_ dc: RTCDataChannel) {
        if dc.readyState == .open {
            dc.sendData(RTCDataBuffer(data: Data("hello over data channel".utf8), isBinary: false))
        }
    }

    nonisolated func dataChannel(_ dc: RTCDataChannel, didReceiveMessageWith buffer: RTCDataBuffer) {
        let text = String(data: buffer.data, encoding: .utf8) ?? "<binary>"
        Task { @MainActor in
            self.note("dc: \(text)")
            if text == "bye" { self.stop(); self.onRemoteHangup?() }
        }
    }
}

/// Renders a WebRTC video track in SwiftUI.
struct VideoView: View {
    let track: RTCVideoTrack?
    var body: some View { Representable(track: track) }
}

#if os(iOS)
private struct Representable: UIViewRepresentable {
    let track: RTCVideoTrack?
    func makeUIView(context: Context) -> RTCMTLVideoView {
        let view = RTCMTLVideoView()
        view.videoContentMode = .scaleAspectFill
        return view
    }
    func updateUIView(_ view: RTCMTLVideoView, context: Context) {
        context.coordinator.attach(track, to: view)
    }
    func makeCoordinator() -> TrackBinding { TrackBinding() }
}
#else
private struct Representable: NSViewRepresentable {
    let track: RTCVideoTrack?
    func makeNSView(context: Context) -> RTCMTLNSVideoView { RTCMTLNSVideoView() }
    func updateNSView(_ view: RTCMTLNSVideoView, context: Context) {
        context.coordinator.attach(track, to: view)
    }
    func makeCoordinator() -> TrackBinding { TrackBinding() }
}
#endif

final class TrackBinding {
    private var track: RTCVideoTrack?
    private weak var renderer: (RTCVideoRenderer & AnyObject)?
    func attach(_ new: RTCVideoTrack?, to renderer: RTCVideoRenderer & AnyObject) {
        guard new !== track else { return }
        if let track, let old = self.renderer { track.remove(old) }
        new?.add(renderer)
        track = new
        self.renderer = renderer
    }
}

/// Shared connection settings form.
struct SettingsForm: View {
    @AppStorage("relay") var relay = "ws://192.168.1.10:9000"
    @AppStorage("turnURL") var turnURL = ""
    @AppStorage("turnUser") var turnUser = ""
    @AppStorage("turnCredential") var turnCredential = ""
    @AppStorage("relayOnly") var relayOnly = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("ws://relay:9000", text: $relay)
            TextField("turn:<vps-ip>:3478", text: $turnURL)
            TextField("TURN username", text: $turnUser)
            TextField("TURN credential", text: $turnCredential)
            Toggle("Relay only (force TURN)", isOn: $relayOnly)
        }
        .textFieldStyle(.roundedBorder)
        .autocorrectionDisabled()
    }

    @MainActor
    static func apply(to session: PeerSession) -> URL? {
        let d = UserDefaults.standard
        var servers = [RTCIceServer(urlStrings: ["stun:stun.l.google.com:19302"])]
        if let url = d.string(forKey: "turnURL"), !url.isEmpty {
            servers.append(RTCIceServer(urlStrings: [url, url + "?transport=tcp"],
                                        username: d.string(forKey: "turnUser"),
                                        credential: d.string(forKey: "turnCredential")))
        }
        session.iceServers = servers
        session.relayOnly = d.bool(forKey: "relayOnly")
        return URL(string: d.string(forKey: "relay") ?? "")
    }
}
