package bridgevalidation

/*
#include <mach/mach.h>
static unsigned long long footprint(void) {
	task_vm_info_data_t info;
	mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
	if (task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&info, &count) != KERN_SUCCESS) {
		return 0;
	}
	return info.phys_footprint;
}
*/
import "C"

func physFootprint() uint64 { return uint64(C.footprint()) }
