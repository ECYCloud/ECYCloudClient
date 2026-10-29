#ifndef ECY_KERNEL_H
#define ECY_KERNEL_H
#include <stdint.h>
// Buffers belong to the caller; the core never retains them after a call.
// MTU 0 with empty addresses starts only the control plane, without a packet device.
uint64_t ECYStart(void *data, int size, const char *directory, int mtu, const char *ipv4, const char *ipv6, const char *dns);
void ECYStop(uint64_t session);
int ECYSubmit(uint64_t session, void *data, int size);
// Supply exactly 65535 bytes. Positive = packet length; 0 = timeout; negative = error.
int ECYRead(uint64_t session, void *data, int capacity);
int ECYSelect(uint64_t session, const char *group, const char *node);
int ECYControl(uint64_t session, void *data, int size, void *output, int capacity);
#endif
