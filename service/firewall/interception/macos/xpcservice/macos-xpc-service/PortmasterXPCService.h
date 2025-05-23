#import <Foundation/Foundation.h>
#import "service/firewall/interception/macos/PortmasterXPCServicable.swift" // Assuming this path is accessible or types are redefined

// Redefine the protocol here if direct import of Swift-generated header is problematic in this environment.
// For a real Xcode project, you'd import the auto-generated -Swift.h header.
// For example: #import <YourApp/YourApp-Swift.h>
// Or ensure PortmasterXPCServicable.swift is part of the XPC service target
// and rely on the bridging header if the XPC service was Swift, or direct ObjC protocol def if ObjC.

// Let's assume for now that PortmasterXPCServicable.swift is compiled
// and its protocol is available. If not, we'd redefine a compatible ObjC protocol.

// This class implements the XPC service protocol.
@interface PortmasterXPCService : NSObject <PortmasterXPCServicable>
@end
