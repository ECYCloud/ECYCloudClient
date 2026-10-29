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

function loginHint(site, status) {
	if (status && status.session && status.session.expired)
		return _('Session expired. Sign in again.');
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
					flag_regex: extra[0].flag_regex || '',
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

		var seq = (this.refreshSeq || 0) + 1;
		var self = this;
		this.refreshSeq = seq;
		return this.loadBundle().then(function(reply) {
			var status = reply && reply.status;
			if (seq != self.refreshSeq)
				return;
			if (api.connectInFlight() && status && status.session && status.session.logged_in &&
				!status.enabled && status.stage != 'failed')
				return;
			return self.update(reply);
		});
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

		status.session.logged_in = api.signedIn(status);
		var previous = this.cache && this.cache.status.session;
		if (previous && previous.id != status.session.id) {
			this.stopAnnounce();
			this.traffic = null;
		}

		this.cache = {
			status: status,
			groups: reply.groups || [],
			flag_regex: reply.flag_regex || '',
			connections: reply.connections || []
		};
		this.warmFlags();
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
			this.loginHint.textContent = loginHint(status.site, status);
		if (this.loginSite)
			this.loginSite.textContent = siteHost(status.site);
		if (this.loginRegister)
			this.loginRegister.href = siteHref(status.site, '/auth/register');
		if (this.loginForgot)
			this.loginForgot.href = siteHref(status.site, '/password/reset');
		if (this.loginTerms)
			this.loginTerms.href = siteHref(status.site, '/tos');
		if (this.loginPrivacy)
			this.loginPrivacy.href = siteHref(status.site, '/privacy');
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
		var stats = (this.cache && this.cache.status && this.cache.status.statistics) || {};
		var traffic = this.traffic || { historyUp: [], historyDown: [] };
		var now = +(stats.at || 0) * 1000;
		traffic.up = running ? +(stats.up || 0) : 0;
		traffic.down = running ? +(stats.down || 0) : 0;
		traffic.totalUp = +(stats.total_up || 0);
		traffic.totalDown = +(stats.total_down || 0);
		if (now > (traffic.at || 0)) {
			traffic.historyUp.push({ at: now, value: traffic.up });
			traffic.historyDown.push({ at: now, value: traffic.down });
			traffic.historyUp = traffic.historyUp.filter(function(item) { return item.at >= now - 60000; });
			traffic.historyDown = traffic.historyDown.filter(function(item) { return item.at >= now - 60000; });
			traffic.at = now;
		}
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

	warmFlags: function() {
		var names = [];
		var generation = (this.flagGeneration || 0) + 1;
		var self = this;

		(this.cache.groups || []).forEach(function(group) {
			(group.members || []).forEach(function(member) {
				if (member.label)
					names.push(member.label);
				if (member.via_label)
					names.push(member.via_label);
			});
		});
		this.flagGeneration = generation;
		return api.warmFlags(names, this.cache.flag_regex).then(function(changed) {
			if (changed && generation == self.flagGeneration && self.body)
				dom.content(self.body, self.renderHome());
		});
	},

	handleCheckin: function() {
		var self = this;

		if (this.checkingIn)
			return;

		this.checkingIn = true;
		this.paint();
		return api.checkin().then(function(res) {
			api.notify(res);
		}).finally(function() {
			self.checkingIn = false;
			return self.refresh();
		});
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
			detail = status.provider_progress && status.provider_progress.total > status.provider_progress.ready
				? _('Loading rule providers: %d/%d').format(status.provider_progress.ready, status.provider_progress.total)
				: status.error || status.message || api.stageText(status);
		else if (phase == 'disconnecting')
			detail = _('Disconnecting, please wait');
		else if (phase == 'failed')
			detail = status.error || _('Failed');

		this.durationNode = E('div', {
			'class': 'ecycloud-status-detail' + (phase == 'failed' ? ' is-err' : '')
		}, [ api.messageText(detail) ]);

		var connectIco = busy ? 'close' : (live ? 'stop' : 'play');
		var content = E('span', { 'class': 'ecycloud-connect-content' }, [
			E('span', {
				'class': 'ecycloud-ico' + (busy ? ' is-spin' : ''),
				'data-ico': connectIco
			}),
			E('span', {}, [
				phase == 'disconnecting' ? _('Disconnecting')
					: phase == 'connecting' ? _('Cancel')
					: live ? _('Disconnect')
					: _('Connect')
			])
		]);
		var connect = api.pressable(
			'ecycloud-btn ' + (live || phase == 'disconnecting' ? 'is-danger' : 'is-cta'),
			{ disabled: phase == 'disconnecting' },
			[ content ]);
		var previous = this.connectButton;
		if (previous && previous.isConnected && this.connectPhase != phase
				&& !window.matchMedia('(prefers-reduced-motion: reduce)').matches) {
			var width = previous.getBoundingClientRect().width;
			var style = window.getComputedStyle(previous);
			var background = style.backgroundColor;
			var foreground = style.color;
			requestAnimationFrame(function() {
				if (!connect.isConnected)
					return;
				var nextStyle = window.getComputedStyle(connect);
				var timing = { duration: 200, easing: 'cubic-bezier(.215,.61,.355,1)' };
				connect.animate([
					{ width: width + 'px', backgroundColor: background, color: foreground },
					{ width: connect.getBoundingClientRect().width + 'px',
						backgroundColor: nextStyle.backgroundColor, color: nextStyle.color }
				], timing);
				content.animate([ { opacity: 0 }, { opacity: 1 } ], timing);
			});
		}
		this.connectButton = connect;
		this.connectPhase = phase;

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
			title: _('Announcement'),
			'aria-label': _('Announcement'),
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
		var flag = api.flagImg(api.flagCode(via || (member ? member.label : '')));
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
				return {
					value: item.name,
					label: item.label || item.name,
					icon: api.groupMark(item.icon, api.isSelector(item.type))
				};
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
				label: api.nodeLabel(item.label),
				delay: item.delay,
				failed: item.failed,
				testing: item.testing,
				icon: api.flagImg(api.flagCode(item.via_label || item.label))
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
					E('div', { 'class': 'ecycloud-now-name' }, [
						via ? '' : (flag || ''),
						E('span', {}, [ api.nodeLabel(display) ])
					]),
					via ? E('div', { 'class': 'ecycloud-node-via' }, [ flag || '', E('span', {}, [ api.nodeLabel(via) ]) ])
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

	renderRankList: function(title, rows, icon) {
		return E('div', {}, [
			E('div', { 'class': 'ecycloud-metric-label ecycloud-rank-title' }, [
				E('span', { 'class': 'ecycloud-ico', 'data-ico': icon }), title
			])
		].concat(rows.length ? rows.map(function(row) {
			return bar(row.name, api.bytesCompact(row.bytes), rows[0].bytes > 0
				? row.bytes / rows[0].bytes : 0, 'primary');
		}) : [ E('div', { 'class': 'ecycloud-hint' }, [ _('No ranking data yet') ]) ]));
	},

	renderTrafficRank: function() {
		var self = this;
		var day = this.rankDay || 'today';
		var data = api.trafficRank(day, api.rankSkip(this.cache && this.cache.status));
		var notice = _('Statistics are stored locally for the last two days, cover only this device, and are not synchronized between devices.');
		var tip = E('span', { 'class': 'ecycloud-rank-tooltip', 'role': 'tooltip', 'id': 'ecycloud-rank-notice' }, [ notice ]);
		var info = api.pressable('ecycloud-icon-btn', { 'aria-label': notice, 'data-ico': 'notice' });
		info.setAttribute('aria-describedby', 'ecycloud-rank-notice');
		info.setAttribute('aria-expanded', 'false');
		var help = E('span', { 'class': 'ecycloud-rank-info' }, [ info, tip ]);
		var closeTimer;
		var hovering = false;
		function position() {
			var available = window.innerWidth - info.getBoundingClientRect().right - 24;
			var below = window.innerWidth <= 600 || available < 180;
			help.classList.toggle('is-below', below);
			help.style.setProperty('--ecy-rank-tip-width', below ? 'none' : available + 'px');
		}
		function close(event) {
			if (event && event.composedPath().indexOf(help) >= 0)
				return;
			clearTimeout(closeTimer);
			help.classList.remove('is-open');
			info.setAttribute('aria-expanded', 'false');
		}
		function show() {
			clearTimeout(closeTimer);
			position();
			help.classList.add('is-open');
			info.setAttribute('aria-expanded', 'true');
		}
		self.closeRankHint = close;
		if (!self._onRankScroll) {
			self._onRankScroll = function() { self.closeRankHint(); };
			document.addEventListener('scroll', self._onRankScroll, true);
			document.addEventListener('pointerdown', function(event) {
				self.closeRankHint(event);
			}, true);
		}
		info.addEventListener('click', function() {
			if (!help.classList.contains('is-open'))
				show();
			else
				close();
		});
		help.addEventListener('mouseenter', function() {
			hovering = true;
			if (window.matchMedia('(hover: hover)').matches)
				show();
		});
		help.addEventListener('mouseleave', function() {
			hovering = false;
			if (window.matchMedia('(hover: hover)').matches)
				closeTimer = setTimeout(close, 100);
		});
		info.addEventListener('focus', position);
		help.addEventListener('focusout', function(event) {
			if (!hovering && event.relatedTarget && !help.contains(event.relatedTarget))
				close();
		});
		info.addEventListener('keydown', function(ev) {
			if (ev.key == 'Escape')
				close();
		});

		return api.section('leaderboard', E('span', {}, [ _('Traffic ranking'), help ]), E('div', {}, [
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
				this.renderRankList(_('Policy groups'), data.groups, 'tune'),
				this.renderRankList(_('Domains / IPs'), data.hosts, 'dns')
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
		var lastUsed = !account.last_ss_time || account.last_ss_time == '从未使用喵'
			? _('Never used') : account.last_ss_time;
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

		return api.section('chart', _('Traffic usage'), E('div', { 'class': 'ecycloud-usage' }, [
			bar(_('Today used'), api.bytesCompact(today), ratio(today), 'danger'),
			bar(_('Previously used'), api.bytesCompact(previous), ratio(previous), 'warning'),
			bar(_('Remaining traffic'), api.bytesCompact(remain > 0 ? remain : 0),
				ratio(remain > 0 ? remain : 0), remain < 0 ? 'danger' : 'success'),
			E('div', { 'class': 'ecycloud-usage-total' }, [
				E('span', {}, [ _('Account total traffic') ]),
				E('span', { 'class': 'ecycloud-chip is-primary' }, [ api.bytesCompact(total) ])
			]),
			E('div', { 'class': 'ecycloud-hint' }, [
				_('Need more traffic? Open '),
				status.site
					? E('a', {
						'class': 'ecycloud-jump',
						'href': status.site.replace(/\/$/, '') + '/user/shop?tab=traffic',
						'target': '_blank',
						'rel': 'noreferrer'
					}, [ _('Shop') + ' ›' ])
					: _('Shop'),
				_(' to buy a traffic pack')
			]),
			E('div', { 'class': 'ecycloud-meta ecycloud-usage-meta' }, [
				E('span', {}, [ E('span', { 'class': 'ecycloud-ico', 'data-ico': 'calendar' }), _('Next usage reset') ]),
				E('span', {}, [ api.messageText(account.traffic_reset || '—') ])
			]),
			E('div', { 'class': 'ecycloud-meta ecycloud-usage-meta' }, [
				E('span', {}, [ E('span', { 'class': 'ecycloud-ico', 'data-ico': 'schedule' }), _('Last used') ]),
				E('span', {}, [ lastUsed ])
			]),
			account.enable_checkin ? E('div', { 'class': 'ecycloud-meta ecycloud-usage-meta' }, [
				E('span', {}, [ E('span', { 'class': 'ecycloud-ico', 'data-ico': 'calendar' }), _('Last check-in') ]),
				E('span', {}, [
					!account.last_check_in_time || account.last_check_in_time == '从未签到'
						? _('Never checked in')
						: account.last_check_in_time
				])
			]) : '',
			account.enable_checkin ? E('div', { 'class': 'ecycloud-checkin' }, [
				E('div', { 'class': 'ecycloud-hint' }, [
					_('Check-in grants %d–%d MB at random').format(account.checkin_min || 1, account.checkin_max || 300)
				]),
				api.pressable('ecycloud-btn', {
					disabled: !account.able_to_checkin || this.checkingIn,
					click: ui.createHandlerFn(this, 'handleCheckin')
				}, [
					E('span', { 'class': 'ecycloud-ico', 'data-ico': 'check' }),
					this.checkingIn
						? _('Check in')
						: (account.able_to_checkin ? _('Check in') : _('Checked in today'))
				])
			]) : ''
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
			if (saved && Object.prototype.hasOwnProperty.call(saved, 'password')) {
				saved = { email: saved.email || '' };
				window.localStorage.setItem(REMEMBER, JSON.stringify(saved));
			}
		}
		catch (e) {
			saved = null;
		}

		var brandName = E('div', { 'class': 'ecycloud-login-name' }, [ 'ECY Cloud' ]);
		var siteName = E('div', { 'class': 'ecycloud-login-site' }, [ siteHost(site) ]);
		var title = E('div', { 'class': 'ecycloud-login-brand' }, [
			E('img', {
				'class': 'ecycloud-login-mark',
				'src': L.resource('view/ecycloud/app_icon.png'),
				'width': 56,
				'height': 56,
				'alt': ''
			}),
			brandName,
			siteName
		]);
		this.loginSite = siteName;
		var descr = E('div', { 'class': 'cbi-section-descr' }, [ loginHint(status && status.site, status) ]);
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
			_('Remember email')
		]);
		var sendBtn = api.pressable('ecycloud-login-send', {}, [ _('Send code') ]);
		var switchBtn = api.pressable('ecycloud-login-alt', {}, [ _('Email code sign-in') ]);
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
		var termsLink = E('a', {
			'class': 'ecycloud-login-textbtn is-muted',
			'href': siteHref(site, '/tos'),
			'target': '_blank',
			'rel': 'noreferrer'
		}, [ _('Terms of Service') ]);
		var privacyLink = E('a', {
			'class': 'ecycloud-login-textbtn is-muted',
			'href': siteHref(site, '/privacy'),
			'target': '_blank',
			'rel': 'noreferrer'
		}, [ _('Privacy Policy') ]);

		var emailRow = loginField(_('Email'), [ email ]);
		var passwordRow = loginField(_('Password'), [ password ]);
		var totpRow = loginField(_('Two-factor code'), [ totp ]);
		var verifyRow = loginField(_('Verification code'), [
			E('div', { 'class': 'ecycloud-login-code' }, [ verify, sendBtn ])
		]);
		var tools = E('div', { 'class': 'ecycloud-login-tools' }, [
			remember,
			forgotLink
		]);
		var links = E('div', { 'class': 'ecycloud-login-links' }, [
			registerLink,
			E('span', { 'class': 'ecycloud-login-legal' }, [ termsLink, privacyLink ])
		]);
		this.loginRegister = registerLink;
		this.loginForgot = forgotLink;
		this.loginTerms = termsLink;
		this.loginPrivacy = privacyLink;

		if (saved && saved.email) {
			email.value = saved.email;
		}

		var paintSend = function() {
			sendBtn.disabled = cooldown > 0;
			sendBtn.textContent = cooldown > 0 ? _('Send code (%ds)').format(cooldown) : _('Send code');
		};

		var paintScreen = function() {
			descr.textContent = loginHint((view.cache && view.cache.status && view.cache.status.site) || site, view.cache && view.cache.status);
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
							email: address
						}));
					else
						window.localStorage.removeItem(REMEMBER);
				}

				if (!res.ok)
					return null;

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
				E('div', { 'class': 'ecycloud-login-form' }, [
					E('div', { 'class': 'ecycloud-login-heading' }, [ _('Sign in') ]),
					descr,
					emailRow,
					passwordRow,
					verifyRow,
					totpRow,
					tools,
					submitBtn,
					switchBtn,
					links
				])
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
