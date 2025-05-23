#import <Foundation/Foundation.h>
#import "PortmasterXPCService.h"
#import <os/log.h>

// Define a logger for the XPC service main
static os_log_t xpcMainLog() {
    static dispatch_once_t onceToken;
    static os_log_t log;
    dispatch_once(&onceToken, ^{
        log = os_log_create("com.safing.portmaster.xpcservice", "XPCMain");
    });
    return log;
}

@interface ServiceDelegate : NSObject <NSXPCListenerDelegate>
@end

@implementation ServiceDelegate

// This method is called by the NSXPCListener when a new connection comes in.
// We should_acceptNewConnection returns true, a new NSXPCConnection is created
// and its remoteObjectInterface is set to the interface defined in the protocol.
- (BOOL)listener:(NSXPCListener *)listener shouldAcceptNewConnection:(NSXPCConnection *)newConnection {
    os_log_info(xpcMainLog(), "XPC Service: New connection received.");

    // Configure the new connection.
    // The exportedObject should be an instance of the class that implements the XPC protocol.
    newConnection.exportedInterface = [NSXPCInterface interfaceWithProtocol:@protocol(PortmasterXPCServicable)];
    
    PortmasterXPCService *exportedObject = [[PortmasterXPCService alloc] init];
    newConnection.exportedObject = exportedObject;
    
    // Resume the connection to start processing messages.
    [newConnection resume];
    
    os_log_info(xpcMainLog(), "XPC Service: Connection configured and resumed.");
    return YES;
}

@end

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        os_log_info(xpcMainLog(), "XPC Service: Starting...");

        // Create the listener for the XPC service.
        // The service name should match the one used by the client (System Extension).
        // This name is typically defined in the Info.plist of the XPC service bundle.
        NSXPCListener *listener = [NSXPCListener serviceListener];
        
        ServiceDelegate *delegate = [[ServiceDelegate alloc] init];
        listener.delegate = delegate;
        
        // Start listening for incoming connections.
        [listener resume];
        
        os_log_info(xpcMainLog(), "XPC Service: Listener resumed. Service is running.");

        // Keep the service alive by running the run loop.
        // XPC services are typically managed by launchd and are launched on demand.
        // The run loop keeps the main thread alive to service requests.
        [[NSRunLoop currentRunLoop] run];

        os_log_info(xpcMainLog(), "XPC Service: Run loop exited. Shutting down.");
    }
    return 0;
}
