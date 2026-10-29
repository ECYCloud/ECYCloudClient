package main

/*
#include <stdint.h>
#include <stdlib.h>
*/
import "C"
import (
	"ecycloud/apple/Kernel"
	"time"
	"unsafe"
)

// Result: 0 = success/timeout, -1 = stopped, -2 = invalid, -3 = queue full.
func result(err error) C.int {
	switch err {
	case nil:
		return 0
	case kernel.ErrStopped:
		return -1
	case kernel.ErrQueueFull:
		return -3
	default:
		return -2
	}
}

//export ECYStart
func ECYStart(data unsafe.Pointer, size C.int, directory *C.char, mtu C.int, ipv4, ipv6, dns *C.char) C.uint64_t {
	if data == nil || size <= 0 || size > kernel.MaximumConfigBytes || directory == nil || ipv4 == nil || ipv6 == nil || dns == nil {
		return 0
	}
	id, err := kernel.Start(C.GoBytes(data, size), C.GoString(directory), int(mtu), C.GoString(ipv4), C.GoString(ipv6), C.GoString(dns))
	if err != nil {
		return 0
	}
	return C.uint64_t(id)
}

//export ECYStop
func ECYStop(id C.uint64_t) { kernel.Stop(uint64(id)) }

//export ECYSubmit
func ECYSubmit(id C.uint64_t, data unsafe.Pointer, size C.int) C.int {
	if data == nil || size <= 0 || size > kernel.MaximumPacketBytes {
		return -2
	}
	return result(kernel.Submit(uint64(id), unsafe.Slice((*byte)(data), int(size))))
}

//export ECYRead
func ECYRead(id C.uint64_t, data unsafe.Pointer, capacity C.int) C.int {
	if data == nil || capacity < kernel.MaximumPacketBytes || capacity > kernel.MaximumPacketBytes {
		return -2
	}
	n, err := kernel.Read(uint64(id), unsafe.Slice((*byte)(data), int(capacity)), 250*time.Millisecond)
	if err != nil {
		return result(err)
	}
	return C.int(n)
}

//export ECYSelect
func ECYSelect(id C.uint64_t, group, node *C.char) C.int {
	if group == nil || node == nil {
		return -2
	}
	return result(kernel.Select(uint64(id), C.GoString(group), C.GoString(node)))
}

//export ECYControl
func ECYControl(id C.uint64_t, data unsafe.Pointer, size C.int, output unsafe.Pointer, capacity C.int) C.int {
	if data == nil || size <= 0 || size > 4096 || output == nil || capacity != kernel.MaximumControlBytes {
		return -2
	}
	value, err := kernel.Control(uint64(id), C.GoBytes(data, size))
	if err != nil {
		return result(err)
	}
	copy(unsafe.Slice((*byte)(output), int(capacity)), value)
	return C.int(len(value))
}
func main() {}
