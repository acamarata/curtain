import Foundation

/// Purpose: Shared XPC contract between the Curtain app (client) and the privileged
///          CurtainHelper daemon (service). Both targets depend on CurtainShared so
///          the protocol and identifiers stay in exactly one place.
/// Inputs: None — this is a declaration unit, not a runtime component.
/// Outputs: The `CurtainDisconnectXPC` remote-object interface and the well-known
///          mach-service / daemon-plist names.
/// Constraints: The protocol is `@objc` because NSXPCInterface requires an
///              Objective-C-visible protocol. The single method is async-by-reply.
/// SPORT: MASTER-DISCONNECT

/// Remote object interface the helper vends and the app calls.
@objc public protocol CurtainDisconnectXPC {
    /// Ask the privileged helper to end the active remote Screen Sharing session.
    /// `reply(true)` if at least one connection process was matched and signalled.
    func endScreenSharingSession(reply: @escaping (Bool) -> Void)
}

/// Well-known identifiers shared by the app and the helper. The mach service name
/// is what the daemon's `NSXPCListener` registers and what the client connects to;
/// the plist name is what `SMAppService.daemon(plistName:)` looks up under
/// `Contents/Library/LaunchDaemons/` of the app bundle.
public enum CurtainHelperInfo {
    public static let machServiceName = "io.acamarata.curtain.helper"
    public static let daemonPlistName = "io.acamarata.curtain.helper.plist"
}
