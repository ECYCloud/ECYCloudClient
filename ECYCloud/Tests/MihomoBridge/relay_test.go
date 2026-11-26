package bridgevalidation

import (
	"net"
	"testing"
	"time"
)

type delayed struct {
	due  time.Time
	data []byte
	to   *net.UDPAddr
}

// 在节点前加一段 UDP 中转，每个方向延时 rtt/2，模拟往返时延；带宽不设限
func delayRelay(t *testing.T, server int, rtt time.Duration) int {
	front, err := net.ListenUDP("udp4", &net.UDPAddr{IP: net.IPv4(127, 0, 0, 1)})
	if err != nil {
		t.Fatal(err)
	}
	back, err := net.DialUDP("udp4", nil, &net.UDPAddr{IP: net.IPv4(127, 0, 0, 1), Port: server})
	if err != nil {
		t.Fatal(err)
	}
	half := rtt / 2
	up, down := make(chan delayed, 1<<16), make(chan delayed, 1<<16)
	var client *net.UDPAddr
	sender := func(queue chan delayed, send func(delayed)) {
		for p := range queue {
			if wait := time.Until(p.due); wait > 0 {
				time.Sleep(wait)
			}
			send(p)
		}
	}
	go sender(up, func(p delayed) { _, _ = back.Write(p.data) })
	go sender(down, func(p delayed) { _, _ = front.WriteToUDP(p.data, p.to) })
	go func() {
		buf := make([]byte, 65535)
		for {
			n, addr, err := front.ReadFromUDP(buf)
			if err != nil {
				return
			}
			client = addr
			up <- delayed{due: time.Now().Add(half), data: append([]byte(nil), buf[:n]...)}
		}
	}()
	go func() {
		buf := make([]byte, 65535)
		for {
			n, err := back.Read(buf)
			if err != nil {
				return
			}
			if client != nil {
				down <- delayed{due: time.Now().Add(half), data: append([]byte(nil), buf[:n]...), to: client}
			}
		}
	}()
	return front.LocalAddr().(*net.UDPAddr).Port
}
