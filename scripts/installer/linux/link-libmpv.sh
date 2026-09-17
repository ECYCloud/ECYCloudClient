#!/bin/sh
# 构建机链的是 libmpv.so.1；仅有 so.2 时在载荷 lib 里补兼容名，否则 GUI 起不来。
dest=/opt/ecycloud/lib/libmpv.so.1
[ -d /opt/ecycloud/lib ] || exit 0
[ -e "$dest" ] && exit 0
so2=
for p in \
    /usr/lib/x86_64-linux-gnu/libmpv.so.2 \
    /usr/lib/aarch64-linux-gnu/libmpv.so.2 \
    /lib/x86_64-linux-gnu/libmpv.so.2 \
    /lib/aarch64-linux-gnu/libmpv.so.2 \
    /usr/lib64/libmpv.so.2 \
    /usr/lib/libmpv.so.2
do
    if [ -e "$p" ]; then
        so2=$p
        break
    fi
done
[ -n "$so2" ] || exit 0
ln -sf "$so2" "$dest"
