# macOS Network Extension for Portmaster

This directory contains the source code for the Portmaster Network Extension on macOS. This extension utilizes the NetworkExtension framework to intercept and manage network traffic.

## Files

- `PortmasterTunnelProvider.swift`: Implements the core logic of the `NEPacketTunnelProvider` system extension. This file handles the lifecycle of the packet tunnel, processes network packets, and includes basic logging for intercepted traffic and source application identification.
- `PortmasterTunnelProvider.entitlements`: Specifies the capabilities and permissions required by the network extension.
- `macos-bridge.h`: Serves as a bridging header for interoperability between Swift and Objective-C code, or for CGo integration if direct C/Go interaction is needed.

## Entitlements

The following entitlements are required for the `PortmasterTunnelProvider` system extension and its containing application:

- **`com.apple.developer.networking.networkextension`**: (Array of Strings)
    - Value: `packet-tunnel`
    - Purpose: Allows the extension to act as a packet tunnel provider.
- **`com.apple.developer.system-extension.install`**: (Boolean)
    - Value: `true`
    - Purpose: Allows the containing application to install the system extension. This is necessary when the extension is bundled with an app and installed via SystemExtensions framework.
- **`com.apple.security.app-sandbox`**: (Boolean, for the containing app)
    - Value: `true` (typically)
    - Purpose: The containing application is usually sandboxed. If it needs to communicate with the system extension or perform privileged operations (like installing the extension or advanced process info gathering), it may need specific sandbox exceptions or a privileged helper tool.
    - *Note for the extension itself:* System extensions run in their own sandboxes with restricted access. Their capabilities are primarily defined by their NetworkExtension type and the entitlements listed here.

The `PortmasterTunnelProvider.entitlements` file has been updated to include these.

## System Dependencies and Permissions

### Dependencies:
- **Xcode**: Version 12.0 or later (Recommended: Latest stable version).
- **macOS SDK**: Version 11.0 or later (corresponding to macOS Big Sur or newer, as NetworkExtension capabilities, especially for system extensions, have evolved).
- **Swift**: Version 5.3 or later.

### User Permissions for Installation and Operation:

When the Portmaster application first attempts to install and run the System Extension, the user will need to grant permissions. The typical flow is:

1.  **Installation Request**: The Portmaster application will trigger a request to install the system extension.
2.  **System Prompt**: macOS will display a prompt asking the user to allow the installation of the system extension by "Portmaster" (or the developer's name).
3.  **System Settings/Preferences**: The user will be directed to `System Settings` (on macOS Ventura and later) or `System Preferences` (on older macOS versions):
    *   Navigate to `Privacy & Security` > `Security` (section might vary slightly by macOS version).
    *   Under the "Security" or "General" tab, there will be a message stating that system software from developer "\[Developer Name]" was blocked from loading.
    *   The user must click "Allow" or "Enable system extension."
4.  **Network Configuration (Potentially)**: Depending on the implementation, the user might also see a prompt to allow Portmaster to add VPN configurations or filter network content. This is part of the `NEPacketTunnelProvider` setup.
5.  **Restart (Historically)**: In older versions of macOS, installing or updating a system extension sometimes required a system restart. This is less common now but can still occur.

The application should guide the user through this process, explaining why the permissions are needed.

## Process Attribution

The current implementation uses `packetFlow.metadata(for: packet)?.sourceAppUniqueIdentifier`.

-   **`sourceAppUniqueIdentifier`**:
    *   **Provides**: This property typically provides the bundle identifier (Bundle ID) of the application that originated the network traffic (e.g., `com.apple.Safari`, `com.google.Chrome`).
    *   **Format**: It's a string. For sandboxed apps, it's usually the Bundle ID. For non-sandboxed apps or command-line tools, it might be less straightforward or unavailable, potentially returning an empty string or the identifier of the process responsible for launching the tool (e.g., Terminal).
    *   **Limitations**:
        *   It does not directly provide the full executable path.
        *   It does not provide the Process ID (PID) directly through this property.
        *   It does not provide signing information (developer, team ID, etc.).
        *   For processes without a bundle ID (e.g., many command-line tools, unsigned binaries), this identifier might be missing or less useful.
        *   The accuracy can sometimes be affected by helper processes or XPC services making network requests on behalf of an app.

### Advanced Process Attribution (Future Enhancements)

To obtain more detailed process information, such as the full executable path and signing details, the approach used by applications like LuLu would be necessary. This typically involves:

1.  **Identifying the PID**: The NetworkExtension framework does not directly provide the PID for packets. A common way to bridge this gap is to correlate flow information (e.g., source/destination IP and port) with network socket information available system-wide.
    *   This correlation usually happens *outside* the Network Extension, often in a user-space daemon or helper tool due to sandbox restrictions within the extension.
2.  **User-Space Helper/Daemon**:
    *   A separate component (e.g., a privileged helper tool or a daemon running with sufficient permissions) would be needed.
    *   This component can iterate through active network connections (e.g., using `netstat` output parsing, or lower-level APIs like `libproc.h` functions if available and permissible for the helper's context).
    *   Once a PID is associated with a flow, the helper can use APIs like:
        *   **`proc_pidpath(pid, buffer, buffersize)`**: (from `libproc.h`) to get the full executable path for a given PID.
        *   **`SecCodeCopySigningInformation(_ code: SecStaticCode, _ flags: SecCSFlags, _ cfError: UnsafeMutablePointer<CFError?>)`**: To get code signing information (Team ID, Bundle ID from the signature, etc.) for an executable path or a `SecStaticCode` object created from a path. This is crucial for verifying application identity.
3.  **Communication & Correlation**:
    *   The enriched process information (PID, path, signing info) gathered by the user-space component needs to be correlated with the flow information (BundleID, IPs, Ports) reported by the Network Extension.
    *   This correlation can happen within the Go core. The `ipc_server_darwin.go` could receive the basic `FlowData` (including BundleID). A separate mechanism or an enhancement to the existing IPC could allow the user-space helper to feed the detailed process map (BundleID -> PID/Path/SignInfo) to the Go core.
    *   Alternatively, the Go core, upon receiving a `FlowData` with a `bundleID`, could query the user-space helper (via another IPC channel if necessary) for additional details about that specific `bundleID`.
4.  **Updating `network.Connection`**:
    *   Once detailed process information is available, the placeholder `process.Process` object associated with the `network.Connection` (currently created with `macOsBundleIdPid`) should be updated or replaced with a more complete one. This would allow existing firewall deciders that rely on path or signing information to function correctly.

#### Implementation Strategy Options:

*   **Option A: Main App as Information Gatherer:**
    *   The main Portmaster application (which is not as restricted as the Network Extension or a sandboxed XPC service) could perform system-wide process scanning and socket information gathering.
    *   **Pros:** Fewer new components; potentially easier to manage permissions if the main app already requires some elevated access for other features.
    *   **Cons:** The main app might not always be running or might be quit by the user. Process scanning can be resource-intensive. Getting PID from socket info system-wide often requires root-like privileges (e.g., accessing `/dev/kmem` or using privileged `sysctl` calls like `NETINFO_BSD_SOCKET_PCBINFO`, which are not generally available to sandboxed apps).

*   **Option B: Dedicated Privileged Helper Tool:**
    *   A small, dedicated privileged helper tool (installed via `SMJobBless`) could be responsible for gathering detailed process and socket information.
    *   This helper would expose an XPC interface to the main Portmaster Go application (or the Objective-C XPC service).
    *   **Pros:** Isolates privileged operations; can run continuously in the background. Standard macOS pattern for such tasks.
    *   **Cons:** More complex to develop, install, and manage (due to `SMJobBless` and inter-component XPC).

*   **Option C: Event-Driven Information Gathering (e.g., EndpointSecurity Framework):**
    *   The EndpointSecurity framework (ESF) could be used by a privileged component (main app or helper tool) to subscribe to process execution events (`ES_EVENT_TYPE_NOTIFY_EXEC`) and fork events. This provides PID, executable path, and parent PID directly when processes start.
    *   This information can be used to build the BundleID-to-ProcessInfo map proactively.
    *   For correlating with network flows, one would still need to associate PIDs with network activity, potentially by also monitoring network-related ESF events if they provide enough detail, or by combining with socket table lookups.
    *   **Pros:** More real-time information about process lifecycle; powerful capabilities.
    *   **Cons:** Requires a privileged component; ESF can be complex to use correctly and efficiently; might provide too much data if not filtered carefully.

#### Challenges:

*   **Permissions**: Accessing system-wide process lists, detailed information about arbitrary processes (especially paths and signing info for processes not owned by the user), and system-wide socket tables typically requires elevated permissions or entitlements not available to sandboxed apps or Network Extensions. This is the primary driver for needing a helper tool or a less-sandboxed main application component.
*   **Correlation Complexity**: Reliably correlating network flows (which might only have IP/port initially from the Network Extension) with specific PIDs and then to BundleIDs can be complex, especially with short-lived processes or processes that use helper tools for networking.
*   **Performance**: Frequent scanning of process or socket tables can be resource-intensive. An event-driven approach (like ESF) might be more efficient but has its own complexities.
*   **SwiftUI Previews / Non-Traditional Processes**: Handling processes that don't have a traditional BundleID (e.g., command-line tools, scripts, SwiftUI Previews in Xcode) will require careful heuristics. `sourceAppUniqueIdentifier` might provide some clues, but full path and parent process information becomes more critical.

**Recommended Path Forward (Phased):**

1.  **Phase 1 (Current + Protocol/Ports)**:
    *   Ensure protocol and port information are passed from the Network Extension (as per other TODOs).
    *   The Go core will use the `bundleID` with the special PID (`macOsBundleIdPid`) and the (now more complete) connection tuple (IPs, Proto, Ports).
    *   Profile rules can be written to target `bundleID`s directly if the profile system is adapted slightly (e.g., by treating the `Path` field in a process object as `bundleID` for these special PIDs).
2.  **Phase 2 (Helper-Assisted PID/Path/Signing Info):**
    *   Implement a privileged helper tool (Option B) or enhance the main app (Option A, if feasible with permissions) to gather PID, executable path, and signing information for running processes.
    *   This helper provides an XPC service that the Go core can query (e.g., "give me info for BundleID X" or "give me info for PID Y if a PID can be obtained via other means").
    *   The Go core then enriches the `network.Connection`'s `process.Process` object with this authoritative information, replacing or augmenting the placeholder data. This allows existing path-based and potentially signature-based rules to work.
3.  **Phase 3 (Explore Advanced Correlation/ESF):**
    *   Investigate using EndpointSecurity Framework or advanced socket sniffing techniques (if necessary and permissible) to directly link network activity to PIDs and processes, reducing reliance on BundleID correlation alone for initial PID discovery.

This phased approach allows for incremental improvements in process attribution accuracy and firewalling granularity.

## Current Implementation Details

The `PortmasterTunnelProvider.swift` file now contains:
- A class `PortmasterTunnelProvider` inheriting from `NEPacketTunnelProvider`.
- Implementation of `startTunnel`, `stopTunnel`, `handleAppMessage`, `sleep`, and `wake` methods with basic logging.
- In `startTunnel`, it sets up basic `NEPacketTunnelNetworkSettings` to route all IPv4 traffic through the tunnel for interception.
- A `readPackets` method is implemented to read IP packets from the `packetFlow`.
- For each packet, it attempts to get the `sourceAppUniqueIdentifier` and logs this information along with a hex representation of the packet data.
- Basic error handling and logging are included in the lifecycle methods.

The `PortmasterTunnelProvider.entitlements` file has been updated to include `packet-tunnel` and `com.apple.developer.system-extension.install` entitlements.

## Swift-Go Bridge

A basic communication bridge has been implemented to allow the Swift-based `PortmasterTunnelProvider` to send messages to the Go core. This is achieved using CGo, allowing Swift to call C functions that are implemented in Go.

### Mechanism: CGo Direct Call

1.  **C Header (`macos-bridge.h`):**
    *   A C function prototype, `void send_data_to_go(const char* message);`, is defined. This function is intended to be called by Swift.

2.  **Swift Side (`PortmasterTunnelProvider.swift`):**
    *   The Swift code calls the `send_data_to_go` C function directly.
    *   Example calls have been added in `startTunnel` (to send a "Tunnel started" message) and within the `readPackets` loop (to send information about intercepted packets).
    *   For this to work, `macos-bridge.h` must be made available to the Swift compiler, typically by importing it into the target's bridging header (e.g., `YourProject-Bridging-Header.h`).

3.  **Go Side (`native_bridge_darwin.go`):**
    *   This new Go file (compiled only for Darwin) uses CGo to implement the `send_data_to_go` function.
    *   The `//export send_data_to_go` directive makes the Go function available as a C function.
    *   The received C string is converted to a Go string, and currently, it's logged using the Portmaster logger (`log.Infof`).
    *   A placeholder `get_data_from_go` function and a `dummy` function (to ensure C.CString linkage) are also included for illustrative purposes.

### Files Involved:

-   `service/firewall/interception/macos/macos-bridge.h`: Defines the C interface for the bridge.
-   `service/firewall/interception/macos/PortmasterTunnelProvider.swift`: Calls the C bridge function from Swift.
-   `service/firewall/interception/macos/native_bridge_darwin.go`: Implements the C bridge function in Go using CGo.

### Build System Adjustments for the Bridge (`Earthfile`):

The `kext-build-macos` target in the `Earthfile` has been updated with conceptual steps to support the CGo bridge:
-   It now includes a stage (using `FROM +go-base AS go-bridge-builder`) to compile the Go code in `service/firewall/interception/macos/` specifically for the target macOS architecture (e.g., `darwin/amd64`, `darwin/arm64`).
-   The conceptual Go build command is `go build -buildmode=c-archive -o macos_bridge.a .`. This would produce a static library (`.a` file) and the C header.
-   Dummy files (`macos_bridge_${target}.a`) are currently created to represent this Go library output.
-   The `Earthfile` now saves these dummy `.a` files as artifacts alongside the placeholder `.appex` bundle.
-   **Challenge**: The actual linking of this Go static library (`macos_bridge.a`) into the Swift System Extension (`.appex`) is a complex step that typically happens within the Xcode build system (`xcodebuild`). Orchestrating this perfectly via Earthly requires a pre-existing Xcode project configured to find and link this library and its header. The current `Earthfile` simulates the preparation of these artifacts.

### Challenges and Next Steps:

-   **Direct Linking Complexity**: Linking a Go CGo static library into a Swift System Extension, ensuring the Go runtime initializes correctly within the extension's sandboxed environment, and managing dependencies can be challenging. This method requires careful setup of the Xcode project that builds the `.appex`.
-   **Data Marshalling**: The current bridge only sends simple UTF-8 strings. For more complex data (like packet data or structured information), robust marshalling/unmarshalling mechanisms would be needed. This can be error-prone and performance-intensive if not handled carefully with CGo.
-   **Bidirectional Communication**: The current implementation focuses on Swift-to-Go. A robust bridge would also need efficient Go-to-Swift communication.
-   **Alternative IPC - XPC**: Given the complexities of direct linking and the sandboxed nature of System Extensions, a more robust and flexible long-term solution for communication between the Swift extension and the Go core would be to use XPC (Cross-Process Communication).
    *   The Network Extension could act as an XPC client.
    *   The Portmaster Go core (or a dedicated Go XPC service) would act as the XPC server.
    *   This approach decouples the extension from the Go core, simplifies build processes, and is the standard Apple-recommended way for extensions to communicate with their containing apps or related processes.
    *   XPC provides a well-defined structure for exchanging messages and data.
-   **High-Volume Data**: For frequent, high-volume data like individual network packets, CGo calls or even XPC messages for every packet would be too slow. A more efficient mechanism, such as shared memory (if permissible and carefully managed) or batching data, would be necessary for performance. The current `send_data_to_go` call in `readPackets` is illustrative and not suitable for production packet forwarding.

The next steps should involve:
1.  Thoroughly investigating and attempting the actual linking of the `macos_bridge.a` into an Xcode project for the System Extension.
2.  If direct linking proves too problematic or unstable, pivot to designing and implementing an XPC-based bridge.
3.  Developing strategies for efficient transfer of packet data and other high-volume information.

## XPC Communication

To facilitate robust communication between the Swift-based `PortmasterTunnelProvider` (System Extension) and a user-space helper process (which will eventually communicate with the Go core), an XPC-based approach has been designed. This replaces the direct CGo bridge for primary communication, offering better stability, decoupling, and adherence to Apple's recommended practices for inter-process communication with System Extensions.

### 1. XPC Service Interface (`PortmasterXPCServicable.swift`)

A Swift protocol defines the interface for the XPC service:

-   **File**: `service/firewall/interception/macos/PortmasterXPCServicable.swift`
-   **Protocol**: `@objc public protocol PortmasterXPCServicable`
-   **Methods**:
    -   `processNewFlow(bundleID: String, sourceIP: String, destinationIP: String, completionHandler: @escaping (Bool) -> Void)`: Sends basic flow information (bundle ID, source/destination IPs) to the XPC service.
-   **Service Identifier**: `public let portmasterXPCServiceIdentifier = "com.safing.portmaster.xpcservice"`

This protocol outlines the contract between the XPC client (Swift extension) and the XPC server.

### 2. XPC Client (`PortmasterTunnelProvider.swift`)

The Swift System Extension acts as the XPC client:

-   **File**: `service/firewall/interception/macos/PortmasterTunnelProvider.swift`
-   **Connection Management**:
    -   An `NSXPCConnection` instance (`xpcConnection`) is established to the service named `portmasterXPCServiceIdentifier`.
    -   The connection is configured with the `PortmasterXPCServicable` interface.
    -   Invalidation and interruption handlers are set up to log errors and clear the connection.
    -   `setupXPCConnection()` method handles creating and resuming the connection. It's called during `startTunnel` and `wake`.
-   **Data Sending**:
    -   The `sendFlowToXPC(bundleID:sourceIPS:destinationIP:)` method is used to send flow data.
    -   It retrieves the remote object proxy from the XPC connection and calls the `processNewFlow` method.
    -   Error handling for the proxy call is included.
-   **Integration**:
    -   In `readPackets()`, when a packet is processed, its metadata (bundle ID, source/destination IPs - currently simplified parsing) is extracted and sent via `sendFlowToXPC`.
    -   Previous CGo calls (`send_data_to_go`) have been commented out in favor of XPC.

### 3. XPC Server (Objective-C Bridge to Go)

Due to the complexity and potential lack of mature, readily available libraries for hosting a direct Go XPC service that can be seamlessly managed by `launchd` as an app-bundled XPC service, the strategy is to use an Objective-C XPC service as an intermediary. This Objective-C service will handle XPC communication from the Swift extension and will be responsible for forwarding the data to the main Portmaster Go process (likely via a Unix domain socket or other local IPC, to be implemented in a future task).

-   **Directory**: `macos-xpc-service/` (contains the Objective-C XPC service code)
-   **Files**:
    -   `PortmasterXPCService.h`: Defines the Objective-C class `PortmasterXPCService` that conforms to the `PortmasterXPCServicable` protocol (Swift protocol exposed to Objective-C).
    -   `PortmasterXPCService.m`: Implements the `PortmasterXPCService` class.
        -   The `processNewFlowWithBundleID:sourceIP:destinationIP:completionHandler:` method currently logs the received flow information.
        -   **TODO**: This implementation will need to be extended to communicate with the Go core.
    -   `main.m`: Contains the main entry point for the XPC service. It sets up an `NSXPCListener` and a delegate to accept and configure new connections.
    -   `Info.plist`: Configures the XPC service, including its identifier (`com.safing.portmaster.xpcservice`) and service type (`Application`).

This Objective-C XPC service acts as a stable bridge, leveraging standard macOS mechanisms.

### 4. Build System Adjustments (`Earthfile`)

-   **XPC Service Target (`xpc-service-macos`)**:
    -   A new target `xpc-service-macos` has been added to the `Earthfile`.
    -   This target currently copies the Objective-C XPC service source files (`macos-xpc-service/`) into a conceptual `.xpc` bundle structure (`${outputDir}/macos_all/PortmasterXPC.xpc`).
    -   It does not compile the Objective-C code; this would be handled by an Xcode build process that builds the main application containing the System Extension and the XPC service. Earthly prepares/stages the source files.
-   **Main Build Integration**:
    -   The main `build` target in `Earthfile` has been updated to include a call to `+xpc-service-macos` to ensure these XPC service files are "packaged".

### 5. Data Structures

-   The primary data currently passed is flow information: `bundleID` (String), `sourceIP` (String), `destinationIP` (String).
-   These are passed as simple arguments to the XPC method.
-   The `PortmasterXPCServicable.swift` file includes commented-out examples of how more complex data (e.g., `FlowDetails` struct) could be defined using Codable structs if needed in the future.

### 6. XPC to Go IPC Bridge

To get data from the Objective-C XPC Service (which receives data from the Swift Network Extension) to the main Portmaster Go core, an Inter-Process Communication (IPC) bridge using Unix Domain Sockets has been implemented.

-   **IPC Mechanism**: Unix Domain Socket.
-   **Socket Path**: `/tmp/portmaster_ipc.sock`.
    -   *Note*: This path is used for simplicity. In a production environment, it should be a more secure, app-specific path, possibly within an App Group container.
-   **Data Serialization**: JSON. Flow data is serialized into a JSON object.
    ```json
    {
      "bundleID": "com.example.app",
      "sourceIP": "192.168.1.10",
      "destinationIP": "8.8.8.8"
    }
    ```

#### Objective-C XPC Service (`PortmasterXPCService.m` - Client Side of IPC)

-   **File**: `macos-xpc-service/PortmasterXPCService.m`
-   **Modifications**:
    -   When `processNewFlowWithBundleID...` is called, the received flow data (bundleID, sourceIP, destinationIP) is serialized into a JSON object.
    -   The service attempts to connect to the Unix Domain Socket at `/tmp/portmaster_ipc.sock`.
    -   The serialized JSON data (UTF-8 encoded, newline-terminated) is sent over the socket to the Go IPC server.
    -   Includes error handling for JSON serialization, socket creation, connection, and writing.
    -   Socket operations are basic POSIX calls (`socket`, `connect`, `write`, `close`).

#### Go IPC Server (`ipc_server_darwin.go` - Server Side of IPC)

-   **File**: `service/firewall/interception/macos/ipc_server_darwin.go`
-   **Functionality**:
    -   This new Go file (compiled only for macOS using `//go:build darwin`) implements the Unix Domain Socket server.
    -   `StartIPCServer()`:
        *   Removes any existing socket file at `/tmp/portmaster_ipc.sock`.
        *   Creates and listens on the Unix Domain Socket.
        *   Accepts incoming connections in a loop. Each connection is handled in a new goroutine.
        *   Designed to be called once using `sync.Once` when Portmaster starts on macOS.
    -   `StopIPCServer()`: Closes the stop channel, causing the listener goroutine to shut down and close the socket.
    -   `handleIPCConnection(conn net.Conn)`:
        *   Reads newline-terminated data from the connection.
        *   Deserializes the received JSON data into a `FlowData` struct.
        *   Logs the received `FlowData` using `log.Infof`.
        *   **TODO**: This is where further processing by the Portmaster core (e.g., sending to firewall logic) will be integrated.
-   **Integration**: The `StartIPCServer()` and `StopIPCServer()` functions are intended to be called from the main Portmaster application logic during startup and shutdown on macOS.

### Next Steps for XPC & IPC Communication:

1.  **Go Core Integration**: Integrate the `StartIPCServer()` call into the Portmaster startup sequence on macOS. Ensure `StopIPCServer()` is called on shutdown. The received `FlowData` in `handleIPCConnection` needs to be passed to the relevant Portmaster modules for actual processing.
2.  **Full Xcode Project Integration**: The System Extension and the Objective-C XPC service need to be correctly configured and built within an Xcode project. This includes:
    *   Ensuring the Swift System Extension target can connect to the XPC service.
    *   Ensuring the XPC service is correctly bundled within the main application and can create the Unix Domain Socket with appropriate permissions.
    *   Proper code signing and entitlements for the extension, XPC service, and main application (potentially including App Group entitlements for a shared socket path).
3.  **Refine Data Structures & IPC**: As more complex data needs to be exchanged, the XPC protocol, JSON structures, and IPC handling (e.g., more robust framing than newline, error reporting from Go to XPC service) will need to be updated.
4.  **Error Handling and Resilience**: Enhance error handling and connection management for both the XPC link and the Unix Domain Socket IPC. Consider scenarios like the Go IPC server not being available.
5.  **Security**: Review and secure the Unix Domain Socket path and permissions.

## Firewall Logic Integration

This section describes how the flow data received from macOS (via XPC and then Unix Domain Socket) is integrated into the Portmaster's core Go firewall logic.

### Data Flow Summary:

1.  **Swift Network Extension (`PortmasterTunnelProvider.swift`)**: Captures network flow metadata (BundleID, IPs).
2.  **XPC**: Sends this data to the Objective-C XPC Service.
3.  **Objective-C XPC Service (`PortmasterXPCService.m`)**: Receives data via XPC, serializes it to JSON.
4.  **Unix Domain Socket**: Sends the JSON data to the Go IPC Server.
5.  **Go IPC Server (`ipc_server_darwin.go`)**: Receives JSON, deserializes it into `FlowData`.
6.  **Core Firewall Processing**: The `processMacOSFlowData` function in `ipc_server_darwin.go` bridges this `FlowData` to the main firewall logic.

### Core Integration in `processMacOSFlowData`:

The `processMacOSFlowData(flow FlowData)` function in `service/firewall/interception/macos/ipc_server_darwin.go` is responsible for this integration:

1.  **Parsing IPs**: Source and destination IPs from `FlowData` are parsed.
2.  **Placeholder Network Info**:
    *   Since `FlowData` currently lacks protocol (TCP/UDP) and port numbers, these are **assumed**:
        *   Protocol: `packet.TCP`
        *   Ports: `0` (placeholder)
    *   This is a significant simplification and will affect the accuracy of port/protocol-specific rules. This information should ideally be captured by the Network Extension.
3.  **Packet Info Creation**: A `packet.Info` struct is populated with the available IPs and assumed protocol/ports. Direction is assumed outbound.
4.  **Connection ID**: A `connID` is generated using `packet.CreateConnectionID`. Due to placeholder ports, this ID might be less specific.
5.  **Connection Object (`network.Connection`)**:
    *   `network.GetConnection(connID)` attempts to find an existing connection.
    *   If no connection exists:
        *   A new `network.Connection` is instantiated.
        *   **Process Handling**:
            *   A special PID (`macOsBundleIdPid = -10`) is used to denote processes identified by BundleID.
            *   `process.NewWithPID(macOsBundleIdPid, flow.BundleID, flow.BundleID)` creates a placeholder `process.Process` object.
            *   `proc.LoadProfile(ctx)` is called to associate a profile. The effectiveness of profile matching may be limited if rules heavily rely on PIDs or full executable paths not derivable from a BundleID alone.
            *   `network.GetProcessContext(ctx, proc)` populates `conn.ProcessContext`.
        *   The connection's `LocalIP`, `LocalPort`, and remote `Entity` are set up using the (partially placeholder) `packet.Info`.
        *   `conn.MarkDataComplete()` is called to enable processing (this bypasses some of the usual packet-driven state checks).
        *   `conn.SetFirewallHandler(firewall.GetDefaultFirewallHandler())` assigns the default handler.
        *   `network.TrackConnection(conn)` adds the new connection to global tracking.
6.  **Updating Connection State**:
    *   The connection's `LastSeen` time is updated.
    *   `conn.ProcessContext` is refreshed if it was initially incomplete.
    *   `conn.UpdateFeatures()` is called to apply feature flags (e.g., history, bandwidth monitoring) based on the profile.
7.  **Invoking Firewall Logic**:
    *   `firewall.FilterConnection(ctx, conn, nil, true, true)` is the key call.
        *   `ctx`: A new background context with a tracer.
        *   `conn`: The prepared `network.Connection` object.
        *   `nil` (for packet.Packet): Since we only have flow info, not a full packet, `nil` is passed. Core firewall deciders that inspect packet content will not be effective.
        *   `checkFilter=true`, `checkTunnel=true`: Standard flags to enable filtering and tunneling checks.
    *   This function internally calls `decideOnConnection` (in `service/firewall/master.go`), which runs the chain of decider functions against the connection and its profile.
8.  **Logging and Saving**:
    *   The resulting verdict (`conn.Verdict`) and reason (`conn.Reason.Msg`) are logged.
    *   `conn.Save()` is called to persist the connection state and its verdict.

### Involved Core Go Modules/Functions:

-   **`service/firewall/interception/macos/ipc_server_darwin.go`**: Specifically `processMacOSFlowData` function.
-   **`service/network/connection.go`**: Used for creating and managing `network.Connection` objects. Functions like `GetConnection`, `TrackConnection`, `Connection.MarkDataComplete`, `Connection.Save()`, `GetProcessContext`.
-   **`service/network/packet/packetinfo.go`**: For `packet.Info` and `packet.CreateConnectionID`.
-   **`service/process/process.go`**: For `process.Process` objects, `NewWithPID`, `LoadProfile`.
-   **`service/intel/entity.go`**: For `intel.Entity`.
-   **`service/firewall/master.go`**: `decideOnConnection` is the core decision engine (called by `FilterConnection`).
-   **`service/firewall/packet_handler.go`**: `FilterConnection` is the primary entry point called from `ipc_server_darwin.go`. `GetDefaultFirewallHandler` is used.
-   **`service/profile/`**: The profile system is used via `proc.LoadProfile()` and accessed by deciders.

### Adaptations and Limitations:

-   **Missing Protocol/Ports**: The assumption of TCP and placeholder ports (0) is the most significant current limitation. This means port-specific firewall rules will not function correctly for these macOS-originated flows. This data needs to be provided by the Network Extension.
-   **Process Identification**: Using `BundleID` with a special PID is a workaround. While it allows flows to be associated with an application identifier, firewall rules based on specific executable paths or traditional PIDs may not apply as expected. Deeper integration with the `process` and `profile` modules might be needed for more nuanced `BundleID`-based rules.
-   **Packet Content Inspection**: Deciders that rely on inspecting actual packet content (e.g., for DPI, specific protocol payloads beyond IP/port) will not be effective as no actual packet is passed to `FilterConnection`.

### Testing Considerations:

-   **Unit Tests for `processMacOSFlowData`**:
    *   Mock dependencies like `network.GetConnection`, `process.NewWithPID`, `firewall.FilterConnection`.
    *   Verify that `network.Connection` objects are constructed with expected (placeholder) values.
    *   Check if `firewall.FilterConnection` is called.
    *   Assert that connection state (e.g., `Verdict`, `LastSeen`) is updated and `Save()` is called.
-   **Integration Tests (Go IPC Level)**:
    *   Start the `ipc_server_darwin.go` listener.
    *   Send various JSON `FlowData` payloads over a Unix Domain Socket.
    *   Observe logs for connection creation and firewall verdicts.
    *   Inspect internal state (e.g., by calling `network.GetConnection`) to see if connections are created and their verdicts are set.
-   **Focus of Current Tests**: Verification of data flow from IPC to `firewall.FilterConnection` and basic decision logging, rather than the accuracy of complex rule matching due to current data limitations.

## Testing Strategy

A comprehensive testing strategy is crucial for ensuring the reliability and correctness of the macOS network interception module. This involves unit tests for individual components, integration tests for communication channels, and end-to-end tests for the entire flow.

### 1. Unit Tests:

*   **Swift Network Extension (`PortmasterTunnelProviderTests.swift`):**
    *   **Target**: `PortmasterTunnelProvider.swift`
    *   **Focus**:
        *   Test XPC connection setup (`setupXPCConnection`) and invalidation/interruption handlers.
        *   Mock `NSXPCConnection` and `PortmasterXPCServicable` protocol to verify that `sendFlowToXPC` correctly attempts to send data.
        *   Test parsing of `NEPacket` to extract source/destination IPs and bundle ID (once protocol/port parsing is added).
        *   Verify correct handling of `NEPacketTunnelProvider` lifecycle methods (`startTunnel`, `stopTunnel`, etc.) with mocked dependencies.
    *   **TODO**: Develop Swift unit tests for `PortmasterTunnelProvider`, including mocking XPC communication and `NEPacket` parsing.
*   **Objective-C XPC Service (`PortmasterXPCServiceTests.m`):**
    *   **Target**: `PortmasterXPCService.m` (within `macos-xpc-service/`)
    *   **Focus**:
        *   Test the `processNewFlowWithBundleID...` method, ensuring correct JSON serialization (including future protocol/port fields).
        *   Mock the Unix Domain Socket connection to verify data writing and error handling.
    *   **TODO**: Develop Objective-C unit tests for `PortmasterXPCService`, including mocking socket interactions and testing various data inputs.
*   **Go IPC Server & Core Logic (`ipc_server_darwin_test.go`):**
    *   **Target**: `ipc_server_darwin.go`
    *   **Focus**:
        *   Test `processMacOSFlowData` with various `FlowData` inputs (complete, missing fields, different IPs, future protocol/ports).
        *   Mock `network.GetConnection`, `process.NewWithPID`, `proc.LoadProfile`, and `firewall.FilterConnection` to isolate logic.
        *   Verify correct construction of `network.Connection` objects.
        *   Check that `conn.Save()` is invoked and that verdicts are logged appropriately.
        *   Test `StartIPCServer`/`StopIPCServer` lifecycle, including socket file management.
        *   Test `handleIPCConnection` for robust JSON deserialization and error handling.
    *   **TODO**: Develop comprehensive Go unit tests for `ipc_server_darwin.go`, ensuring all code paths in `processMacOSFlowData` are covered.

### 2. Integration Tests (macOS Environment):

*   **System Extension <-> XPC Service Communication:**
    *   **Setup**: Requires building and running the Swift Network Extension and the Objective-C XPC service, likely within a test host app.
    *   **Focus**:
        *   Verify XPC connection establishment and resilience.
        *   Test sending various `FlowData` structures (including future protocol/ports) from the Network Extension to the XPC service.
        *   Confirm data integrity and correct reception by the XPC service.
    *   **TODO**: Design and implement integration tests for the Extension-XPC link.
*   **XPC Service <-> Go IPC Server Communication:**
    *   **Setup**: Run the Go IPC server. Build and run the Objective-C XPC service.
    *   **Focus**:
        *   Trigger XPC methods on the Objective-C service.
        *   Verify Unix Domain Socket connection and data transmission (including future protocol/ports).
        *   Confirm correct deserialization and processing by the Go server.
        *   Test error handling (e.g., Go IPC server unavailable).
    *   **TODO**: Design and implement integration tests for the XPC-Go IPC link.

### 3. End-to-End Tests (macOS Environment):

*   **Setup**:
    *   A fully built Portmaster application for macOS, with the System Extension, XPC Service, and Go core (IPC server running) correctly bundled and installed.
    *   Automated installation and enabling of the System Extension.
*   **Focus**:
    *   **Scenario 1: Application Blocking (by BundleID, and later by full attributes):**
        1.  Configure Portmaster rules to block a test application.
        2.  Automate the test application to make network connections.
        3.  Verify the flow is intercepted, data is passed through all components, the rule is applied, and the connection is blocked.
    *   **Scenario 2: Allow Rule Verification.**
    *   **Scenario 3: Data Integrity and Correctness:** Ensure information logged by Go core matches actual network activity.
    *   **Scenario 4: Protocol/Port Specific Rules:** Once protocol/port data is available, test rules based on this information.
    *   **TODO**: Develop a robust E2E test suite, including test applications and automation for UI interaction if needed for enabling the extension.

### General Considerations for Testing:

*   **Mocking and Dependency Injection**: Essential for unit tests.
*   **Logging**: Critical for debugging across all components.
*   **Automation**: Automate all test layers for CI/CD. This includes the complex E2E setup.
*   **Performance Testing**:
    *   Measure IPC overhead (XPC, Unix Domain Socket).
    *   Assess resource usage of the System Extension and helper processes under load.
    *   **TODO**: Plan and execute performance tests.
*   **Security Testing**:
    *   Review permissions of XPC service and Unix Domain Socket.
    *   Test for IPC vulnerabilities (e.g., unauthorized connections, data injection).
    *   Assess System Extension sandboxing effectiveness.
    *   **TODO**: Conduct security-focused testing and code review.

## Build System

Initial stubs for building the macOS Network Extension have been added to the project's `Earthfile`. The following targets were added:

- `kext-build-macos`: This target is responsible for building the `PortmasterTunnelProvider.appex` for a specified target architecture (e.g., `x86_64-apple-darwin`, `aarch64-apple-darwin`). It currently contains placeholder commands and needs to be implemented with the actual build steps for the Swift-based network extension.
- The main `build` target has been updated to include calls to `kext-build-macos` for both `x86_64-apple-darwin` and `aarch64-apple-darwin` architectures.
- Go build targets (`go-build`, `go-ci`) have been updated to include macOS targets (`darwin/amd64` and `darwin/arm64`).

The `RUST_TO_GO_ARCH_STRING` helper function in the `Earthfile` was already capable of handling Darwin targets, so no changes were needed there.

**Next Steps for Build System Integration:**

- Implement the actual build commands within the `kext-build-macos` target in the `Earthfile`. This will involve:
    - Setting up the correct build environment for Swift and Xcode.
    - Compiling the Swift code in `PortmasterTunnelProvider.swift`.
    - Packaging the compiled extension along with its entitlements (`PortmasterTunnelProvider.entitlements`) into an `.appex` bundle.
    - Ensuring the resulting `.appex` is placed in the correct output directory (e.g., `dist/darwin_amd64/` or `dist/darwin_arm64/`).
- Verify that the CGo integration (using `macos-bridge.h`) works correctly within the Earthly build environment if direct Go interaction is required for the extension.
