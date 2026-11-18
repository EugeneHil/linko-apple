// MacCallPresenter (Plan 4 Task 10 / LNK-36, macOS only): the macOS
// reporting surface — an own incoming-call window plus a user notification
// when the window is not key (spec §4.3); the window's accept/reject
// closures route into the coordinator.

#if os(macOS)
    import AppKit
    import Calls
    import Foundation
    import Synchronization
    import UserNotifications

    /// The incoming-call window surface (the live window is a small floating
    /// panel; tests record instead).
    public protocol MacIncomingWindowPresenting: Sendable {
        func showIncoming(
            callId: String,
            peer: String,
            video: Bool,
            onAccept: @escaping @Sendable () async -> Void,
            onReject: @escaping @Sendable () async -> Void
        ) async
        func hideIncoming(callId: String) async
        func incomingWindowIsKey() async -> Bool
    }

    /// The user notification surface (the live poster wraps
    /// UNUserNotificationCenter; tests record instead).
    public protocol MacUserNotifying: Sendable {
        func postIncomingCall(callId: String, peer: String) async
    }

    /// The macOS reporting surface: window + notification instead of CallKit
    /// (spec §4.3). The presenter owns the routing; the window stays dumb.
    public final class MacCallPresenter: CallReporting, Sendable {
        private let window: any MacIncomingWindowPresenting
        private let notifier: any MacUserNotifying
        private let coordinator: any CallCoordinating
        private let activeCall = Mutex<String?>(nil)

        public init(
            window: any MacIncomingWindowPresenting,
            notifier: any MacUserNotifying,
            coordinator: any CallCoordinating
        ) {
            self.window = window
            self.notifier = notifier
            self.coordinator = coordinator
        }

        // MARK: CallReporting

        /// ReportIncoming: show the own incoming-call window; when the
        /// window is not key (the app is in the background or another window
        /// has focus), a user notification draws the attention.
        public func reportIncoming(callId: String, peer: String, video: Bool) async {
            activeCall.withLock { $0 = callId }
            await window.showIncoming(
                callId: callId,
                peer: peer,
                video: video,
                onAccept: { [coordinator] in await coordinator.accept() },
                onReject: { [coordinator] in await coordinator.reject() }
            )
            let key = await window.incomingWindowIsKey()
            if !key {
                await notifier.postIncomingCall(callId: callId, peer: peer)
            }
        }

        /// ReportEnded: the window dies with the call.
        public func reportEnded(callId: String, reason _: CallEndReason) async {
            await window.hideIncoming(callId: callId)
            activeCall.withLock {
                if $0 == callId {
                    $0 = nil
                }
            }
        }

        /// StartRinging: the incoming-call window carries the ring UI; the
        /// Mac has no system ringtone surface in v0.1.
        public func startRinging() async {}

        /// StopRinging: hide the window when the ring dies with accept,
        /// reject or cancel.
        public func stopRinging() async {
            let callId = activeCall.withLock { state -> String? in
                let id = state
                state = nil
                return id
            }
            if let callId {
                await window.hideIncoming(callId: callId)
            }
        }
    }

    /// The live incoming-call panel: peer label plus Accept/Decline buttons
    /// wired to the presenter's closures.
    @MainActor
    public final class IncomingCallWindow: NSObject, MacIncomingWindowPresenting {
        private weak var panel: NSPanel?
        private var acceptAction: (@Sendable () async -> Void)?
        private var rejectAction: (@Sendable () async -> Void)?

        override init() {
            super.init()
        }

        public func showIncoming(
            callId _: String,
            peer: String,
            video: Bool,
            onAccept: @escaping @Sendable () async -> Void,
            onReject: @escaping @Sendable () async -> Void
        ) async {
            acceptAction = onAccept
            rejectAction = onReject

            let panel = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: 260, height: 110),
                styleMask: [.titled, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            panel.title = video ? "Incoming video call" : "Incoming call"
            panel.level = .floating
            panel.isReleasedWhenClosed = false

            let peerLabel = NSTextField(labelWithString: peer)
            peerLabel.frame = NSRect(x: 16, y: 66, width: 228, height: 26)
            let acceptButton = NSButton(title: "Accept", target: self, action: #selector(acceptClicked))
            acceptButton.frame = NSRect(x: 16, y: 20, width: 105, height: 32)
            acceptButton.bezelStyle = .rounded
            let declineButton = NSButton(title: "Decline", target: self, action: #selector(declineClicked))
            declineButton.frame = NSRect(x: 139, y: 20, width: 105, height: 32)
            declineButton.bezelStyle = .rounded

            panel.contentView?.addSubview(peerLabel)
            panel.contentView?.addSubview(acceptButton)
            panel.contentView?.addSubview(declineButton)

            panel.center()
            panel.makeKeyAndOrderFront(nil)
            self.panel = panel
        }

        public func hideIncoming(callId _: String) async {
            panel?.orderOut(nil)
            panel = nil
            acceptAction = nil
            rejectAction = nil
        }

        public func incomingWindowIsKey() async -> Bool {
            panel?.isKeyWindow ?? false
        }

        @objc private func acceptClicked() {
            let accept = acceptAction
            Task { await accept?() }
        }

        @objc private func declineClicked() {
            let reject = rejectAction
            Task { await reject?() }
        }
    }

    /// The live user notification poster (UNUserNotificationCenter).
    public struct LiveMacNotifier: MacUserNotifying {
        public init() {}

        public func postIncomingCall(callId: String, peer: String) async {
            let center = UNUserNotificationCenter.current()
            let granted = await (try? center.requestAuthorization(options: [.alert, .sound])) ?? false
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = peer
            content.body = "Incoming call"
            content.sound = .default
            let request = UNNotificationRequest(
                identifier: "incoming-call-\(callId)",
                content: content,
                trigger: nil
            )
            try? await center.add(request)
        }
    }
#endif
