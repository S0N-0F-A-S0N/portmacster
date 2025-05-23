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

// Implement the method from the PortmasterXPCServicable protocol
- (void)processNewFlowWithBundleID:(NSString *)bundleID
                          sourceIP:(NSString *)sourceIP
                     destinationIP:(NSString *)destinationIP
                 completionHandler:(void (^)(BOOL))completionHandler {
    
    os_log_info(xpcServiceLog(), "XPC Service: Received processNewFlow. BundleID: \"%{public}@\", SourceIP: %{public}@, DestinationIP: %{public}@",
                bundleID ?: @"N/A",
                sourceIP ?: @"N/A",
                destinationIP ?: @"N/A");

    // 1. Serialize the flow data to JSON
    NSDictionary *flowDataDict = @{
        @"bundleID": bundleID ?: @"", // Ensure non-nil for JSON serialization
        @"sourceIP": sourceIP ?: @"",
        @"destinationIP": destinationIP ?: @""
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
    // char buffer[1];
    // read(sockfd, buffer, sizeof(buffer)); // Example: simple ack

    close(sockfd);
    completionHandler(YES); // Signal success to the XPC client
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

@end
