include $(TOPDIR)/rules.mk

PANEL_JSON:=$(CURDIR)/../../config/panel.json
PUBSPEC:=$(CURDIR)/../../app/pubspec.yaml

ECYCLOUD_SITE_URL?=$(shell sed -n 's|.*"panelUrl"[[:space:]]*:[[:space:]]*"\([^"]*\)".*|\1|p' $(PANEL_JSON) 2>/dev/null)
ECYCLOUD_SUB_URL?=$(shell sed -n 's|.*"subUrl"[[:space:]]*:[[:space:]]*"\([^"]*\)".*|\1|p' $(PANEL_JSON) 2>/dev/null)
ECYCLOUD_VERSION?=$(shell sed -n 's|^version:[[:space:]]*\([0-9][0-9.]*\).*|\1|p' $(PUBSPEC) 2>/dev/null)

PKG_VERSION:=$(if $(ECYCLOUD_VERSION),$(ECYCLOUD_VERSION),0.0.0)
PKG_RELEASE:=1
PKG_LICENSE:=GPL-3.0-or-later
PKG_MAINTAINER:=ECY Cloud

LUCI_TITLE:=ECY Cloud client for OpenWrt (mihomo transparent proxy)
LUCI_URL:=https://github.com/ECYCloud/ECYCloudClient
LUCI_DESCRIPTION:=LuCI interface, configuration assembly, procd service and nftables \
	transparent proxy rules for the ECY Cloud panel on top of the mihomo kernel.
LUCI_DEPENDS:=+luci-base +mihomo +firewall4 +curl +ca-bundle +ip-full +kmod-tun \
	+kmod-nft-tproxy +kmod-nft-socket +rpcd-mod-ucode +ucode-mod-fs +ucode-mod-uci \
	+ucode-mod-ubus
LUCI_PKGARCH:=all

# 不声明就会被升级包覆盖：端口、模式、LAN 接口全部回到出厂值
define Package/luci-app-ecycloud/conffiles
/etc/config/ecycloud
endef

include $(TOPDIR)/feeds/luci/luci.mk

define Build/Prepare/luci-app-ecycloud
	[ -n "$(ECYCLOUD_SITE_URL)" ] && [ -n "$(ECYCLOUD_SUB_URL)" ] || { \
		echo "ECYCLOUD_SITE_URL / ECYCLOUD_SUB_URL unset and $(PANEL_JSON) unreadable" >&2; \
		exit 1; \
	}
	$(SED) 's|__SITE_URL__|$(ECYCLOUD_SITE_URL)|; s|__SUB_URL__|$(ECYCLOUD_SUB_URL)|; s|__VERSION__|$(PKG_VERSION)|' \
		$(PKG_BUILD_DIR)/root/usr/share/ecycloud/build.json
	chmod 0755 $(PKG_BUILD_DIR)/root/etc/init.d/ecycloud \
		$(PKG_BUILD_DIR)/root/usr/libexec/ecycloud-ctl
endef

# call BuildPackage - OpenWrt buildroot signature
