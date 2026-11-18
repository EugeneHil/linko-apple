// LiveNetworkMonitor (Plan 4 Task 13 part 2, LNK-39): the production
// CallNetworkMonitoring — NWPathMonitor wrapped once at the boundary (spec
// 7), its path updates mapped onto CallStats NetworkState values for the
// adaptation policy. The dispatch queue is the monitor's own API surface;
// all of our concurrency above stays structured.

import CallStats
import Foundation
import Network

public final class LiveNetworkMonitor: CallNetworkMonitoring, @unchecked Sendable {
    /// The path states, from the monitor's initial report onward.
    public let states: AsyncStream<NetworkState>

    private let continuation: AsyncStream<NetworkState>.Continuation
    private let monitor = NWPathMonitor()

    public init() {
        (states, continuation) = AsyncStream.makeStream(of: NetworkState.self, bufferingPolicy: .unbounded)
        monitor.pathUpdateHandler = { [continuation] path in
            continuation.yield(Self.networkState(path))
        }
        // NWPathMonitor.start requires a dispatch queue — the delegate-style
        // boundary this module wraps exactly once.
        monitor.start(queue: DispatchQueue(label: "io.github.eugenehil.linko.network-monitor"))
    }

    /// Stops observing.
    public func stop() {
        monitor.cancel()
        continuation.finish()
    }

    /// The path's interface and Low Data Mode flag, as the policy reads them.
    static func networkState(_ path: NWPath) -> NetworkState {
        let interface: NetworkInterface = {
            if path.usesInterfaceType(.cellular) {
                return .cellular
            }
            if path.usesInterfaceType(.wifi) {
                return .wifi
            }
            return .other
        }()
        return NetworkState(interface: interface, isLowDataMode: path.isConstrained)
    }
}
