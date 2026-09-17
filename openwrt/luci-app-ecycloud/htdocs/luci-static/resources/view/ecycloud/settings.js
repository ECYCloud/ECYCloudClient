'use strict';
'require view';
'require form';
'require tools.widgets as widgets';
'require ecycloud.api as api';

function actionButton(label, run) {
	return api.btn(label, 'cta', run);
}

function dummyOption(section, name, title, descr, widget) {
	var o = section.option(form.DummyValue, name, title, descr);
	o.rmempty = true;
	o.write = function() {};
	o.remove = function() {};
	o.renderWidget = function() {
		return widget();
	};
	return o;
}

function attachListDialog(option, title, descr, accept, invalidMsg) {
	option.renderWidget = function() {
		var list = form.DynamicList.prototype.renderWidget.apply(this, arguments);
		var cancel = api.pressable('ecycloud-modal-cancel', {}, [ _('Close') ]);
		var ok = api.pressable('ecycloud-modal-ok', {}, [ _('OK') ]);
		var hint = E('div', { 'class': 'ecycloud-modal-text is-err', 'hidden': 'hidden' });
		var backdrop;
		var open;
		var mounted = false;

		function setHint(text) {
			if (text) {
				hint.textContent = text;
				hint.removeAttribute('hidden');
			}
			else {
				hint.textContent = '';
				hint.setAttribute('hidden', 'hidden');
			}
		}
		function pendingValue() {
			var pending = list.querySelector('.add-item .ecycloud-input-host')
				|| list.querySelector('.add-item input[type="text"]');
			return pending ? String(pending.value || '').replace(/^\s+|\s+$/g, '') : '';
		}

		list.classList.add('ecycloud-dynlist');
		list._ecyReject = function(value) {
			setHint(value ? invalidMsg : '');
		};
		api.skinDynlist(list, accept);
		this._ecyList = list;
		backdrop = E('div', {
			'class': 'ecycloud-modal is-dialog',
			'hidden': 'hidden',
			'data-theme': api.detectTheme()
		}, [
			E('div', { 'class': 'ecycloud-modal-card is-dialog' }, [
				E('div', { 'class': 'ecycloud-modal-title' }, [ title ]),
				E('div', { 'class': 'ecycloud-modal-text' }, [ descr ]),
				list,
				hint,
				E('div', { 'class': 'ecycloud-modal-actions' }, [ ok, cancel ])
			])
		]);
		open = api.pressable('ecycloud-btn is-cta', {}, [ _('Settings') ]);
		function close() {
			backdrop.setAttribute('hidden', 'hidden');
		}
		open.addEventListener('click', function(ev) {
			ev.preventDefault();
			if (!mounted) {
				document.body.appendChild(backdrop);
				api.isolate(backdrop);
				api.onBackdrop(backdrop, close);
				mounted = true;
			}
			backdrop.removeAttribute('hidden');
			api.applyTheme(backdrop);
		});
		ok.addEventListener('click', function() {
			var value = pendingValue();
			if (value && typeof accept == 'function' && !accept(value)) {
				setHint(invalidMsg);
				return;
			}
			setHint('');
			close();
		});
		cancel.addEventListener('click', close);
		return E('div', { 'class': 'ecycloud-list-dialog' }, [ open ]);
	};
	option.formvalue = function() {
		var node = this._ecyList;
		var items = [];
		var pending;
		var value;
		var i;
		var el;

		if (!node)
			return [];
		el = node.querySelectorAll('.item input[type="hidden"]');
		for (i = 0; i < el.length; i++) {
			value = el[i].value;
			if (value && (!accept || accept(value)))
				items.push(value);
		}
		pending = node.querySelector('.add-item .ecycloud-input-host')
			|| node.querySelector('.add-item input[type="text"]');
		value = pending ? String(pending.value || '').replace(/^\s+|\s+$/g, '') : '';
		if (value && (!accept || accept(value)) && items.indexOf(value) < 0)
			items.push(value);
		return items;
	};
}

function updateTile(initial, check) {
	var status = E('div', { 'class': 'cbi-value-description' }, [ initial ]);
	var extra = E('span');
	var btn = actionButton(_('Check for updates'), function() {
		extra.textContent = '';
		return check().then(function(res) {
			status.textContent = res.text;
			if (res.link) {
				extra.appendChild(document.createTextNode(' '));
				extra.appendChild(E('a', {
					'class': 'ecycloud-btn is-cta',
					href: res.link,
					target: '_blank',
					rel: 'noreferrer'
				}, [ _('Open releases') ]));
			}
			api.notify({ ok: res.ok, msg: res.text });
		});
	});

	return E('div', {}, [ E('div', {}, [ btn, extra ]), status ]);
}

function kernelUpdateText(res) {
	if (!res || !res.ok)
		return _('Check failed: %s').format((res && res.msg) || _('Request failed'));
	if (!res.current)
		return _('Local version unknown, latest (%s)').format(res.latest);
	if (res.outdated)
		return _('Update available (%s). This page cannot install it. Use the router package manager via SSH. apk: apk update && apk upgrade mihomo-meta; opkg: opkg update && opkg upgrade mihomo-meta').format(res.latest);
	return _('Up to date (%s)').format(res.current);
}

return view.extend({
	handleSave: null,

	handleSaveApply: function() {
		var self = this;

		return api.status().then(function(status) {
			if (!api.signedIn(status))
				return;

			return Promise.resolve(self._form ? self._form.save() : api.saveMaps()).then(function() {
				return L.ui.changes.apply(true);
			});
		});
	},

	load: function() {
		return api.status();
	},

	render: function(status) {
		var self = this;

		return api.ensureStyle().then(function() {
			if (!api.signedIn(status))
				return api.shell([ api.signedOut() ], true);

			return self.renderForm(status);
		});
	},

	renderForm: function(status) {
		var m, s, o;

		m = new form.Map('ecycloud', null,
			_('Saving restarts the service, connections are dropped for a moment.'));
		this._form = m;

		s = m.section(form.NamedSection, 'config', 'ecycloud', _('Proxy'));
		s.addremove = false;

		o = s.option(form.ListValue, 'mode', _('Proxy mode'));
		o.value('tproxy', _('TPROXY'));
		o.value('tun', _('TUN'));
		o.rmempty = false;
		api.skinListValue(o);

		o = s.option(form.Value, 'tproxy_port', _('TPROXY port'));
		o.datatype = 'port';
		o.depends('mode', 'tproxy');
		o.default = '10202';
		o.placeholder = '10202';
		o.rmempty = false;
		o.cfgvalue = function(section) {
			return form.Value.prototype.cfgvalue.call(this, section) || '10202';
		};
		o.write = function(section, value) {
			return form.Value.prototype.write.call(this, section, value || '10202');
		};
		o.remove = function() {};
		api.skinValue(o);

		o = s.option(form.DynamicList, 'bypass', _('TPROXY bypass'));
		o.datatype = 'or(ip4addr,ip6addr,cidr4,cidr6)';
		o.placeholder = '192.168.56.0/24';
		o.depends('mode', 'tproxy');
		o.rmempty = true;
		attachListDialog(o, _('TPROXY bypass'),
			_('Destinations that skip TPROXY. IPv4/IPv6 address or CIDR only, for example 192.168.56.0/24. LAN, loopback and link-local are already bypassed.'),
			function(value) { return api.isIpNet(value); },
			_('IPv4/IPv6 address or CIDR only'));

		o = s.option(form.ListValue, 'tun_stack', _('TUN stack'));
		o.value('mixed', _('Mixed'));
		o.value('system', _('System'));
		o.value('gvisor', _('gVisor'));
		o.depends('mode', 'tun');
		o.rmempty = false;
		api.skinListValue(o);

		o = s.option(form.DynamicList, 'tun_exclude', _('TUN excluded networks'));
		o.datatype = 'or(cidr4,cidr6)';
		o.placeholder = '192.168.56.0/24';
		o.depends('mode', 'tun');
		o.rmempty = true;
		attachListDialog(o, _('TUN excluded networks'),
			_('IPv4/IPv6 CIDR only, for example 192.168.56.0/24 or fd00::/8. LAN and loopback are already excluded.'),
			function(value) { return api.isIpCidr(value); },
			_('IPv4/IPv6 CIDR only'));

		o = s.option(form.Value, 'mixed_port', _('Mixed port'),
			_('HTTP and SOCKS proxy port of the kernel.'));
		o.datatype = 'port';
		o.rmempty = false;
		api.skinValue(o);

		o = s.option(form.Value, 'dns_port', _('DNS port'),
			_('Loopback port the kernel resolver listens on.'));
		o.datatype = 'port';
		o.rmempty = false;
		api.skinValue(o);

		o = s.option(widgets.NetworkSelect, 'lan_interface', _('LAN interfaces'),
			_('Traffic from these interfaces is sent to the kernel.'));
		o.multiple = true;
		o.nocreate = true;
		o.rmempty = false;
		api.skinNetworkSelect(o);

		o = s.option(form.Flag, 'dns_hijack', _('Hijack DNS'),
			_('Redirect port 53 of LAN clients and point dnsmasq at the kernel resolver.'));
		o.default = '1';
		o.rmempty = false;
		api.skinFlag(o);

		o = s.option(form.Flag, 'router_proxy', _('Proxy the router itself'),
			_('Also send traffic originating on the router through the kernel.'));
		o.default = '0';
		o.rmempty = false;
		api.skinFlag(o);

		o = s.option(form.Flag, 'ipv6', _('IPv6'),
			_('Handle IPv6 traffic as well.'));
		o.default = '1';
		o.rmempty = false;
		api.skinFlag(o);

		o = s.option(form.Flag, 'allow_lan', _('Allow LAN'),
			_('Let LAN clients use the mixed port directly.'));
		o.default = '1';
		o.rmempty = false;
		api.skinFlag(o);

		s = m.section(form.NamedSection, 'config', 'ecycloud', _('Application'));
		s.addremove = false;

		dummyOption(s, '_theme', _('Color scheme'), '', function() {
			return api.dropdown([
				{ value: 'auto', label: _('Follow system') },
				{ value: 'light', label: _('Light') },
				{ value: 'dark', label: _('Dark') }
			], api.uiTheme(), function(mode) {
				api.setUiTheme(mode);
			});
		});

		o = s.option(form.ListValue, '_ui_language', _('Language'));
		o.value('zh_CN', '简体中文');
		o.value('zh_TW', '繁體中文');
		o.value('en', 'English');
		o.rmempty = false;
		o.cfgvalue = function() {
			return api.resolveLang();
		};
		o.write = function() {};
		o.remove = function() {};
		o.onchange = function(ev, sectionId, value) {
			api.setUiLang(value);
		};
		api.skinListValue(o);

		o = s.option(form.Flag, 'auto_connect', _('Connect at startup'),
			_('Start the kernel after reboot if this router is signed in.'));
		o.default = '0';
		o.rmempty = false;
		api.skinFlag(o);

		o = s.option(form.Value, 'refresh_interval', _('Profile refresh'),
			_('Minutes between panel checks, 0 disables the periodic check.'));
		o.datatype = 'uinteger';
		o.rmempty = false;
		api.skinValue(o);

		o = s.option(form.ListValue, 'log_level', _('Log level'));
		o.value('silent', 'silent');
		o.value('error', 'error');
		o.value('warning', 'warning');
		o.value('info', 'info');
		o.value('debug', 'debug');
		o.rmempty = false;
		api.skinListValue(o);

		s = m.section(form.NamedSection, 'config', 'ecycloud', _('Configuration'));
		s.addremove = false;

		o = s.option(form.Value, 'site_url', _('Panel URL'),
			_('Website address used to sign in. Must be https. If you do not understand these settings, do not change them. Invalid addresses will make the service unusable.'));
		o.placeholder = 'https://owo.ecycloud.com';
		o.rmempty = false;
		api.skinValue(o);

		o = s.option(form.Value, 'sub_url', _('Config URL'),
			_('Host that serves the clash profile. Must be https. Leave empty to use the panel URL. If you do not understand these settings, do not change them. Invalid addresses will make the service unusable.'));
		o.placeholder = 'https://owo.ecydy.com';
		api.skinValue(o);

		o = s.option(form.Value, 'geox_base', _('GeoData mirror'),
			_('Base URL for geoip.metadb and GeoSite.dat. Leave empty to keep the URLs sent by the panel. If you do not understand these settings, do not change them. Invalid addresses will make the service unusable.'));
		o.placeholder = 'https://rules.ecydy.com/Clash';
		api.skinValue(o);

		dummyOption(s, '_refresh', _('Refresh panel profile'),
			_('Pull nodes and rules again. Node changes also follow the account refresh.'),
			function() {
				return actionButton(_('Refresh panel profile'), function() {
					return api.update().then(function(res) {
						api.notify(Object.assign({}, res, { msg: api.profileNotice(res) }));
					});
				});
			});

		dummyOption(s, '_geodata', _('Update GeoData'),
			_('Redownload the geo databases using the panel geox-url. The kernel must be running.'),
			function() {
				return actionButton(_('Update GeoData'), function() {
					return api.updateGeo().then(function(res) {
						if (!res.ok)
							api.notify(res, res.msg || _('The kernel is not running'));
						else
							api.notify({
								ok: true,
								msg: res.changed ? _('Update succeeded') : _('Already up to date')
							});
					});
				});
			});

		dummyOption(s, '_runtime', _('View runtime config'),
			_('Read-only view of the kernel config.json'),
			function() {
				return actionButton(_('View runtime config'), function() {
					return api.runtimeConfig().then(function(res) {
						if (!res.ok) {
							api.notify(res, res.msg || _('No runtime config yet'));
							return;
						}
						api.showText(_('Runtime config'), res.text);
					});
				});
			});

		dummyOption(s, '_rules', _('View routing rules'),
			_('Read-only view of downloaded rule-providers'),
			function() {
				return actionButton(_('View routing rules'), function() {
					return api.ruleProviders().then(function(res) {
						var items = (res && res.items) || [];
						if (!items.length) {
							api.alert(_('No routing rules yet. Connect once and they will download into the run directory.'));
							return;
						}

						return api.dialog({
							title: _('Routing rules'),
							choices: items.map(function(item) {
								return {
									value: item.path,
									label: item.name,
									detail: item.path
								};
							}),
							cancel: true,
							action: _('Open'),
							onAction: function(item) {
								return api.ruleProvider(item.value).then(function(file) {
									if (!file.ok) {
										api.notify(file, file.msg || _('Request failed'));
										return;
									}
									api.showText(item.value, file.text);
								});
							}
						});
					});
				});
			});

		s = m.section(form.NamedSection, 'config', 'ecycloud', _('About'));
		s.addremove = false;

		o = s.option(form.DummyValue, '_version', _('Current version'));
		o.cfgvalue = function() {
			return (status && status.version) || '-';
		};

		dummyOption(s, '_app_update', _('Check for updates'),
			_('This only checks the version. To install, open the releases page, download the OpenWrt package, extract it, then install via SSH. apk: apk add --allow-untrusted /tmp/luci-app-ecycloud-*.apk; ipk: opkg install /tmp/luci-app-ecycloud_*.ipk'),
			function() {
				return updateTile(_('Not checked yet'), function() {
					return api.checkUpdate('app').then(function(res) {
						return {
							ok: !!(res && res.ok),
							text: api.appUpdateText(res),
							link: res && res.ok && res.outdated ? res.releases_url : ''
						};
					}).catch(function() {
						return {
							ok: false,
							text: _('Check failed: %s').format(_('Request failed'))
						};
					});
				});
			});

		dummyOption(s, '_kernel_update', _('mihomo kernel'),
			_('This only checks the version. To upgrade, use the router package manager via SSH. apk: apk update && apk upgrade mihomo-meta; opkg: opkg update && opkg upgrade mihomo-meta'),
			function() {
				var current = status && status.kernel_version;
				return updateTile(
					current ? _('Current (%s)').format(current) : _('Local version unknown'),
					function() {
						return api.checkUpdate('kernel').then(function(res) {
							return {
								ok: !!(res && res.ok),
								text: kernelUpdateText(res)
							};
						}).catch(function() {
							return {
								ok: false,
								text: _('Check failed: %s').format(_('Request failed'))
							};
						});
					});
			});

		return Promise.resolve(m.render()).then(function(node) {
			var icons = [ 'vpn', 'tune', 'description', 'info' ];
			node.querySelectorAll('.cbi-section > h3').forEach(function(h3, i) {
				if (!icons[i] || h3.querySelector('.ecycloud-ico'))
					return;
				h3.insertBefore(E('span', { 'class': 'ecycloud-ico', 'data-ico': icons[i] }), h3.firstChild);
			});
			return api.shell([ node ]);
		});
	}
});
