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

                let sourceIP = sourceIPRaw.map { String($0) }.joined(separator: ".")
                let destIP = destIPRaw.map { String($0) }.joined(separator: ".")
                
                let metadata = self.packetFlow.metadata(for: packetData)
                let bundleID = metadata?.sourceAppUniqueIdentifier ?? "N/A"
                
                os_log(.default, log: self.defaultLog, "PortmasterTunnelProvider: Intercepted IP packet. App: %{public}@, Src: %{public}@, Dst: %{public}@", bundleID, sourceIP, destIP)

                // Send flow information via XPC
                self.sendFlowToXPC(bundleID: bundleID, sourceIP: sourceIP, destinationIP: destIP)

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
