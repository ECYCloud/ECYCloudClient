#ifndef ECY_KERNEL_H
#define ECY_KERNEL_H
#include <stdint.h>
// Buffers belong to the caller; the core never retains them after a call.
// MTU 0 with empty addresses starts only the control plane, without a packet device.
uint64_t ECYStart(void *data, int size, const char *directory, int mtu, const char *ipv4, const char *ipv6, const char *dns);
// Result of the latest ECYStart: 0 = started, -4 = no usable nodes, other negative values = invalid configuration.
int ECYStartError(void);
void ECYStop(uint64_t session);
int ECYSubmit(uint64_t session, void *data, int size);
// Supply exactly 65535 bytes. Positive = packet length; 0 = timeout; negative = error.
int ECYRead(uint64_t session, void *data, int capacity);
int ECYSelect(uint64_t session, const char *group, const char *node);
// Rewrites the panel node files from a full configuration and reloads them without restarting the kernel; 0 = updated.
int ECYUpdateNodes(uint64_t session, void *data, int size);
// Supply exactly ECY_CONTROL_CAPACITY bytes; it must equal MaximumControlBytes in Kernel/control.go.
#define ECY_CONTROL_CAPACITY 1048576
int ECYControl(uint64_t session, void *data, int size, void *output, int capacity);
#endif
