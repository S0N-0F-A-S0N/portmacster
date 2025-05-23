//go:build darwin

package macos

import (
	"bufio"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"os"
	"sync"

	"github.com/safing/portmaster/base/log"
)

const (
	// unixSocketPath is the path for the Unix Domain Socket.
	// IMPORTANT: In a production app, this path should be more robust,
	// potentially within an App Group container or a path derived from user data.
	unixSocketPath = "/tmp/portmaster_ipc.sock"
)

// FlowData represents the structure of the JSON data received from the XPC service.
type FlowData struct {
	BundleID      string `json:"bundleID"`
	SourceIP      string `json:"sourceIP"`
	DestinationIP string `json:"destinationIP"`
}

var (
	ipcServerOnce sync.Once
	stopListener  chan struct{} // Channel to signal listener to stop
)

// StartIPCServer initializes and starts the Unix Domain Socket server to listen for
// connections from the Objective-C XPC service.
// It should be called when Portmaster starts up on macOS.
func StartIPCServer() {
	ipcServerOnce.Do(func() {
		log.Infof("Starting macOS IPC Server on socket: %s", unixSocketPath)
		stopListener = make(chan struct{})

		// Ensure the socket file does not already exist or remove it.
		if err := os.Remove(unixSocketPath); err != nil && !os.IsNotExist(err) {
			log.Errorf("Failed to remove existing socket file %s: %v", unixSocketPath, err)
			// Depending on the error, we might not want to proceed.
			// For example, if it's a permissions issue.
			return
		}

		listener, err := net.Listen("unix", unixSocketPath)
		if err != nil {
			log.Errorf("Failed to listen on Unix socket %s: %v", unixSocketPath, err)
			return
		}

		// Set permissions for the socket file (e.g., only accessible by the user).
		// This is important for security. os.Chmod is not effective on all systems for sockets.
		// The default umask of the process will determine permissions.
		// For more control, use App Groups if applicable.

		log.Infof("IPC Server listening on %s", unixSocketPath)

		go func() {
			defer listener.Close()
			for {
				select {
				case <-stopListener:
					log.Infof("IPC Server: Stopping listener on %s", unixSocketPath)
					return
				default:
					// Accept new connections
					conn, err := listener.Accept()
					if err != nil {
						// Check if the listener was closed, possibly by StopIPCServer()
						select {
						case <-stopListener:
							return // Normal shutdown
						default:
							log.Errorf("Failed to accept new connection on IPC server: %v", err)
							// If Accept fails, it might be a temporary issue or a fatal one.
							// Consider adding a delay before trying to accept again or exiting if it's persistent.
							continue // Continue to try accepting new connections
						}
					}
					log.Infof("IPC Server: Accepted new connection.")
					go handleIPCConnection(conn)
				}
			}
		}()
	})
}

// StopIPCServer signals the IPC server to stop listening and cleans up resources.
func StopIPCServer() {
	log.Infof("Attempting to stop macOS IPC Server...")
	if stopListener != nil {
		close(stopListener) // Signal the listener to stop
		// The listener will close the socket file when it exits.
		// We can also explicitly remove the socket file here if needed,
		// but it's better to let the listener goroutine handle its cleanup.
		// Forcing removal here might interfere with an active listener.
		// os.Remove(unixSocketPath)
	}
}

func handleIPCConnection(conn net.Conn) {
	defer conn.Close()
	log.Infof("IPC Server: Handling connection from %s", conn.RemoteAddr())

	reader := bufio.NewReader(conn)
	for {
		// Assuming messages are newline-terminated JSON strings
		line, err := reader.ReadBytes('\n')
		if err != nil {
			if err == io.EOF {
				log.Infof("IPC Server: Connection closed by client (EOF).")
			} else {
				log.Errorf("IPC Server: Error reading from connection: %v", err)
			}
			return // End of connection or error
		}

		var data FlowData
		if err := json.Unmarshal(line, &data); err != nil {
			log.Errorf("IPC Server: Failed to unmarshal JSON data: %v. Raw data: %s", err, string(line))
			continue // Try to read next line
		}

		log.Infof("IPC Server: Received Flow Data: BundleID='%s', SourceIP=%s, DestinationIP=%s",
			data.BundleID, data.SourceIP, data.DestinationIP)

		// --- Begin Integration with Firewall Logic ---
		processMacOSFlowData(data)
		// --- End Integration with Firewall Logic ---

		// Optionally, send an acknowledgment back to the XPC service.
		// For now, the XPC service is fire-and-forget.
	}
}

// processMacOSFlowData takes the received FlowData and attempts to process it through the firewall.
func processMacOSFlowData(flow FlowData) {
	ctx, tracer := log.AddTracer(context.Background()) // Create a new context for this operation
	defer tracer.Submit()

	srcIP := net.ParseIP(flow.SourceIP)
	dstIP := net.ParseIP(flow.DestinationIP)

	if srcIP == nil || dstIP == nil {
		tracer.Errorf("IPC Server: Invalid IP address(es) received: Src='%s', Dst='%s'", flow.SourceIP, flow.DestinationIP)
		return
	}

	// --- Simplification: Assume TCP and placeholder ports ---
	// This is a major simplification because FlowData lacks protocol and port.
	const assumedProtocol = packet.TCP
	const placeholderPort = 0 // Using 0 as a generic placeholder.

	pktInfo := &packet.Info{
		Inbound:  false, // Assuming outbound, this might need to come from FlowData
		Version:  packet.IPv4,
		Protocol: assumedProtocol,
		Src:      srcIP,
		SrcPort:  placeholderPort,
		Dst:      dstIP,
		DstPort:  placeholderPort,
		SeenAt:   time.Now(),
		// PID will be handled by creating a special process.Process object
	}
	if srcIP.To4() == nil { // Basic check for IPv6
		pktInfo.Version = packet.IPv6
	}

	connID := packet.CreateConnectionID(pktInfo.Protocol, pktInfo.Src, pktInfo.SrcPort, pktInfo.Dst, pktInfo.DstPort, pktInfo.Inbound)

	conn, existing := network.GetConnection(connID)
	if !existing {
		tracer.Infof("IPC Server: Creating new connection object for ID %s (BundleID: %s)", connID, flow.BundleID)
		
		// Create a placeholder process.Process for BundleID-based identification.
		// macOsBundleIdPid is a convention for PIDs that are not actual PIDs but represent bundle IDs.
		const macOsBundleIdPid = -10 
		
		// Create a new process instance. This is a simplified approach.
		// Normally, process.GetProcessWithProfile is used, which involves caching and more complex logic.
		proc := process.NewWithPID(macOsBundleIdPid, flow.BundleID, flow.BundleID)
		// Attempt to load a profile. This is crucial. Without a profile, decisions might default to block.
		// The profile loading logic might need to be adapted for bundleID-based "processes".
		// For now, this will likely result in a default or "unknown" profile state if not found by path/name.
		proc.LoadProfile(ctx) // Load profile for this new process

		conn = &network.Connection{
			ID:             connID,
			Type:           network.IPConnection,
			IPVersion:      pktInfo.Version,
			IPProtocol:     pktInfo.Protocol,
			Inbound:        pktInfo.Inbound,
			PID:            macOsBundleIdPid,
			Started:        time.Now().Unix(),
			ProcessContext: network.GetProcessContext(ctx, proc), // Populate ProcessContext
		}
		conn.SetProcess(proc) // Associate the process object with the connection
		conn.SetLocalIP(pktInfo.LocalIP()) // Set local IP and derive its scope
		conn.LocalPort = pktInfo.LocalPort()
		
		// Initialize the Entity for the remote connection
		conn.Entity = (&intel.Entity{
			IP:       pktInfo.RemoteIP(),
			Protocol: uint8(pktInfo.Protocol),
			Port:     pktInfo.RemotePort(),
		}).Init(pktInfo.DstPort) // DstPort is used for entity initialization context

		// Mark data as complete to allow firewall processing. This is a shortcut.
		if err := conn.MarkDataComplete(); err != nil {
			tracer.Errorf("IPC Server: Error marking connection data complete: %v for %s", err, conn.ID)
			return
		}
		
		conn.SetFirewallHandler(firewall.GetDefaultFirewallHandler())
		network.TrackConnection(conn) // Add to global connection tracking
		tracer.Infof("IPC Server: New connection %s created and tracked for BundleID %s.", conn.ID, flow.BundleID)
	} else {
		tracer.Infof("IPC Server: Using existing connection object for ID %s (BundleID: %s)", connID, flow.BundleID)
	}

	conn.Lock()
	defer conn.Unlock()

	// Update last seen time
	conn.SetLastSeen(time.Now().Unix())

	// If the process context wasn't fully resolved (e.g. profile name missing)
	if conn.ProcessContext.ProfileName == "" && conn.Process() != nil {
		conn.ProcessContext = network.GetProcessContext(ctx, conn.Process())
		tracer.Infof("IPC Server: Updated ProcessContext for %s: Profile '%s'", conn.ID, conn.ProcessContext.ProfileName)
	}
	
	// Ensure features (like history, bandwidth) are updated based on the profile/user.
	if err := conn.UpdateFeatures(); err != nil && !errors.Is(err, access.ErrNotLoggedIn) {
		tracer.Warningf("IPC Server: failed to update connection features for %s: %s", conn.ID, err)
	}


	// Call the core firewall decision logic.
	// We pass `nil` for the packet as we only have flow info.
	// Some deciders that rely on packet content might not work as expected.
	firewall.FilterConnection(ctx, conn, nil, true, true) // checkFilter=true, checkTunnel=true

	tracer.Infof("IPC Server: Firewall decision for flow %s (Src: %s, Dst: %s, App: %s) -> Verdict: %s, Reason: '%s'",
		conn.ID, flow.SourceIP, flow.DestinationIP, flow.BundleID, conn.Verdict.Verb(), conn.Reason.Msg)

	conn.Save() // Save connection state (verdict, timestamps, etc.)
}

// Ensure necessary imports. These might need adjustment based on actual package structure.
import (
	"context"
	"time"
	"errors" // For access.ErrNotLoggedIn comparison

	"github.com/safing/portmaster/service/firewall"
	"github.com/safing/portmaster/service/intel"
	"github.com/safing/portmaster/service/network"
	"github.com/safing/portmaster/service/network/packet"
	"github.com/safing/portmaster/service/process"
	"github.com/safing/portmaster/spn/access" // For access.ErrNotLoggedIn
	// "github.com/tevino/abool" // Not directly used now, but network.Connection uses it.
)

// Example usage (would be in main.go or similar, wrapped in //go:build darwin tags):
/*
func main() {
    // ... other Portmaster initialization ...

    // On macOS, start the IPC server
    // This needs to be conditional on the OS using build tags in the calling code.
    // if runtime.GOOS == "darwin" {
    //    macosinterception.StartIPCServer()
    // }

    // ... wait for shutdown signal ...
    // if runtime.GOOS == "darwin" {
    //    macosinterception.StopIPCServer()
    // }
}
*/
