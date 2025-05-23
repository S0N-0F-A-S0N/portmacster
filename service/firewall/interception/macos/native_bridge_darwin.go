//go:build darwin

package macos

/*
#cgo CFLAGS: -I.
#include "macos-bridge.h"
*/
import "C"
import (
	"fmt"
	"unsafe"

	"github.com/safing/portmaster/base/log"
)

//export send_data_to_go
func send_data_to_go(message *C.char) {
	goMessage := C.GoString(message)
	// Using the project's logger for consistency if available and configured.
	// If not, fmt.Printf is a fallback.
	log.Infof("Message from Swift (via CGo): %s", goMessage)

	// TODO: Process this message or pass it to the Portmaster core.
	// This could involve:
	// - Sending it to a channel that a Go module is listening on.
	// - Calling a function in another Go package.
	// - Storing it in a shared data structure (ensure thread safety).
}

// Example of a function that could be called from Swift to get data from Go.
// This is not part of the current task but shows the other direction.
//
//export get_data_from_go
func get_data_from_go() *C.char {
	message := "Hello from Go!"
	// It's crucial to manage memory correctly when passing strings from Go to C.
	// The C string must be allocated in a way that C can manage it, or Go must ensure it remains valid.
	// C.CString allocates memory that C can free.
	// The caller (Swift) would be responsible for freeing this C string.
	// For now, this is just a placeholder to illustrate the concept.
	// A robust implementation would need careful memory management.
	return C.CString(message)
}

// Dummy function to ensure C.CString is recognized by CGo if not used elsewhere yet.
// C.CString is part of the "C" pseudo-package and its availability depends on actual usage.
func dummy() {
	dummyStr := "dummy"
	cStr := C.CString(dummyStr)
	C.free(unsafe.Pointer(cStr))
}
