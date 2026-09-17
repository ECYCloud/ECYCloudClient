'use strict';
'require view';
'require dom';
'require poll';
'require ui';
'require ecycloud.api as api';

var REMEMBER = 'ecycloud-remember';

function loginField(title, nodes) {
	return E('div', { 'class': 'ecycloud-login-field' }, [
		E('label', {}, [ title ])
	].concat(nodes));
}

function siteHost(site) {
	var match = String(site || '').match(/^https?:\/\/([^\/]+)/);
	return match ? match[1] : '';
}

function loginHint(site) {
	return _('Sign in with your %s account to load available nodes').format(siteHost(site));
}

function siteHref(site, path) {
	return String(site || '').replace(/\/$/, '') + path;
}

function bar(label, value, ratio, tone) {
	return E('div', { 'class': 'ecycloud-bar-row' }, [
		E('div', { 'class': 'ecycloud-bar-top' }, [
			E('span', {}, [ label ]),
			E('span', { 'class': 'ecycloud-chip is-' + tone }, [ value ])
		]),
		E('div', { 'class': 'ecycloud-bar-track' }, [
			E('div', {
				'class': 'ecycloud-bar-fill is-' + tone,
				'style': 'width:' + Math.max(0, Math.min(100, ratio * 100)).toFixed(1) + '%'
			})
		])
	]);
}

return view.extend({
	handleSave: null,
	handleSaveApply: null,
	handleReset: null,
	rankDay: 'today',

	load: function() {
		return this.loadBundle();
	},

	loadBundle: function() {
		return api.status().then(function(status) {
			status = Object.assign({
				session: {}, account: {}, profile: {}, traffic: {}, lan: []
			}, status);

			if (!api.signedIn(status))
				return { status: status, groups: [], connections: [] };

			return Promise.all([
				api.groups().catch(function() { return { groups: [] }; }),
				api.connections().catch(function() { return { connections: [] }; })
			]).then(function(extra) {
				return {
					status: status,
					groups: extra[0].groups || [],
					connections: extra[1].connections || []
				};
			});
		});
	},

	maybeAlertConfigError: function(status) {
		if (api.phase(status) != 'failed')
			return;

		var error = status.error || '';
		if (!api.isProfileFormatError(error))
			return;
		if (this._alertedConfigError == error || api._lastFormatError == error)
			return;

		this._alertedConfigError = error;
		api.alertProfileFormat(error);
	},

	refresh: function(force) {
		if (!force && api.menuOpen())
			return Promise.resolve();

		return this.loadBundle().then(L.bind(this.update, this), L.bind(function() {
			if (this.signedIn)
				this.update({
					status: { session: { logged_in: true, email: this.signedIn.email } }
				});
		}, this));
	},

	showLogin: function(show) {
		if (!this.loginBox)
			return;

		this.loginBox.classList.toggle('ecycloud-hidden', !show);
	},

	update: function(reply) {
		var status = Object.assign({
			session: {}, account: {}, profile: {}, traffic: {}, lan: []
		}, reply.status || reply);

		if (this.signedIn) {
			status.session.logged_in = true;
			if (!status.session.email)
				status.session.email = this.signedIn.email;
		}

		this.cache = {
			status: status,
			groups: reply.groups || [],
			connections: reply.connections || []
		};
		this.armDelayPoll(this.cache.groups);
		this.maybeAlertConfigError(status);

		if (!status.running || api.phase(status) != 'connected')
			api.connectedSince(false);

		if (status.session.logged_in) {
			this.showLogin(false);
			this.tickTraffic(this.cache.connections, status.running, api.rankSkip(status));
			dom.content(this.body, this.renderHome());
			this.armAnnounce();
			return;
		}

		this.stopAnnounce();
		this.showLogin(true);
		dom.content(this.body, '');
		if (this.loginHint)
			this.loginHint.textContent = loginHint(status.site);
		if (this.loginRegister)
			this.loginRegister.href = siteHref(status.site, '/auth/register');
		if (this.loginForgot)
			this.loginForgot.href = siteHref(status.site, '/password/reset');
	},

	emptyAnnounce: function() {
		return {
			items: [],
			popup: null,
			has_unread: false,
			loaded: false,
			error: '',
			open_index: 0,
			pending_popup: null
		};
	},

	announceSite: function() {
		return (this.cache && this.cache.status && this.cache.status.site) || '';
	},

	applyAnnounce: function(res) {
		if (!res)
			return;

		var prev = this.announcements || this.emptyAnnounce();
		var error = res.error || '';
		if (res.ok === false)
			error = error || res.msg || prev.error;

		this.announcements = {
			items: res.items || prev.items,
			popup: res.popup !== undefined ? res.popup : prev.popup,
			has_unread: res.has_unread != null ? !!res.has_unread : prev.has_unread,
			loaded: res.loaded == true || prev.loaded,
			error: error,
			open_index: res.open_index != null ? +res.open_index : prev.open_index,
			pending_popup: res.pending_popup !== undefined
				? res.pending_popup : prev.pending_popup
		};
	},

	armAnnounce: function() {
		if (this.announceTimer)
			return;

		var self = this;
		this.pollAnnounce();
		this.announceTimer = setInterval(function() {
			if (!self.cache || !self.cache.status.session.logged_in)
				return;
			self.pollAnnounce(true);
		}, 60000);
	},

	stopAnnounce: function() {
		if (this.announceTimer) {
			clearInterval(this.announceTimer);
			this.announceTimer = null;
		}

		this.announcements = this.emptyAnnounce();
		this.announceBusy = false;
		this.announceBrowsing = false;
		this.promptedPopupKey = null;
		if (this.announceModal) {
			api.closeAnnounce();
			this.announceModal = null;
		}
	},

	pollAnnounce: function(force) {
		if (this.announcePoll)
			return this.announcePoll;

		var self = this;
		var wasLoaded = !!(this.announcements && this.announcements.loaded);
		this.announceBusy = true;
		this.announcePoll = api.fetchAnnouncements(force).then(function(res) {
			if (!self.cache || !self.cache.status.session.logged_in)
				return;
			self.applyAnnounce(res);
		}).catch(function() {
		}).finally(function() {
			self.announceBusy = false;
			self.announcePoll = null;
			if (self.body && self.cache && self.cache.status.session.logged_in)
				self.paint();
			if (self.announceBrowsing && !wasLoaded)
				self.presentAnnounce();
			else
				self.maybeShowPopup();
		});
		return this.announcePoll;
	},

	maybeShowPopup: function() {
		if (this.announceBrowsing || this.announceModal)
			return;

		var data = this.announcements;
		if (!data || !data.loaded || !data.pending_popup)
			return;

		var pending = data.pending_popup;
		var key = pending.id + '|' + (pending.updated_at || '');
		if (this.promptedPopupKey == key)
			return;

		this.promptedPopupKey = key;
		this.showAnnouncePopup(pending);
	},

	showAnnouncePopup: function(item) {
		var self = this;
		api.markAnnouncementSeen(item.id).then(function(res) {
			self.applyAnnounce(res);
			self.paint();
		});
		this.announceModal = api.announcePopup(item, {
			site: this.announceSite(),
			onClose: function(gotIt) {
				self.announceModal = null;
				if (!gotIt)
					return;
				api.dismissAnnouncementPopup().then(function(res) {
					self.applyAnnounce(res);
					self.paint();
				});
			}
		});
	},

	presentAnnounce: function() {
		var self = this;
		var data = this.announcements || this.emptyAnnounce();
		this.announceModal = api.announceBrowser({
			items: data.items,
			index: data.open_index,
			loaded: data.loaded,
			busy: this.announceBusy,
			error: data.error,
			site: this.announceSite(),
			onClose: function() {
				self.announceModal = null;
				self.announceBrowsing = false;
				api.markAnnouncementsSeen().then(function(res) {
					self.applyAnnounce(res);
					self.paint();
				});
			}
		});
	},

	openAnnouncements: function() {
		this.announceBrowsing = true;
		this.presentAnnounce();
		if (!(this.announcements && this.announcements.loaded))
			this.pollAnnounce();
	},

	tickTraffic: function(connections, running, skip) {
		if (!running) {
			this.traffic = {
				up: 0, down: 0, totalUp: 0, totalDown: 0,
				historyUp: [], historyDown: [], at: 0, prev: {}
			};
			return this.traffic;
		}

		var prev = (this.traffic && this.traffic.prev) || {};
		var next = {};
		var up = 0;
		var down = 0;

		(connections || []).forEach(function(item) {
			if (!api.viaProxy(item))
				return;

			var id = item.id;
			var currentUp = item.upload || 0;
			var currentDown = item.download || 0;

			next[id] = [ currentUp, currentDown ];
			var last = prev[id] || [ 0, 0 ];
			var du = Math.max(0, currentUp - last[0]);
			var dd = Math.max(0, currentDown - last[1]);
			up += du;
			down += dd;
			if (this.traffic && this.traffic.at && prev[id] && (du + dd) > 0)
				api.noteTrafficRank(item, du + dd, skip);
		}, this);

		var now = Date.now();
		var traffic = this.traffic || {
			totalUp: 0, totalDown: 0, historyUp: [], historyDown: [], at: 0
		};

		if (!traffic.at) {
			traffic.prev = next;
			traffic.at = now;
			this.traffic = traffic;
			return traffic;
		}

		var seconds = (now - traffic.at) / 1000;

		traffic.totalUp += up;
		traffic.totalDown += down;
		traffic.up = seconds > 0 ? Math.floor(up / seconds) : 0;
		traffic.down = seconds > 0 ? Math.floor(down / seconds) : 0;
		traffic.historyUp.push({ at: now, value: traffic.up });
		traffic.historyDown.push({ at: now, value: traffic.down });

		var cutoff = now - 60000;
		while (traffic.historyUp.length && traffic.historyUp[0].at < cutoff) {
			traffic.historyUp.shift();
			traffic.historyDown.shift();
		}

		traffic.prev = next;
		traffic.at = now;
		this.traffic = traffic;
		return traffic;
	},

	saveOption: function(name, value) {
		return api.set(name, value).then(L.bind(function(res) {
			if (res && !res.ok)
				api.notify(res);
			return this.refresh();
		}, this));
	},

	armDelayPoll: function(groups) {
		var busy = (groups || []).some(function(group) {
			if (group.testing)
				return true;
			return (group.members || []).some(function(member) {
				return member.testing;
			});
		});

		if (this.delayTimer) {
			clearTimeout(this.delayTimer);
			this.delayTimer = null;
		}

		if (!busy || !this.body)
			return;

		var self = this;
		this.delayTimer = setTimeout(function() {
			self.delayTimer = null;
			if (!self.body)
				return;
			if (api.menuOpen()) {
				self.armDelayPoll(self.cache && self.cache.groups);
				return;
			}
			self.refresh();
		}, 2000);
	},

	paint: function() {
		if (!this.body || !this.cache || !this.cache.status.session.logged_in)
			return;

		dom.content(this.body, this.renderHome());
	},

	renderHome: function() {
		var status = this.cache.status;
		var groups = api.groupsForMode(this.cache.groups, status.route_mode);
		var nodes = [ this.renderConnection(status) ];

		if (status.route_mode == 'direct' || groups.length)
			nodes.push(this.renderCurrentNode(status, groups));

		nodes.push(this.renderToggles(status));
		nodes.push(this.renderTraffic(status));
		nodes.push(this.renderKernel(status));
		nodes.push(this.renderTrafficRank());
		nodes.push(this.renderUsage(status));

		return E('div', { 'class': 'ecycloud-home' }, nodes);
	},

	renderConnection: function(status) {
		var self = this;
		var phase = api.phase(status);
		var live = phase == 'connected';
		var busy = phase == 'connecting' || phase == 'disconnecting';
		var visual = {
			connected: { cls: 'is-ok', label: _('Connected') },
			connecting: { cls: 'is-warn is-spin', label: _('Connecting') },
			disconnecting: { cls: 'is-warn is-spin', label: _('Currently disconnecting') },
			failed: { cls: 'is-err', label: _('Failed') },
			disconnected: { cls: '', label: _('Disconnected') }
		}[phase];
		var detail = _('Click the button on the right to connect');

		if (phase == 'connected')
			detail = _('Connected %s').format(api.elapsed(api.connectedSince(true)));
		else if (phase == 'connecting')
			detail = status.error || status.message || api.stageText(status);
		else if (phase == 'disconnecting')
			detail = _('Disconnecting, please wait');
		else if (phase == 'failed')
			detail = status.error || _('Failed');

		this.durationNode = E('div', {
			'class': 'ecycloud-status-detail' + (phase == 'failed' ? ' is-err' : '')
		}, [ detail ]);

		var connectIco = (phase == 'disconnecting' || phase == 'connecting')
			? 'close' : (live ? 'stop' : 'play');
		var connect = api.pressable(
			'ecycloud-btn ' + (live || phase == 'disconnecting' ? 'is-danger' : 'is-cta'),
			{ disabled: phase == 'disconnecting' },
			[
			E('span', { 'class': 'ecycloud-ico', 'data-ico': connectIco }),
			phase == 'disconnecting' ? _('Disconnecting')
				: phase == 'connecting' ? _('Cancel')
				: live ? _('Disconnect')
				: _('Connect')
		]);

		connect.addEventListener('click', function() {
			if (live || busy) {
				status.enabled = false;
				self.paint();
				return api.stop().then(L.bind(self.refresh, self));
			}

			status.enabled = true;
			self.paint();
			return api.connect({
				account: status.account,
				device_kicked: status.device_kicked
			}).then(function(res) {
				if (res && !res.ok && !res.cancelled)
					api.notify(res);
				return self.refresh();
			});
		});

		return api.card([
			E('div', { 'class': 'ecycloud-status' }, [
				E('div', { 'class': 'ecycloud-status-main' }, [
					E('div', { 'class': 'ecycloud-badge ' + visual.cls }),
					E('div', { 'class': 'ecycloud-status-text' }, [
						E('div', { 'class': 'ecycloud-status-label' }, [ visual.label ]),
						this.durationNode
					])
				]),
				E('div', { 'class': 'ecycloud-status-actions' }, [
					this.renderMode(status),
					E('div', { 'class': 'ecycloud-status-connect' }, [
						connect,
						this.renderAnnounceBtn()
					])
				])
			])
		]);
	},

	renderAnnounceBtn: function() {
		var self = this;
		var unread = this.announcements && this.announcements.has_unread;
		var bell = api.pressable('ecycloud-icon-btn' + (unread ? ' is-unread' : ''), {
			title: _('Announcements'),
			'aria-label': _('Announcements'),
			'data-ico': 'bell'
		});

		bell.addEventListener('click', function() {
			self.openAnnouncements();
		});

		return bell;
	},

	renderMode: function(status) {
		return api.segments([
			{ value: 'rule', label: _('Rule') },
			{ value: 'global', label: _('Global') },
			{ value: 'direct', label: _('Direct') }
		], status.route_mode || 'rule', L.bind(function(mode) {
			return api.mode(mode).then(L.bind(function(res) {
				if (!res || !res.ok)
					api.notify(res || {});
				return this.refresh();
			}, this));
		}, this));
	},

	renderCurrentNode: function(status, groups) {
		if (status.route_mode == 'direct')
			return api.section('tower', _('Current node'), E('div', {}, [ _('Direct') ]));

		var self = this;
		var picked = this.pickedGroup;
		var group = groups.filter(function(item) { return item.name == picked; })[0]
			|| groups.filter(function(item) { return item.name == status.profile.main_group; })[0]
			|| groups[0];
		var selectable = api.isSelector(group.type);
		var now = group.now || '';
		var member = (group.members || []).filter(function(item) { return item.name == now; })[0];
		var display = member ? member.label : (group.now_label || _('Not selected'));
		var via = member && member.via_label ? member.via_label : (group.now_via_label || '');
		var testing = !!group.testing;
		var testBtn = api.pressable('ecycloud-icon-btn' + (testing ? ' is-testing' : ''), {
			title: _('Test all nodes in this group'),
			'aria-label': _('Test all nodes in this group'),
			'data-ico': 'bolt'
		});
		var chips = [];

		if (member && !member.is_group)
			[ member.protocol, (member.network || '').toUpperCase(), member.tls, member.udp ].forEach(function(tag) {
				if (tag)
					chips.push(E('span', { 'class': 'ecycloud-tag' }, [ tag ]));
			});

		testBtn.addEventListener('click', function() {
			if (group.testing)
				return;

			testBtn.classList.add('is-testing');
			api.testGroup(group).then(function(res) {
				if (res && !res.ok)
					api.notify(res);
				return self.refresh();
			});
		});

		var groupSelect = api.dropdown(
			groups.map(function(item) {
				return { value: item.name, label: item.name };
			}),
			group.name,
			function(name) {
				self.pickedGroup = name;
				self.update(self.cache);
			},
			{ disabled: status.route_mode == 'global' }
		);

		var nodeItems = (group.members || []).map(function(item) {
			return {
				value: item.name,
				label: item.label,
				delay: item.delay,
				failed: item.failed,
				testing: item.testing
			};
		});
		var nodeSelect = api.dropdown(
			nodeItems,
			now,
			L.bind(function(name) {
				return api.select(group.name, name).then(L.bind(function(res) {
					if (res && !res.ok)
						api.notify(res);
					return this.refresh();
				}, this));
			}, this),
			{
				disabled: !selectable || !nodeItems.length,
				placeholder: _('Not selected')
			}
		);

		return api.section('tower', _('Current node'), E('div', {}, [
			E('div', { 'class': 'ecycloud-now' }, [
				E('div', { 'class': 'ecycloud-now-info' }, [
					E('div', { 'class': 'ecycloud-now-name' }, [ display ]),
					via ? E('div', { 'class': 'ecycloud-node-via' }, [ via ])
						: (chips.length ? E('div', { 'class': 'ecycloud-tags' }, chips) : '')
				]),
				member ? api.delayBadge(member, function() {
					var leaf = member.via || member.name;
					if (!leaf)
						return;
					api.delay(leaf).then(function(res) {
						if (res && !res.ok)
							api.notify(res);
						return self.refresh();
					});
				}) : ''
			]),
			E('div', { 'class': 'ecycloud-gap' }),
			api.pair(
				E('div', { 'class': 'ecycloud-field' }, [
					E('label', {}, [ _('Proxy group') ]),
					groupSelect
				]),
				E('div', { 'class': 'ecycloud-field' }, [
					E('label', {}, [ _('Node') ]),
					nodeSelect
				])
			)
		]), E('div', { 'class': 'ecycloud-card-actions' }, [
			testBtn,
			api.jump(api.page('nodes'), _('Nodes'))
		]));
	},

	renderToggles: function(status) {
		var running = status.running;
		var tun = status.mode == 'tun';
		var hijack = !!status.dns_hijack;

		return api.card([
			E('div', { 'class': 'ecycloud-toggles' }, [
				this.renderToggle('dns', _('Hijack DNS'), running
					? (status.dns_applied
						? _('dnsmasq forwards to the kernel')
						: _('Waiting for the kernel'))
					: _('Used only while running'), hijack, L.bind(function(on) {
					return this.saveOption('dns_hijack', on ? '1' : '0');
				}, this)),
				this.renderToggle('lan', _('TUN mode'), running
					? _('Take over all forwarded traffic')
					: _('Used only while running'), tun, L.bind(function(on) {
					return this.saveOption('mode', on ? 'tun' : 'tproxy');
				}, this))
			])
		], 'ecycloud-toggles');
	},

	renderToggle: function(icon, title, subtitle, checked, onChange) {
		var input = E('input', { 'type': 'checkbox' });
		input.checked = checked;
		input.addEventListener('change', ui.createHandlerFn(this, function() {
			return onChange(input.checked);
		}));

		return E('label', { 'class': 'ecycloud-toggle' }, [
			E('span', { 'class': 'ecycloud-ico' + (checked ? ' is-on' : ''), 'data-ico': icon }),
			E('div', { 'class': 'ecycloud-toggle-text' }, [
				E('div', { 'class': 'ecycloud-toggle-title' }, [ title ]),
				E('div', { 'class': 'ecycloud-toggle-sub' }, [ subtitle ])
			]),
			E('span', { 'class': 'ecycloud-switch' }, [
				input,
				E('span', { 'class': 'ecycloud-switch-ui' })
			])
		]);
	},

	renderTraffic: function(status) {
		var traffic = this.traffic || { up: 0, down: 0, totalUp: 0, totalDown: 0, historyUp: [], historyDown: [] };
		var live = api.phase(status) == 'connected';

		return api.pair(
			api.section('north', _('Upload'), E('div', {}, [
				E('div', { 'class': 'ecycloud-speed' }, [ live ? api.speed(traffic.up) : '—' ]),
				E('div', { 'class': 'ecycloud-speed-total' }, [
					_('Total %s').format(api.bytes(traffic.totalUp))
				]),
				api.sparkline(traffic.historyUp, '#e0a800')
			])),
			api.section('south', _('Download'), E('div', {}, [
				E('div', { 'class': 'ecycloud-speed' }, [ live ? api.speed(traffic.down) : '—' ]),
				E('div', { 'class': 'ecycloud-speed-total' }, [
					_('Total %s').format(api.bytes(traffic.totalDown))
				]),
				api.sparkline(traffic.historyDown, '#0071e3')
			]))
		);
	},

	renderRankList: function(title, rows) {
		if (!rows.length)
			return E('div', {}, [
				E('div', { 'class': 'ecycloud-metric-label' }, [ title ]),
				E('div', { 'class': 'ecycloud-hint' }, [ _('No ranking data yet') ])
			]);

		return E('div', {}, [
			E('div', { 'class': 'ecycloud-metric-label' }, [ title ])
		].concat(rows.map(function(row) {
			return bar(row.name, api.bytesCompact(row.bytes), rows[0].bytes > 0
				? row.bytes / rows[0].bytes : 0, 'primary');
		})));
	},

	renderTrafficRank: function() {
		var self = this;
		var day = this.rankDay || 'today';
		var data = api.trafficRank(day, api.rankSkip(this.cache && this.cache.status));

		return api.section('history', _('Traffic ranking'), E('div', {}, [
			E('div', { 'class': 'ecycloud-rank-switch' }, [
				api.segments([
					{ value: 'today', label: _('Today') },
					{ value: 'yesterday', label: _('Yesterday') }
				], day, function(next) {
					self.rankDay = next;
					self.paint();
				})
			]),
			api.pair(
				this.renderRankList(_('Policy groups'), data.groups),
				this.renderRankList(_('Domains / IPs'), data.hosts)
			)
		]));
	},

	renderKernel: function(status) {
		var live = api.phase(status) == 'connected';
		var closed = api.ingestConnections(this.cache.connections).closed.length;
		var active = status.traffic.connections || 0;

		function metric(icon, label, value, liveValue) {
			return E('div', {}, [
				E('div', { 'class': 'ecycloud-metric-label' }, [
					E('span', { 'class': 'ecycloud-ico', 'data-ico': icon }),
					label
				]),
				E('div', { 'class': 'ecycloud-metric-value' + (liveValue ? ' is-live' : '') }, [ value ])
			]);
		}

		return api.section('board', _('Kernel status'), E('div', { 'class': 'ecycloud-metrics' }, [
			metric('memory', _('Memory'), live ? api.bytes(status.memory) : '—'),
			metric('swap', _('Active connections'), live ? String(active) : '—', live && active > 0),
			metric('history', _('Closed connections'), live ? String(closed) : '—')
		]));
	},

	renderUsage: function(status) {
		var account = status.account || {};
		var used = (account.upload || 0) + (account.download || 0);
		var today = Math.max(0, used - (account.last_day_t || 0));
		var previous = account.last_day_t || 0;
		var remain = (account.transfer_enable || 0) - used;
		var total = account.transfer_enable || 0;
		var ratio = function(value) {
			return total <= 0 ? 0 : Math.max(0, Math.min(1, value / total));
		};
		var lastUsed = account.last_ss_time || _('Never used');
		var self = this;
		var refreshBtn = api.pressable('ecycloud-icon-btn' + (this.refreshingProfile ? ' is-refreshing' : ''), {
			title: _('Refresh profile'),
			'aria-label': _('Refresh profile')
		});

		refreshBtn.addEventListener('click', function() {
			if (self.refreshingProfile)
				return;

			self.refreshingProfile = true;
			refreshBtn.classList.add('is-refreshing');
			api.refreshAccount().then(function(res) {
				if (res && !res.ok)
					api.notify(res);
			}).finally(function() {
				self.refreshingProfile = false;
				return self.refresh();
			});
		});

		return api.section('chart', _('Traffic usage'), E('div', {}, [
			bar(_('Today used'), api.bytesCompact(today), ratio(today), 'danger'),
			bar(_('Previously used'), api.bytesCompact(previous), ratio(previous), 'warning'),
			bar(_('Remaining traffic'), api.bytesCompact(remain > 0 ? remain : 0),
				ratio(remain > 0 ? remain : 0), remain < 0 ? 'danger' : 'success'),
			E('div', { 'class': 'ecycloud-usage-total' }, [
				E('span', {}, [ _('Account total traffic') ]),
				E('span', { 'class': 'ecycloud-chip is-primary' }, [ api.bytesCompact(total) ])
			]),
			E('div', { 'class': 'ecycloud-hint' }, [
				status.site
					? E('a', {
						'class': 'ecycloud-link',
						'href': status.site.replace(/\/$/, '') + '/user/shop?tab=traffic',
						'target': '_blank',
						'rel': 'noreferrer'
					}, [ _('Need more traffic? Open the panel to buy a traffic pack') ])
					: _('Need more traffic? Open the panel to buy a traffic pack')
			]),
			E('div', { 'class': 'ecycloud-meta' }, [
				E('span', {}, [ _('Next usage reset') ]),
				E('span', {}, [ account.traffic_reset || '—' ])
			]),
			E('div', { 'class': 'ecycloud-meta' }, [
				E('span', {}, [ _('Last used') ]),
				E('span', {}, [ lastUsed ])
			])
		]), E('div', { 'class': 'ecycloud-card-actions' }, [
			refreshBtn,
			status.site
				? api.jump(status.site.replace(/\/$/, '') + '/user/trafficlog',
					_('Traffic details'), { external: true })
				: ''
		]));
	},

	renderLogin: function(status) {
		var view = this;
		var emailCodeMode = false;
		var showTotp = false;
		var cooldown = 0;
		var timer = null;
		var saved = null;
		var site = (status && status.site) || '';

		try {
			saved = JSON.parse(window.localStorage.getItem(REMEMBER) || 'null');
		}
		catch (e) {
			saved = null;
		}

		var brandName = E('div', { 'class': 'ecycloud-login-name' }, [ 'ECY Cloud' ]);
		var title = E('div', { 'class': 'ecycloud-login-brand' }, [
			E('img', {
				'class': 'ecycloud-login-mark',
				'src': L.resource('view/ecycloud/app_icon.png'),
				'width': 56,
				'height': 56,
				'alt': ''
			}),
			brandName
		]);
		var descr = E('div', { 'class': 'cbi-section-descr' }, [ loginHint(status && status.site) ]);
		this.loginHint = descr;
		var email = api.input({ type: 'text', autocomplete: 'username' });
		var password = api.input({ type: 'password', autocomplete: 'current-password' });
		var totp = api.input({ type: 'text', autocomplete: 'one-time-code' });
		var verify = api.input({ type: 'text', autocomplete: 'one-time-code' });
		var rememberOn = !!(saved && saved.email);
		var remember = api.pressable('ecycloud-login-remember', {
			'aria-pressed': rememberOn ? 'true' : 'false'
		}, [
			E('span', { 'class': 'ecycloud-login-check', 'aria-hidden': 'true' }),
			_('Remember email and password')
		]);
		var sendBtn = api.pressable('ecycloud-login-send', {}, [ _('Send code') ]);
		var switchBtn = api.pressable('ecycloud-login-textbtn', {}, [ _('Email code sign-in') ]);
		var submitBtn = api.pressable('ecycloud-login-submit', {}, [ _('Sign in') ]);
		var registerLink = E('a', {
			'class': 'ecycloud-login-textbtn',
			'href': siteHref(site, '/auth/register'),
			'target': '_blank',
			'rel': 'noreferrer'
		}, [ _('Create an account') + ' ›' ]);
		var forgotLink = E('a', {
			'class': 'ecycloud-login-textbtn',
			'href': siteHref(site, '/password/reset'),
			'target': '_blank',
			'rel': 'noreferrer'
		}, [ _('Forgot password?') ]);

		var emailRow = loginField(_('Email'), [ email ]);
		var passwordRow = loginField(_('Password'), [ password ]);
		var totpRow = loginField(_('Two-factor code'), [ totp ]);
		var verifyRow = loginField(_('Verification code'), [
			E('div', { 'class': 'ecycloud-login-code' }, [ verify, sendBtn ])
		]);
		var tools = E('div', { 'class': 'ecycloud-login-tools' }, [
			remember,
			switchBtn
		]);
		var links = E('div', { 'class': 'ecycloud-login-links' }, [ registerLink, forgotLink ]);
		this.loginRegister = registerLink;
		this.loginForgot = forgotLink;

		if (saved && saved.email) {
			email.value = saved.email;
			password.value = saved.password || '';
		}

		var paintSend = function() {
			sendBtn.disabled = cooldown > 0;
			sendBtn.textContent = cooldown > 0 ? _('Send code (%ds)').format(cooldown) : _('Send code');
		};

		var paintScreen = function() {
			descr.textContent = loginHint((view.cache && view.cache.status && view.cache.status.site) || site);
			passwordRow.style.display = emailCodeMode ? 'none' : '';
			verifyRow.style.display = emailCodeMode ? '' : 'none';
			totpRow.style.display = showTotp && !emailCodeMode ? '' : 'none';
			remember.classList.toggle('ecycloud-hidden', emailCodeMode);
		};

		var setEmailCode = function(next) {
			emailCodeMode = next;
			showTotp = false;
			switchBtn.textContent = emailCodeMode ? _('Password sign-in') : _('Email code sign-in');
			paintScreen();
		};

		paintScreen();

		sendBtn.addEventListener('click', ui.createHandlerFn(this, function() {
			var address = email.value.trim();

			if (!address) {
				api.alert(_('Enter your email first'));
				return;
			}

			if (cooldown > 0)
				return;

			return api.sendLoginVerify(address).then(function(res) {
				api.notify(res, _('A verification code has been sent to your email'));

				if (!res.ok)
					return;

				cooldown = 60;
				paintSend();
				clearInterval(timer);
				timer = setInterval(function() {
					cooldown -= 1;
					if (cooldown <= 0) {
						clearInterval(timer);
						cooldown = 0;
					}
					paintSend();
				}, 1000);
			});
		}));

		switchBtn.addEventListener('click', function(ev) {
			ev.preventDefault();
			setEmailCode(!emailCodeMode);
		});

		var rememberChecked = function() {
			return remember.getAttribute('aria-pressed') == 'true';
		};

		remember.addEventListener('click', function(ev) {
			ev.preventDefault();
			var next = !rememberChecked();
			remember.setAttribute('aria-pressed', next ? 'true' : 'false');
			if (!next)
				window.localStorage.removeItem(REMEMBER);
		});

		var submit = ui.createHandlerFn(this, function() {
			var address = email.value.trim();

			var request = emailCodeMode
				? api.loginCode(address, verify.value.trim())
				: api.login(address, password.value, totp.value);

			return request.then(L.bind(function(res) {
				api.notify(res, _('Signed in'));

				if (!emailCodeMode && res.need_code) {
					showTotp = true;
					paintScreen();
					totp.focus();
					return;
				}

				if (res.ok && !emailCodeMode) {
					if (rememberChecked())
						window.localStorage.setItem(REMEMBER, JSON.stringify({
							email: address,
							password: password.value
						}));
					else
						window.localStorage.removeItem(REMEMBER);
				}

				if (!res.ok)
					return null;

				this.signedIn = { email: address };
				this.showLogin(false);
				return this.refresh(true);
			}, this));
		});

		submitBtn.addEventListener('click', submit);
		[ email, password, verify ].forEach(function(input) {
			input.addEventListener('keydown', function(ev) {
				if (ev.key != 'Enter')
					return;
				ev.preventDefault();
				ev.stopPropagation();
				submit(ev);
			});
			input.addEventListener('keypress', function(ev) {
				if (ev.key == 'Enter') {
					ev.preventDefault();
					ev.stopPropagation();
				}
			});
		});

		return E('div', { 'class': 'cbi-section ecycloud-login' }, [
			E('div', { 'class': 'ecycloud-login-body' }, [
				title,
				descr,
				emailRow,
				passwordRow,
				verifyRow,
				totpRow,
				tools,
				submitBtn,
				links
			])
		]);
	},

	render: function(reply) {
		var self = this;

		return api.ensureStyle().then(function() {
			self.body = E('div', {});
			self.loginBox = self.renderLogin((reply && reply.status) || reply || {});
			self.update(reply);
			poll.add(L.bind(self.refresh, self), 5);
			if (!self._onVis) {
				self._onVis = function() {
					if (!document.hidden && self.body && self.body.isConnected)
						self.refresh();
				};
				document.addEventListener('visibilitychange', self._onVis);
			}
			self.timer = setInterval(function() {
				if (!self.cache || !self.body || !self.body.isConnected)
					return;

				var phase = api.phase(self.cache.status);

				if (phase == 'connecting' || phase == 'disconnecting') {
					self.refresh();
					return;
				}

				if (!self.durationNode || !self.cache.status.running)
					return;

				if (api.phase(self.cache.status) == 'connected')
					self.durationNode.textContent = _('Connected %s').format(
						api.elapsed(api.connectedSince(true)));
			}, 1000);
			return api.shell([ self.body, self.loginBox ]);
		});
	}
});
