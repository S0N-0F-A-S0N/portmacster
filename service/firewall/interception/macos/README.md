# Portmaster macOS Interception Module

This directory contains the source code and documentation for Portmaster's network interception capabilities on macOS. This module utilizes Apple's NetworkExtension framework (specifically `NEPacketTunnelProvider`) for traffic interception and an XPC Service for communication between the extension and the Portmaster Go core.

## Overview of Components

The macOS interception mechanism consists of several key components:

1.  **Swift Network Extension (`PortmasterTunnelProvider.swift`, `PortmasterTunnelProvider.entitlements`)**:
    *   A System Extension (`NEPacketTunnelProvider`) that runs in a sandboxed environment.
    *   Location: `service/firewall/interception/macos/`
    *   Source files for the extension.
    *   Intercepts network packets system-wide.
    *   Extracts basic flow information (BundleID of the source app, source/destination IPs, protocol type, source/destination ports, and the source application's `audit_token_t`).
    *   Acts as an XPC client to send this flow data (including the audit token as `Data`) to the Objective-C XPC Service.
    *   **Build Process**: The `Earthfile`'s `kext-build-macos` target orchestrates the staging of these files and executes the `build_extension.sh` script. This script currently simulates a build process.

2.  **XPC Service Interface (`PortmasterXPCServicable.swift`)**:
    *   Defines the Swift protocol for communication between the Network Extension and the XPC service.
    *   Location: `service/firewall/interception/macos/`
    *   The `processNewFlow` method in this protocol now includes parameters for `sourcePort`, `destinationPort`, `protocol`, and `auditToken` (as `Data`).

3.  **Objective-C XPC Service (`xpcservice/macos-xpc-service/`)**:
    *   Acts as an intermediary between the sandboxed Network Extension and the Portmaster Go core.
    *   Source Location: `service/firewall/interception/macos/xpcservice/macos-xpc-service/`
    *   Implements the updated `PortmasterXPCServicable` protocol, receiving the new port, protocol, and audit token information.
    *   Connects to a Unix Domain Socket provided by the Go core.
    *   Serializes received flow data to JSON and sends it over the Unix Domain Socket.
    *   **Build Process**: The `Earthfile`'s `xpc-service-macos` target orchestrates the staging of these files and executes the `build_xpc_service.sh` script. This script currently simulates a build process.

4.  **Go IPC Server (`ipc_server_darwin.go`)**:
    *   Part of the Portmaster Go application (compiled for macOS).
    *   Location: `service/firewall/interception/macos/`
    *   Listens on a Unix Domain Socket (default: `/tmp/portmaster_ipc.sock`).
    *   Receives JSON-formatted flow data from the Objective-C XPC Service.
    *   Deserializes the data and integrates it into the main Portmaster firewall logic (`firewall.FilterConnection`).

5.  **Core Go Firewall Logic Integration**:
    *   The `processMacOSFlowData` function in `ipc_server_darwin.go` adapts the received flow data to create a `network.Connection` object, which is then processed by the Portmaster firewall engine.

6.  **Placeholder Containing App (`macos-app-placeholder/`)**:
    *   A minimal directory structure (containing an `Info.plist`) that represents a macOS application.
    *   Location: `macos-app-placeholder/` (at the repository root).
    *   This is used by the `Earthfile` build targets (`kext-build-macos`, `xpc-service-macos`) to provide a conceptual context for building the System Extension and XPC Service, as these components are typically bundled within a main application. It is not a fully functional app and its `Info.plist` is primarily for satisfying structural expectations of build tools.

7.  **Build Scripts**:
    *   `service/firewall/interception/macos/build_extension.sh`: Placeholder script intended to house `xcodebuild` commands for compiling and packaging the Network Extension. Currently simulates a build.
    *   `service/firewall/interception/macos/xpcservice/build_xpc_service.sh`: Placeholder script intended to house `xcodebuild` commands for compiling and packaging the XPC Service. Currently simulates a build.

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
- **`com.apple.developer.networking.vpn.api`**: (Array of Strings, for the containing app)
    - Value: `app-proxy`, `packet-tunnel` (include `packet-tunnel` if the app directly manages the tunnel provider, `app-proxy` if it uses NEAppProxyProvider).
    - Purpose: Allows the application to control and manage Network Extension configurations.
- **App Group Entitlement (e.g., `group.com.safing.portmaster`)**:
    - Required for both the main application and the XPC service if they need to share data via an App Group container (e.g., for a more secure Unix Domain Socket path).
    - **TODO**: Define and use an App Group for shared resources like the IPC socket.
    - **TODO**: Ensure the main application's entitlements request `com.apple.developer.networking.vpn.api` and any necessary App Group entitlements.

The `PortmasterTunnelProvider.entitlements` file has been updated to include `com.apple.developer.networking.networkextension` and `com.apple.developer.system-extension.install`. Other entitlements are typically set in the main application's `.entitlements` file.

## Code Signing & Provisioning

- **Apple Developer ID**: All components (main application, System Extension, XPC Service) must be signed with an Apple Developer ID certificate.
- **Provisioning Profiles**:
    - For the System Extension: Requires a specific provisioning profile that enables the Network Extension capability.
    - For the main application: Requires a provisioning profile that allows System Extension installation and potentially App Group access.
- **Notarization**: For distribution outside the Mac App Store, the main application bundle (containing the extension and XPC service) must be notarized by Apple. This involves uploading the signed app to Apple's notarization service.

Failure to meet these signing and provisioning requirements will prevent the System Extension from being installed or run.

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
    -   Previous CGo calls (`send_data_to_go`) have been removed in favor of XPC.

### 3. XPC Server (Objective-C XPC Service)

The Objective-C XPC Service (source located in `service/firewall/interception/macos/xpcservice/macos-xpc-service/`) acts as a bridge:
- It implements the `PortmasterXPCServicable` protocol, which includes methods for passing flow information along with an `auditToken` (as `NSData`).
- It receives flow data from the Network Extension.
- **Process Attribution in XPC Service**:
    - It uses the received `auditToken` (if valid and of correct length) to derive the Process ID (PID) of the source application using the `audit_token_to_pid` function.
    - If a valid PID is obtained, it then calls `proc_pidpath` to retrieve the full executable path of the process.
    - If the originally passed `bundleID` was "N/A" or empty, it attempts to derive a BundleID from the `executablePath` using `[NSBundle bundleWithPath:executablePath].bundleIdentifier`.
    - The PID and `executablePath` (and potentially updated `bundleID`) are logged.
    - Code signature retrieval (e.g., Team ID using `SecCodeCopySigningInformation`) is a planned next step but is currently not fully implemented in this phase (code might be present but commented or placeholder).
- It serializes the augmented flow data (now including PID and executable path) to JSON and forwards it to the Go IPC server via a Unix Domain Socket.
    - **Note**: The Go IPC server (`ipc_server_darwin.go`) currently only deserializes the original flow fields (BundleID, IPs, ports, protocol). The handling of `pid` and `executablePath` in the Go layer is a TODO for the next phase.
- The build process for this service is initiated by the `build_xpc_service.sh` script (located in `service/firewall/interception/macos/xpcservice/`), which is called by the `Earthfile`.

### 4. Build System and Developer Workflow (`Earthfile`, `build_*.sh`, Xcode)

The build process for macOS components is managed by a combination of `Earthfile` and placeholder shell scripts, with the expectation that actual compilation and signing will occur within an Xcode environment.

-   **`Earthfile` Targets**:
    -   **`kext-build-macos`**: This target is responsible for the Network Extension. It copies the Swift source files (`PortmasterTunnelProvider.swift`, `PortmasterTunnelProvider.entitlements`, `PortmasterXPCServicable.swift`), the `build_extension.sh` script (from `service/firewall/interception/macos/`), and the `macos-app-placeholder/Info.plist` (as context for a containing app) into a staging directory. It then makes `build_extension.sh` executable and runs it.
    -   **`xpc-service-macos`**: This target handles the XPC Service. It copies the Objective-C source files (from `service/firewall/interception/macos/xpcservice/macos-xpc-service/`), the `build_xpc_service.sh` script (from `service/firewall/interception/macos/xpcservice/`), the `PortmasterXPCServicable.swift` protocol (for context), and the `macos-app-placeholder/Info.plist` into a staging directory. It then makes `build_xpc_service.sh` executable and runs it.
    -   The main `build` target in `Earthfile` calls these targets, integrating them into the broader project build.

-   **Placeholder Build Scripts (`build_extension.sh`, `build_xpc_service.sh`)**:
    -   These scripts currently *simulate* a successful build by creating token files (e.g., `PortmasterTunnelProvider.appex_built_SUCCESS`) and empty placeholder bundle files (`.appex` and `.xpc`).
    -   **For actual compilation and packaging, these scripts must be updated with the necessary `xcodebuild` commands.** Example `xcodebuild` invocations are commented within the scripts as a starting point.

-   **Developer Workflow**:
    -   **Automated Placeholder Build (Earthly)**: The current Earthly setup allows for an automated "build" (via the scripts) of these components as part of the larger project build. This is useful for CI and for ensuring the file staging process works. Earthly creates placeholder `.appex` and `.xpc` files.
    -   **Xcode for Development & Real Builds**: Developers working on the Swift Network Extension or Objective-C XPC Service will primarily use Xcode:
        1.  A dedicated Xcode project (not yet included in this repository) needs to be set up. This project would contain targets for:
            *   A main macOS application (which could be the Portmaster UI application or a minimal wrapper).
            *   The `PortmasterTunnelProvider` System Extension, using sources from `service/firewall/interception/macos/`.
            *   The `PortmasterXPCService` XPC Service, using sources from `service/firewall/interception/macos/xpcservice/macos-xpc-service/`.
        2.  The Xcode project must be configured for correct code signing (with an Apple Developer ID), provisioning profiles, and App Group entitlements.
        3.  The placeholder build scripts (`build_extension.sh`, `build_xpc_service.sh`) can serve as templates for the command-line invocations (`xcodebuild` commands) that would be used in a CI environment that has access to Xcode build tools and appropriate signing identities.

-   **Go IPC Server**: The `ipc_server_darwin.go` is compiled as part of the standard Go build for macOS (`darwin` target) via the `+go-build` target in the `Earthfile`.

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
      "bundleID": "com.example.app", // May be updated if derived from executablePath
      "sourceIP": "192.168.1.10",
      "destinationIP": "8.8.8.8",
      "sourcePort": 12345,
      "destinationPort": 80,
      "protocol": 6, // (IPPROTO_TCP)
      "pid": 123, // Derived from auditToken, -1 on error
      "executablePath": "/Applications/Safari.app/Contents/MacOS/Safari" // "N/A" or "Path Lookup Failed" on error
      // "codeSignatureDetails": "TeamID: ABCDE12345" // Future addition
    }
    ```
    *(The Go IPC server currently only deserializes the original fields and the newly added port/protocol fields; handling of `pid` and `executablePath` is pending in Go).*

#### Objective-C XPC Service (`service/firewall/interception/macos/xpcservice/macos-xpc-service/PortmasterXPCService.m` - Client Side of IPC)

-   **Modifications**:
    -   The `processNewFlowWithBundleID...` method now accepts `sourcePort`, `destinationPort`, `protocol`, and `auditToken` (as `NSData *`) as parameters.
    -   It uses the received `auditToken` to derive the Process ID (PID) using `audit_token_to_pid`.
    -   If a PID is successfully obtained:
        - It retrieves the full executable path using `proc_pidpath`.
        - If the initial `bundleID` was generic (e.g., "N/A"), it attempts to derive a more specific BundleID from the executable path.
    -   The PID and `executablePath` (along with the potentially updated `bundleID`) are included in the `NSDictionary` (`flowDataDict`) that is serialized to JSON. Code signature retrieval is deferred.
    -   Extensive logging is included to trace these operations.
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
        *   Deserializes the received JSON data into a `FlowData` struct. (Currently, this struct in Go only contains `bundleID`, `sourceIP`, `destinationIP`, `sourcePort`, `destinationPort`, `protocol`. It will need updating in the next phase to include PID, path, and signature details).
        *   Logs the received (partially deserialized) `FlowData` using `log.Infof`.
        *   **TODO (Next Phase)**: Update the Go `FlowData` struct in `ipc_server_darwin.go` to include `PID` (int), `ExecutablePath` (string), and `CodeSignatureDetails` (string). Modify `handleIPCConnection` to deserialize these new fields from the JSON. Adapt `processMacOSFlowData` to use this new information when creating or updating `process.Process` objects within the `network.Connection`.
-   **Integration**: The `StartIPCServer()` and `StopIPCServer()` functions are intended to be called from the main Portmaster application logic during startup and shutdown on macOS.

### Next Steps for XPC & IPC Communication:

1.  **Go IPC and Core Logic Update (Next Subtask)**:
    *   The primary focus of the next subtask will be to update the Go side:
        *   Modify the `FlowData` struct in `ipc_server_darwin.go` to include `PID` (int), `ExecutablePath` (string), and `CodeSignatureDetails` (string).
        *   Update `handleIPCConnection` in `ipc_server_darwin.go` to correctly deserialize these new fields from the JSON payload received from the XPC service.
        *   Enhance `processMacOSFlowData` in `ipc_server_darwin.go` to utilize the new `PID`, `ExecutablePath`, and `CodeSignatureDetails` when creating or updating `process.Process` objects. This will involve using the PID for more accurate process lookups and populating the path and signature details into the `process.Process` struct, allowing for more granular firewall rules.
2.  **Go Core Integration**: Integrate the `StartIPCServer()` call into the Portmaster startup sequence on macOS. Ensure `StopIPCServer()` is called on shutdown. The (now more complete) `FlowData` in `handleIPCConnection` needs to be passed to the relevant Portmaster modules for actual processing.
3.  **Full Xcode Project Integration**: The System Extension and the Objective-C XPC service need to be correctly configured and built within an Xcode project. This includes:
    *   Ensuring the Swift System Extension target can connect to the XPC service.
    *   Ensuring the XPC service is correctly bundled within the main application and can create the Unix Domain Socket with appropriate permissions.
    *   Proper code signing and entitlements for the extension, XPC service, and main application (potentially including App Group entitlements for a shared socket path - see Entitlements section).
4.  **Error Handling and Resilience**:
    *   **TODO**: Implement comprehensive error handling (e.g., XPC connection retry logic, handling IPC server unavailability, error propagation from Go back to XPC).
5.  **Security**:
    *   **TODO**: Change the Unix Domain Socket path from `/tmp/portmaster_ipc.sock` to a secure, app-specific path, ideally within an App Group container.
    *   **Future Enhancement**: Consider authentication mechanisms on the Unix Domain Socket.
6.  **Data Serialization Robustness**:
    *   **Future Enhancement**: Consider more robust data serialization (e.g., Protocol Buffers) and IPC framing (e.g., length-prefixing messages) if JSON/newline becomes a bottleneck or too error-prone.

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

The "Build System" section has been integrated into the "Build System and Developer Workflow" section above, providing a more cohesive explanation.
The CGo bridge components (`macos-bridge.h`, `native_bridge_darwin.go`) are obsolete and all references to them have been removed from this document.
