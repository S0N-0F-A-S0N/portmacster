import NetworkExtension
import os.log

class PortmasterTunnelProvider: NEPacketTunnelProvider {

    let defaultLog = OSLog(subsystem: "com.safing.portmaster.macos.tunnel", category: "PortmasterTunnel")

    override func startTunnel(options: [String: NSObject]?, completionHandler: @escaping (Error?) -> Void) {
        os_log(.default, log: defaultLog, "PortmasterTunnelProvider: Starting tunnel...")

        let tunnelNetworkSettings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "127.0.0.1")
        // Specify the IP addresses and subnets that should be routed through the tunnel.
        // For now, let's route all IPv4 traffic.
        tunnelNetworkSettings.ipv4Settings = NEIPv4Settings(addresses: ["192.168.200.1"], subnetMasks: ["255.255.255.0"])
        tunnelNetworkSettings.ipv4Settings?.includedRoutes = [NEIPv4Route.default()]
        // It's common to exclude local network traffic if you only want to tunnel internet traffic.
        // tunnelNetworkSettings.ipv4Settings?.excludedRoutes = [NEIPv4Route(destinationAddress: "192.168.0.0", subnetMask: "255.255.0.0")]


        setTunnelNetworkSettings(tunnelNetworkSettings) { error in
            if let error = error {
                os_log(.error, log: self.defaultLog, "PortmasterTunnelProvider: Failed to set tunnel network settings: %{public}@", error.localizedDescription)
                completionHandler(error)
                return
            }
            os_log(.default, log: self.defaultLog, "PortmasterTunnelProvider: Tunnel network settings applied.")
            // Start reading packets after the tunnel is established.
            self.readPackets()

            // Call the C function to send a message to Go
            let message = "Tunnel started successfully"
            if let cMessage = message.cString(using: .utf8) {
                send_data_to_go(cMessage)
                os_log(.default, log: self.defaultLog, "PortmasterTunnelProvider: Sent message to Go: %{public}@", message)
            } else {
                os_log(.error, log: self.defaultLog, "PortmasterTunnelProvider: Failed to create C string for message to Go.")
            }

            completionHandler(nil)
        }
    }

    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        os_log(.default, log: defaultLog, "PortmasterTunnelProvider: Stopping tunnel with reason %{public}@", String(describing: reason))
        // Add cleanup code here.
        completionHandler()
    }

    override func handleAppMessage(_ messageData: Data, completionHandler: ((Data?) -> Void)? = nil) {
        os_log(.default, log: defaultLog, "PortmasterTunnelProvider: Received app message.")
        // Handle messages from the main app.
        if let handler = completionHandler {
            handler(nil) // Respond if necessary
        }
    }

    override func sleep(completionHandler: @escaping () -> Void) {
        os_log(.default, log: defaultLog, "PortmasterTunnelProvider: Tunnel is going to sleep.")
        // Add code to handle tunnel sleep.
        completionHandler()
    }

    override func wake() {
        os_log(.default, log: defaultLog, "PortmasterTunnelProvider: Tunnel woke up.")
        // Add code to handle tunnel wake-up.
        // Re-establish XPC connection if it was invalidated.
        setupXPCConnection()
    }

    // MARK: - XPC Connection

    private var xpcConnection: NSXPCConnection?

    private func setupXPCConnection() {
        // Ensure only one connection is active
        if self.xpcConnection != nil {
            // Check if the existing connection is valid. If not, invalidate and create a new one.
            // For simplicity, we create a new one each time wake() or startTunnel() might imply a need.
            // More robust handling would involve checking connection.isValid.
            self.xpcConnection?.invalidate()
            self.xpcConnection = nil
        }

        let connection = NSXPCConnection(serviceName: portmasterXPCServiceIdentifier)
        connection.remoteObjectInterface = NSXPCInterface(with: PortmasterXPCServicable.self)
        
        connection.invalidationHandler = { [weak self] in
            os_log(.error, log: self!.defaultLog, "PortmasterTunnelProvider: XPC Connection Invalidated.")
            self?.xpcConnection = nil
            // Optionally attempt to reconnect after a delay or on next event
        }
        
        connection.interruptionHandler = { [weak self] in
            os_log(.error, log: self!.defaultLog, "PortmasterTunnelProvider: XPC Connection Interrupted.")
            self?.xpcConnection = nil
            // Optionally attempt to reconnect
        }
        
        self.xpcConnection = connection
        connection.resume()
        os_log(.default, log: defaultLog, "PortmasterTunnelProvider: XPC Connection to %{public}@ established.", portmasterXPCServiceIdentifier)
    }

    private func sendFlowToXPC(bundleID: String, sourceIP: String, destinationIP: String) {
        guard let connection = self.xpcConnection else {
            os_log(.error, log: defaultLog, "PortmasterTunnelProvider: XPC connection is nil. Cannot send flow.")
            // Attempt to re-establish connection for next time
            setupXPCConnection()
            return
        }
        
        let remoteObject = connection.remoteObjectProxyWithErrorHandler { error in
            os_log(.error, log: self.defaultLog, "PortmasterTunnelProvider: XPC remote object error: %{public}@", error.localizedDescription)
            // Connection might be invalid, consider re-establishing
            self.xpcConnection?.invalidate()
            self.xpcConnection = nil
            self.setupXPCConnection()
        } as? PortmasterXPCServicable
        
        if let proxy = remoteObject {
            proxy.processNewFlow(bundleID: bundleID, sourceIP: sourceIP, destinationIP: destinationIP) { success in
                if success {
                    os_log(.debug, log: self.defaultLog, "PortmasterTunnelProvider: Successfully sent flow to XPC service.")
                } else {
                    os_log(.error, log: self.defaultLog, "PortmasterTunnelProvider: XPC service failed to process flow.")
                }
            }
        } else {
            os_log(.error, log: defaultLog, "PortmasterTunnelProvider: XPC remote object proxy is nil.")
        }
    }


    // MARK: - Packet Handling

    private func readPackets() {
        packetFlow.readPackets { [weak self] packets, protocols in
            guard let self = self else { return }

            for packetData in packets {
                // Basic parsing to get IP addresses (example for IPv4)
                // This is highly simplified. Proper IP parsing is needed.
                guard packetData.count >= 20 else { continue } // Basic check for IPv4 header size
                let sourceIPRaw = packetData.subdata(in: 12..<16)
                let destIPRaw = packetData.subdata(in: 16..<20)

                // Parse the packet
                let (sourceIP, destinationIP, protocolType, sourcePort, destinationPort) = self.parseIPPacket(packetData)

                let metadata = self.packetFlow.metadata(for: packetData)
                let bundleID = metadata?.sourceAppUniqueIdentifier ?? "N/A"
                
                os_log(.default, log: self.defaultLog, """
                    PortmasterTunnelProvider: Intercepted IP packet. App: %{public}@, \
                    Src: %{public}@:%d, Dst: %{public}@:%d, Proto: %d
                    """, bundleID, sourceIP ?? "N/A", sourcePort ?? 0, destinationIP ?? "N/A", destinationPort ?? 0, protocolType ?? 0)

                // Send flow information via XPC, including new fields
                // The XPC interface will be updated in a subsequent step.
                if let srcIP = sourceIP, let dstIP = destinationIP, let proto = protocolType {
                    self.sendFlowToXPC(bundleID: bundleID, 
                                       sourceIP: srcIP, 
                                       destinationIP: dstIP,
                                       sourcePort: sourcePort ?? 0, // Default to 0 if not available (e.g. ICMP)
                                       destinationPort: destinationPort ?? 0, // Default to 0 if not available
                                       protocol: proto)
                } else {
                    os_log(.error, log: self.defaultLog, "PortmasterTunnelProvider: Could not parse full IP packet details for XPC.")
                }
                
                // Remove CGo call for now, prefer XPC
                // let packetInfoMessage = "Packet intercepted. App: \(bundleID)"
                // if let cPacketInfoMessage = packetInfoMessage.cString(using: .utf8) {
                //     send_data_to_go(cPacketInfoMessage)
                // }
            }
            // Continue reading packets.
            self.readPackets()
        }
    }

    
    // Helper structures for parsing
    struct IPv4Header {
        var versionAndIHL: UInt8
        var differentiatedServices: UInt8
        var totalLength: UInt16
        var identification: UInt16
        var flagsAndFragmentOffset: UInt16
        var timeToLive: UInt8
        var `protocol`: UInt8
        var headerChecksum: UInt16
        var sourceIP: UInt32
        var destinationIP: UInt32
        // Options and padding can follow
    }

    struct TCPHeader {
        var sourcePort: UInt16
        var destinationPort: UInt16
        var sequenceNumber: UInt32
        var acknowledgmentNumber: UInt32
        var dataOffsetAndFlags: UInt16 // First 4 bits are data offset, next 3 reserved, next 9 are flags
        var windowSize: UInt16
        var checksum: UInt16
        var urgentPointer: UInt16
        // Options and padding can follow
    }

    struct UDPHeader {
        var sourcePort: UInt16
        var destinationPort: UInt16
        var length: UInt16
        var checksum: UInt16
    }

    private func parseIPPacket(_ data: Data) -> (sourceIP: String?, destinationIP: String?, protocol: Int?, sourcePort: Int?, destinationPort: Int?) {
        guard data.count >= 20 else { // Minimum IPv4 header size
            os_log(.error, log: defaultLog, "PortmasterTunnelProvider: Packet too short for IPv4 header.")
            return (nil, nil, nil, nil, nil)
        }

        // Assuming IPv4 for now
        let ipHeader = data.withUnsafeBytes { $0.load(as: IPv4Header.self) }
        
        let sourceIPString = ipv4AddressToString(ipHeader.sourceIP)
        let destinationIPString = ipv4AddressToString(ipHeader.destinationIP)
        let protocolType = Int(ipHeader.protocol)
        
        var sourcePort: Int? = nil
        var destinationPort: Int? = nil

        let ipHeaderLength = Int((ipHeader.versionAndIHL & 0x0F) * 4) // IHL is in 4-byte words

        guard data.count >= ipHeaderLength else {
            os_log(.error, log: defaultLog, "PortmasterTunnelProvider: Packet too short for full IP header (IHL: %d).", ipHeaderLength)
            return (sourceIPString, destinationIPString, protocolType, nil, nil)
        }

        if protocolType == IPPROTO_TCP { // 6 for TCP
            guard data.count >= ipHeaderLength + 20 else { // Minimum TCP header size
                os_log(.error, log: defaultLog, "PortmasterTunnelProvider: TCP packet too short for header.")
                return (sourceIPString, destinationIPString, protocolType, nil, nil)
            }
            let tcpHeader = data.subdata(in: ipHeaderLength..<(ipHeaderLength + 20)).withUnsafeBytes { $0.load(as: TCPHeader.self) }
            sourcePort = Int(CFSwapInt16BigToHost(tcpHeader.sourcePort))
            destinationPort = Int(CFSwapInt16BigToHost(tcpHeader.destinationPort))
        } else if protocolType == IPPROTO_UDP { // 17 for UDP
            guard data.count >= ipHeaderLength + 8 else { // UDP header size
                os_log(.error, log: defaultLog, "PortmasterTunnelProvider: UDP packet too short for header.")
                return (sourceIPString, destinationIPString, protocolType, nil, nil)
            }
            let udpHeader = data.subdata(in: ipHeaderLength..<(ipHeaderLength + 8)).withUnsafeBytes { $0.load(as: UDPHeader.self) }
            sourcePort = Int(CFSwapInt16BigToHost(udpHeader.sourcePort))
            destinationPort = Int(CFSwapInt16BigToHost(udpHeader.destinationPort))
        }
        // ICMP (protocol 1) and other protocols will have nil for ports
        
        return (sourceIPString, destinationIPString, protocolType, sourcePort, destinationPort)
    }

    private func ipv4AddressToString(_ address: UInt32) -> String {
        // address is in network byte order (big endian), convert to host byte order for manipulation if needed,
        // but for direct byte access, it's fine.
        // However, inet_ntoa expects network byte order.
        var networkOrderAddress = address // Already in network byte order from header
        var addr = in_addr(s_addr: networkOrderAddress)
        if let cString = inet_ntoa(&addr) {
            return String(cString: cString)
        }
        return "?.?.?.?" // Fallback
    }


    // Ensure XPC connection is set up when tunnel starts
    override func startTunnel(options: [String: NSObject]?, completionHandler: @escaping (Error?) -> Void) {
        os_log(.default, log: defaultLog, "PortmasterTunnelProvider: Starting tunnel...")

        // Setup XPC Connection
        setupXPCConnection()

        let tunnelNetworkSettings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "127.0.0.1")
        tunnelNetworkSettings.ipv4Settings = NEIPv4Settings(addresses: ["192.168.200.1"], subnetMasks: ["255.255.255.0"])
        tunnelNetworkSettings.ipv4Settings?.includedRoutes = [NEIPv4Route.default()]

        setTunnelNetworkSettings(tunnelNetworkSettings) { error in
            if let error = error {
                os_log(.error, log: self.defaultLog, "PortmasterTunnelProvider: Failed to set tunnel network settings: %{public}@", error.localizedDescription)
                completionHandler(error)
                return
            }
            os_log(.default, log: self.defaultLog, "PortmasterTunnelProvider: Tunnel network settings applied.")
            self.readPackets()

            // Remove CGo call for now
            // let message = "Tunnel started successfully"
            // if let cMessage = message.cString(using: .utf8) {
            //     send_data_to_go(cMessage)
            //     os_log(.default, log: self.defaultLog, "PortmasterTunnelProvider: Sent message to Go: %{public}@", message)
            // } else {
            //     os_log(.error, log: self.defaultLog, "PortmasterTunnelProvider: Failed to create C string for message to Go.")
            // }

            completionHandler(nil)
        }
    }
}
