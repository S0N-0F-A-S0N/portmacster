import Foundation

// Define the protocol for the XPC service.
// This protocol outlines the methods that the XPC server (Go helper) will implement
// and the XPC client (Swift System Extension) will call.
@objc public protocol PortmasterXPCServicable {
    /**
     * Processes new flow information received from the Network Extension.
     *
     * - Parameters:
     *   - bundleID: The bundle identifier of the source application, if available.
     *   - sourceIP: The source IP address of the flow.
     *   - destinationIP: The destination IP address of the flow.
     *   - completionHandler: A handler to call back with a boolean indicating success or failure.
     */
    func processNewFlow(bundleID: String,
                        sourceIP: String,
                        destinationIP: String,
                        sourcePort: Int,
                        destinationPort: Int,
                        protocol: Int,
                        auditToken: Data, // audit_token_t will be passed as Data
                        completionHandler: @escaping (Bool) -> Void)

    // Future methods for sending packet data, configuration updates, etc., can be added here.
    // For example:
    // func processPacketData(_ packetData: Data, metadata: [String: Any], completionHandler: @escaping (Bool) -> Void)
}

// Define a struct for more complex data if needed in the future.
// For the current `processNewFlow` method, simple types are used directly.
// If we were sending, for example, a full packet anaysis:
/*
public struct FlowDetails: Codable {
    let bundleID: String?
    let sourceIP: String
    let destinationIP: String
    let sourcePort: Int
    let destinationPort: Int
    let protocolType: Int // e.g., IPPROTO_TCP, IPPROTO_UDP
    let auditToken: Data? // Optional if it cannot always be retrieved
    // Add other relevant fields
}

// The protocol method would then look like:
// func processDetailedFlow(_ flowDetailsData: Data, completionHandler: @escaping (Bool) -> Void)
*/

// Service name for the XPC connection. This should be unique.
// It's typically the bundle ID of the app providing the XPC service.
public let portmasterXPCServiceIdentifier = "com.safing.portmaster.xpcservice"
