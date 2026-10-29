#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
logged_in=1
saved_enabled=0
saved_auto_connect=1
prepared=-1
instances=''
prepare_status=0

config_load() { :; }
config_get_bool() {
	case "$3" in
		enabled) eval "$1=\$saved_enabled" ;;
		auto_connect) eval "$1=\$saved_auto_connect" ;;
	esac
}
uci() {
	case "$*" in
		'-q set ecycloud.config.enabled=1') saved_enabled=1 ;;
		'-q set ecycloud.config.enabled=0') saved_enabled=0 ;;
	esac
}
procd_open_instance() { instances="$instances $1"; }
procd_set_param() { :; }
procd_close_instance() { :; }
start() { start_service; }
boot() { start; }

. "${1:-$root/root/etc/init.d/ecycloud}"
has_session() { [ "$logged_in" = 1 ]; }
ctl() {
	case "$1" in
		prepare) prepared=$saved_enabled; return "$prepare_status" ;;
		kernel) printf '/usr/libexec/mihomo\n' ;;
	esac
}
CTL=ctl

boot
[ "$prepared" = 1 ] || { echo '自动连接必须在生成 TUN 配置前启用'; exit 1; }
case "$instances" in
	*' core watchdog refresh statistics') ;;
	*) echo '内核、看门狗和面板轮询必须分别受 procd 管理'; exit 1 ;;
esac

saved_enabled=0
prepared=-1
start_service
[ "$prepared" = 0 ] && [ "$saved_enabled" = 0 ] || { echo '手动断开后的重启不能被自动连接开关重新接管'; exit 1; }

saved_auto_connect=0
saved_enabled=1
prepared=-1
boot
[ "$prepared" = 0 ] && [ "$saved_enabled" = 0 ] || { echo '关闭自动连接时必须清除上次连接状态并进入待机'; exit 1; }

logged_in=0
saved_enabled=1
saved_auto_connect=1
prepared=-1
boot
[ "$prepared" = -1 ] && [ "$saved_enabled" = 0 ] || { echo '未登录时不能启用连接'; exit 1; }

logged_in=1
saved_enabled=1
prepare_status=1
instances=''
if start_service; then
	echo '配置校验失败不能启动服务'
	exit 1
fi
[ -z "$instances" ] || { echo '配置校验失败不能登记 procd 实例'; exit 1; }
prepare_status=2
instances=''
start_service
[ "$instances" = ' retry' ] || { echo '临时网络失败必须登记重试任务'; exit 1; }
echo 'OpenWrt init 稳定性回归通过：自动连接、手动断开、未登录、校验失败及任务隔离。'
