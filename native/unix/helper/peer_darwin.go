//go:build darwin && cgo

package main

/*
#cgo LDFLAGS: -framework Security -framework CoreFoundation -lbsm
#include <stdlib.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <bsm/libbsm.h>
#include <Security/Security.h>

static int ecy_peer_token(int fd, audit_token_t *token) {
	socklen_t length = sizeof(*token);
	return getsockopt(fd, SOL_LOCAL, LOCAL_PEERTOKEN, token, &length);
}

static pid_t ecy_token_pid(audit_token_t token) { return audit_token_to_pid(token); }
static uid_t ecy_token_euid(audit_token_t token) { return audit_token_to_euid(token); }

static OSStatus ecy_self_team(char *team, size_t size) {
	SecCodeRef self = NULL;
	OSStatus status = SecCodeCopySelf(kSecCSDefaultFlags, &self);
	if (status != errSecSuccess) return status;
	CFDictionaryRef info = NULL;
	status = SecCodeCopySigningInformation((SecStaticCodeRef)self, kSecCSSigningInformation, &info);
	CFRelease(self);
	if (status != errSecSuccess) return status;
	team[0] = 0;
	CFStringRef value = CFDictionaryGetValue(info, kSecCodeInfoTeamIdentifier);
	if (value != NULL && !CFStringGetCString(value, team, size, kCFStringEncodingUTF8)) status = errSecParam;
	CFRelease(info);
	return status;
}

static OSStatus ecy_guest_path(audit_token_t token, const char *team, char *path, size_t size) {
	CFDataRef data = CFDataCreate(NULL, (const UInt8 *)&token, sizeof(token));
	if (data == NULL) return errSecAllocate;
	const void *keys[] = { kSecGuestAttributeAudit };
	const void *values[] = { data };
	CFDictionaryRef attributes = CFDictionaryCreate(NULL, keys, values, 1, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
	CFRelease(data);
	if (attributes == NULL) return errSecAllocate;
	SecCodeRef code = NULL;
	OSStatus status = SecCodeCopyGuestWithAttributes(NULL, attributes, kSecCSDefaultFlags, &code);
	CFRelease(attributes);
	if (status != errSecSuccess) return status;
	SecRequirementRef requirement = NULL;
	if (team[0] != 0) {
		CFStringRef text = CFStringCreateWithFormat(NULL, NULL, CFSTR("anchor apple generic and certificate leaf[subject.OU] = \"%s\""), team);
		status = text == NULL ? errSecAllocate : SecRequirementCreateWithString(text, kSecCSDefaultFlags, &requirement);
		if (text != NULL) CFRelease(text);
	}
	if (status == errSecSuccess) status = SecCodeCheckValidity(code, kSecCSDefaultFlags, requirement);
	if (requirement != NULL) CFRelease(requirement);
	CFURLRef url = NULL;
	if (status == errSecSuccess) status = SecCodeCopyPath((SecStaticCodeRef)code, kSecCSDefaultFlags, &url);
	CFRelease(code);
	if (status != errSecSuccess) return status;
	if (!CFURLGetFileSystemRepresentation(url, true, (UInt8 *)path, (CFIndex)size)) status = errSecParam;
	CFRelease(url);
	return status;
}
*/
import "C"

import (
	"fmt"
	"net"
	"strconv"
	"sync"
	"time"
	"unsafe"
)

type peer struct {
	pid   int
	user  string
	exe   string
	token C.audit_token_t
}

var selfTeam = sync.OnceValues(func() (string, error) {
	var team [64]C.char
	if status := C.ecy_self_team(&team[0], C.size_t(len(team))); status != C.errSecSuccess {
		return "", fmt.Errorf("读取 helper 自身签名失败: OSStatus %d", int(status))
	}
	return C.GoString(&team[0]), nil
})

// 对端只按内核审计令牌认定（kern.procargs2 的路径在对端自己的内存里，可改写）。
// helper 带团队标识时要求同团队签名，/Applications 对 admin 组可写。
func peerIdentity(conn *net.UnixConn, _ time.Time) (*peer, error) {
	token, err := peerToken(conn)
	if err != nil {
		return nil, err
	}
	team, err := selfTeam()
	if err != nil {
		return nil, err
	}
	cTeam := C.CString(team)
	defer C.free(unsafe.Pointer(cTeam))
	var path [4096]C.char
	if status := C.ecy_guest_path(token, cTeam, &path[0], C.size_t(len(path))); status != C.errSecSuccess {
		return nil, fmt.Errorf("调用方代码签名校验失败: OSStatus %d", int(status))
	}
	return &peer{
		pid:   int(C.ecy_token_pid(token)),
		user:  strconv.FormatUint(uint64(C.ecy_token_euid(token)), 10),
		exe:   C.GoString(&path[0]),
		token: token,
	}, nil
}

// LOCAL_PEERTOKEN 取的是最后读写这条连接的进程此刻的映像：exec 后会变成新映像，兄弟进程读写会换成兄弟进程，
// 请求读完时必须仍是握手时那个进程的同一次 exec
func (p *peer) confirm(conn *net.UnixConn) error {
	token, err := peerToken(conn)
	if err != nil {
		return err
	}
	if token != p.token {
		return fmt.Errorf("请求不是由通过校验的调用方写出")
	}
	return nil
}

func (*peer) close() {}

func peerToken(conn *net.UnixConn) (C.audit_token_t, error) {
	var token C.audit_token_t
	raw, err := conn.SyscallConn()
	if err != nil {
		return token, fmt.Errorf("获取连接底层句柄失败: %w", err)
	}
	var tokenErr error
	if err := raw.Control(func(fd uintptr) {
		if result, errno := C.ecy_peer_token(C.int(fd), &token); result != 0 {
			tokenErr = errno
		}
	}); err != nil {
		return token, fmt.Errorf("读取对端凭据失败: %w", err)
	}
	if tokenErr != nil {
		return token, fmt.Errorf("读取对端凭据失败: %w", tokenErr)
	}
	return token, nil
}
