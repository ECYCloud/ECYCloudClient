package kernel

/*
#include <TargetConditionals.h>
#include <mach/mach.h>
#if TARGET_OS_IPHONE
#include <os/proc.h>
#endif

// 系统按 phys_footprint 判断扩展是否超出内存上限
static unsigned long long ecyFootprint(void) {
	task_vm_info_data_t info;
	mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
	if (task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&info, &count) != KERN_SUCCESS) {
		return 0;
	}
	return info.phys_footprint;
}

static unsigned long long ecyAvailable(void) {
#if TARGET_OS_IPHONE
	return os_proc_available_memory();
#else
	return 0;
#endif
}
*/
import "C"

import (
	"context"
	"runtime/debug"
	"runtime/metrics"
	"slices"
	"sync/atomic"
	"time"

	"github.com/metacubex/mihomo/log"
	"github.com/metacubex/mihomo/tunnel/statistic"
)

var tunnelMemoryLimit atomic.Uint64

func init() { tunnelMemoryLimit.Store(defaultTunnelMemoryLimit) }

// SetTunnelMemoryLimit 设置包隧道实例的内存上限（phys_footprint，字节），0 表示不限
func SetTunnelMemoryLimit(bytes uint64) { tunnelMemoryLimit.Store(bytes) }

const (
	admitReserve = 15 * 1024 * 1024
	shedReserve  = 6 * 1024 * 1024
)

type memoryGuard struct {
	refusing bool
	// 下一次允许主动回收的时刻（UnixNano）
	reclaimAt atomic.Int64
}

// 读不到内存时按不限处理，不能因此拒绝全部连接
func memoryUsage() (used, limit uint64) {
	limit = tunnelMemoryLimit.Load()
	used = uint64(C.ecyFootprint())
	if limit == 0 || used == 0 {
		return 0, 0
	}
	if available := uint64(C.ecyAvailable()); available > 0 {
		limit = min(limit, used+available)
	}
	return used, limit
}

// 建连高峰时读数里的垃圾与已释放未归还的页能占十几 MiB，入口按回收后会剩下的占用判断，否则会误拒
func settledUsage() (used, limit uint64) {
	used, limit = memoryUsage()
	if limit == 0 {
		return used, limit
	}
	samples := []metrics.Sample{{Name: "/memory/classes/heap/free:bytes"}, {Name: "/memory/classes/heap/objects:bytes"}, {Name: "/gc/heap/live:bytes"}}
	metrics.Read(samples)
	spare := samples[0].Value.Uint64()
	if objects, live := samples[1].Value.Uint64(), samples[2].Value.Uint64(); objects > live {
		spare += objects - live
	}
	if spare < used {
		used -= spare
	}
	return used, limit
}

func (g *memoryGuard) reclaim(gap time.Duration) (used, limit uint64) {
	now := time.Now().UnixNano()
	if at := g.reclaimAt.Load(); now >= at && g.reclaimAt.CompareAndSwap(at, now+int64(gap)) {
		debug.FreeOSMemory()
	}
	return memoryUsage()
}

func (g *memoryGuard) admit() bool {
	used, limit := settledUsage()
	return limit == 0 || used+admitReserve < limit
}

func (g *memoryGuard) run(ctx context.Context) {
	timer := time.NewTimer(time.Second)
	defer timer.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-timer.C:
		}
		// 系统按真实读数结束扩展：越过拒绝线每秒回收一次，逼近上限时先回收再决定断不断
		used, limit := memoryUsage()
		if limit != 0 && used+admitReserve >= limit {
			used, limit = g.reclaim(time.Second)
		}
		if limit != 0 && used+shedReserve >= limit {
			if used, limit = g.reclaim(100 * time.Millisecond); used+shedReserve >= limit {
				g.shed(used, limit)
			}
		}
		settled, _ := settledUsage()
		tight := limit != 0 && settled+admitReserve >= limit
		if tight != g.refusing {
			g.refusing = tight
			if tight {
				log.Warnln("内存接近系统上限（%d / %d MiB），暂不接受新连接", used>>20, limit>>20)
			} else {
				log.Infoln("内存已回落（%d MiB），恢复接受新连接", used>>20)
			}
		}
		switch {
		case tight:
			timer.Reset(100 * time.Millisecond)
		case limit != 0 && used+2*admitReserve >= limit:
			timer.Reset(250 * time.Millisecond)
		default:
			timer.Reset(time.Second)
		}
	}
}

func (g *memoryGuard) shed(used, limit uint64) {
	var trackers []statistic.Tracker
	statistic.DefaultManager.Range(func(c statistic.Tracker) bool { trackers = append(trackers, c); return true })
	if len(trackers) == 0 {
		g.reclaimAt.Store(time.Now().Add(5 * time.Second).UnixNano())
		return
	}
	slices.SortFunc(trackers, func(a, b statistic.Tracker) int { return b.Info().Start.Compare(a.Info().Start) })
	count := max(1, len(trackers)/8)
	for _, c := range trackers[:count] {
		_ = c.Close()
	}
	debug.FreeOSMemory()
	log.Warnln("内存接近系统上限（%d / %d MiB），已断开最新的 %d 条连接", used>>20, limit>>20, count)
}
