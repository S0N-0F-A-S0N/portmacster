#ifndef MACOS_BRIDGE_H
#define MACOS_BRIDGE_H

// Include necessary headers for C types if needed by Swift, e.g., <stddef.h> for size_t.
// For const char*, no special includes are typically needed for basic interop.

#ifdef __cplusplus
extern "C" {
#endif

/**
 * @brief Sends a UTF-8 encoded string message from Swift to Go.
 *
 * This function is implemented in Go using CGo and is callable from Swift.
 * It's intended for simple, infrequent messages like status updates or commands.
 * For high-volume data (like packets), a more efficient mechanism will be needed.
 *
 * @param message A null-terminated C string (UTF-8 encoded).
 */
void send_data_to_go(const char* message);

#ifdef __cplusplus
}
#endif

#endif /* MACOS_BRIDGE_H */
