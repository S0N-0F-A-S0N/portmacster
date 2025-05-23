#import "PortmasterXPCService.h"
#import <os/log.h>

// Define a logger for the XPC service
static os_log_t xpcServiceLog() {
    static dispatch_once_t onceToken;
    static os_log_t log;
    dispatch_once(&onceToken, ^{
        log = os_log_create("com.safing.portmaster.xpcservice", "XPCHandler");
    });
    return log;
}

@implementation PortmasterXPCService

#import <libproc.h> // For proc_pidpath
#import <Security/Security.h> // For SecCodeCopySigningInformation
#import <bsm/libbsm.h> // For audit_token_to_pid (may require adding libbsm to linker flags in Xcode)

// Implement the method from the PortmasterXPCServicable protocol
- (void)processNewFlowWithBundleID:(NSString *)bundleID
                          sourceIP:(NSString *)sourceIP
                     destinationIP:(NSString *)destinationIP
                        sourcePort:(NSInteger)sourcePort
                 destinationPort:(NSInteger)destinationPort
                        protocol:(NSInteger)protocol
                      auditToken:(NSData *)auditTokenData
                 completionHandler:(void (^)(BOOL))completionHandler {
    
    pid_t pid = -1;
    NSString *executablePath = @"N/A"; // Default to N/A
    NSString *finalBundleID = bundleID ?: @"N/A"; // Use provided bundleID as fallback or primary

    if (auditTokenData && [auditTokenData length] == sizeof(audit_token_t)) {
        audit_token_t token;
        [auditTokenData getBytes:&token length:sizeof(audit_token_t)];
        pid = audit_token_to_pid(token); // Extract PID from audit_token_t
        
        os_log_info(xpcServiceLog(), "XPC Service: PID derived from audit_token: %d", pid);

        if (pid > 0) {
            char pathBuffer[PROC_PIDPATHINFO_MAXSIZE];
            int ret = proc_pidpath(pid, pathBuffer, sizeof(pathBuffer));
            if (ret > 0) {
                executablePath = [NSString stringWithUTF8String:pathBuffer];
                os_log_info(xpcServiceLog(), "XPC Service: Executable path for PID %d: \"%{public}@\"", pid, executablePath);
                
                // Attempt to get BundleID from the path if the provided one was N/A
                if ([finalBundleID isEqualToString:@"N/A"] || [finalBundleID length] == 0) {
                    NSBundle *bundle = [NSBundle bundleWithPath:executablePath];
                    if (bundle && bundle.bundleIdentifier) {
                        finalBundleID = bundle.bundleIdentifier;
                        os_log_info(xpcServiceLog(), "XPC Service: BundleID derived from path for PID %d: \"%{public}@\"", pid, finalBundleID);
                    } else {
                        // If it's a path to a non-bundle executable, bundleID might remain N/A or path itself
                        os_log_info(xpcServiceLog(), "XPC Service: Could not derive BundleID from path for PID %d.", pid);
                    }
                }
            } else {
                os_log_error(xpcServiceLog(), "XPC Service: proc_pidpath failed for PID %d: %s. Path will be 'Path Lookup Failed'.", pid, strerror(errno));
                executablePath = @"Path Lookup Failed";
            }
        } else {
             os_log_error(xpcServiceLog(), "XPC Service: Failed to get valid PID from audit_token (pid was %d).", pid);
        }
    } else {
        os_log_warning(xpcServiceLog(), "XPC Service: Audit token not provided or invalid length (length: %lu). PID and path lookup via token skipped.", (unsigned long)[auditTokenData length]);
        // Here, pid remains -1 and executablePath "N/A"
        // We rely on the originally passed bundleID.
    }
    
    os_log_info(xpcServiceLog(), "XPC Service: Processed Flow. Final BundleID: \"%{public}@\", SourceIP: %{public}@, DestinationIP: %{public}@, SourcePort: %ld, DestinationPort: %ld, Protocol: %ld, PID: %d, Path: \"%{public}@\"",
                finalBundleID, // Use the potentially updated bundleID
                sourceIP ?: @"N/A",
                destinationIP ?: @"N/A",
                (long)sourcePort,
                (long)destinationPort,
                (long)protocol,
                pid,
                executablePath);

    // 1. Serialize the flow data to JSON
    NSDictionary *flowDataDict = @{
        @"bundleID": finalBundleID, // Use the final bundleID
        @"sourceIP": sourceIP ?: @"",
        @"destinationIP": destinationIP ?: @"",
        @"sourcePort": @(sourcePort),
        @"destinationPort": @(destinationPort),
        @"protocol": @(protocol),
        @"pid": @(pid), 
        @"executablePath": executablePath
        // Code signature details deferred
    };

    NSError *jsonError;
    NSData *jsonData = [NSJSONSerialization dataWithJSONObject:flowDataDict options:0 error:&jsonError];

    if (!jsonData) {
        os_log_error(xpcServiceLog(), "XPC Service: Failed to serialize flow data to JSON: %{public}@", jsonError.localizedDescription);
        completionHandler(NO);
        return;
    }

    // 2. Define the Unix Domain Socket path
    // IMPORTANT: In a production app, this path should be more robust,
    // potentially within an App Group container.
    // TODO: Use a configurable or App Group based socket path.
    NSString *socketPath = @"/tmp/portmaster_ipc.sock";

    // 3. Connect and send data via Unix Domain Socket
    // For simplicity, using a basic POSIX socket API.
    // Production code might use higher-level libraries or GCD for async IO.
    
    int sockfd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (sockfd < 0) {
        os_log_error(xpcServiceLog(), "XPC Service: Failed to create socket: %{public}s", strerror(errno));
        completionHandler(NO);
        return;
    }

    struct sockaddr_un server_addr;
    memset(&server_addr, 0, sizeof(server_addr));
    server_addr.sun_family = AF_UNIX;
    strncpy(server_addr.sun_path, [socketPath UTF8String], sizeof(server_addr.sun_path) - 1);

    if (connect(sockfd, (struct sockaddr *)&server_addr, sizeof(server_addr)) < 0) {
        os_log_error(xpcServiceLog(), "XPC Service: Failed to connect to socket %{public}@: %{public}s", socketPath, strerror(errno));
        close(sockfd);
        completionHandler(NO);
        return;
    }

    // Send data - for simplicity, sending raw JSON data.
    // A real implementation might add framing (e.g., length prefix) or use a streaming JSON parser on the Go side.
    // Adding a newline delimiter for now, assuming the Go server will read line by line.
    NSMutableData *sendableData = [NSMutableData dataWithData:jsonData];
    [sendableData appendData:[@"\n" dataUsingEncoding:NSUTF8StringEncoding]];


    ssize_t bytes_written = write(sockfd, [sendableData bytes], [sendableData length]);
    if (bytes_written < 0) {
        os_log_error(xpcServiceLog(), "XPC Service: Failed to write to socket: %{public}s", strerror(errno));
        close(sockfd);
        completionHandler(NO);
        return;
    } else if (bytes_written < [sendableData length]) {
        os_log_warning(xpcServiceLog(), "XPC Service: Partially wrote data to socket. Expected %lu, wrote %zd", (unsigned long)[sendableData length], bytes_written);
        // Handle partial write if necessary, for now, consider it a failure for simplicity
        close(sockfd);
        completionHandler(NO);
        return;
    }
    
    os_log_info(xpcServiceLog(), "XPC Service: Successfully sent %zd bytes to Go IPC server.", bytes_written);

    // Optionally, wait for an acknowledgment from the Go server.
    // For this task, we'll assume fire-and-forget for simplicity.
    // TODO: Implement a mechanism for the Go service to send an ACK/NACK or a response if needed.
    // char buffer[3]; // For "ACK"
    // ssize_t bytes_read = read(sockfd, buffer, sizeof(buffer) -1 );
    // if (bytes_read > 0) {
    //    buffer[bytes_read] = '\0';
    //    os_log_info(xpcServiceLog(), "XPC Service: Received ACK: %s", buffer);
    // } else {
    //    os_log_error(xpcServiceLog(), "XPC Service: Failed to read ACK or connection closed by server.");
    // }


    close(sockfd);
    completionHandler(YES); // Signal success to the XPC client
    // TODO: The completionHandler's success should ideally reflect actual success/failure from the Go side if an ACK/NACK is implemented.
}

// Example of how another method would be implemented:
/*
- (void)processPacketData:(NSData *)packetData
                 metadata:(NSDictionary<NSString *, id> *)metadata
        completionHandler:(void (^)(BOOL))completionHandler {
    
    os_log_info(xpcServiceLog(), "XPC Service: Received processPacketData. Size: %lu bytes", (unsigned long)packetData.length);
    // Process packet data...
    completionHandler(YES);
}
*/

// Required for socket includes like AF_UNIX, SOCK_STREAM, etc.
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h> // For close() and write()
#include <sys/sysctl.h> // For audit_token_to_pid, though bsm/libbsm.h is more direct

@end
