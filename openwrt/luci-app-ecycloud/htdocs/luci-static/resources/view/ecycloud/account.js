'use strict';
'require view';
'require dom';
'require poll';
'require ui';
'require ecycloud.api as api';

function emptyUsage() {
	return {
		items: [],
		log_keep_days: 1,
		current_page: 1,
		last_page: 1,
		total: 0
	};
}

return view.extend({
	handleSave: null,
	handleSaveApply: null,
	handleReset: null,

	load: function() {
		return this.fetch(true);
	},

	refresh: function() {
		return this.fetch(false).then(L.bind(this.update, this));
	},

	fetch: function(freshAccount) {
		var page = this.page || 1;

		return api.status().then(function(status) {
			if (!api.signedIn(status))
				return { status: status, usage: emptyUsage() };

			var start = freshAccount
				? api.refreshAccount().then(function() {
					return api.status();
				}, function() {
					return api.status();
				})
				: Promise.resolve(status);

			return start.then(function(next) {
				return api.devices(page, 100).then(function(res) {
					return { status: next, usage: res || emptyUsage() };
				}, function() {
					return { status: next, usage: emptyUsage() };
				});
			});
		});
	},

	update: function(data) {
		this.status = Object.assign({ session: {}, account: {} }, data.status || data);
		if (data.usage)
			this.usage = data.usage;
		if (!this.usage)
			this.usage = emptyUsage();
		this.paint();
	},

	confirmKick: function(item) {
		var self = this;
		var label = item.device || item.ip;

		return api.dialog({
			title: _('Remove this device?'),
			text: _('The client on %s will be told to disconnect, within 60 seconds.').format(label),
			cancel: true,
			ok: _('OK')
		}).then(function(ok) {
			if (ok !== true)
				return;

			return api.kickDevice(item.device_id).then(function(res) {
				api.notify(res, res.msg || _('Request failed'));
				return self.fetch(true).then(L.bind(self.update, self));
			});
		});
	},

	renderDevices: function() {
		var self = this;
		var usage = this.usage || emptyUsage();
		var items = usage.items || [];

		if (!items.length)
			return E('div', { 'class': 'ecycloud-empty' }, [
				_('No online clients in the last %d days').format(usage.log_keep_days || 1)
			]);

		var selfId = (this.status && this.status.session && this.status.session.device_id) || '';

		return E('div', { 'class': 'ecycloud-list' }, items.map(function(item) {
			var official = !!(item.device);
			var kickable = !!(official && item.online && item.device_id);
			var current = !!(official && item.device_id && item.device_id === selfId);
			var action = kickable
				? api.pressable('ecycloud-jump is-danger', {}, [ _('Remove') ])
				: E('span', { 'class': 'ecycloud-row-sub' }, [
					official ? '' : _('Not supported')
				]);

			if (kickable)
				action.addEventListener('click', function() {
					self.confirmKick(item);
				});

			var when = [];
			if (item.datetime)
				when.push(item.datetime);
			if (item.app_version)
				when.push(item.app_version);

			return E('div', { 'class': 'ecycloud-row' + (item.online ? '' : ' is-closed') }, [
				E('div', { 'class': 'ecycloud-row-main' }, [
					E('div', { 'class': 'ecycloud-row-title' }, [
						E('span', { 'class': 'ecycloud-dot' }),
						E('span', { 'class': 'ecycloud-row-host' }, [ item.ip || '—' ])
					]),
					E('div', { 'class': 'ecycloud-row-tags' }, [
						E('span', { 'class': 'ecycloud-row-sub' }, [
							api.deviceLabel(item)
						]),
						current
							? E('span', { 'class': 'ecycloud-tag' }, [ _('This device') ])
							: ''
					]),
					item.location
						? E('div', { 'class': 'ecycloud-row-sub' }, [ item.location ])
						: '',
					when.length
						? E('div', { 'class': 'ecycloud-row-sub' }, [ when.join(' · ') ])
						: ''
				]),
				E('div', { 'class': 'ecycloud-row-side' }, [ action ])
			]);
		}));
	},

	paint: function() {
		var status = this.status;
		var account = status.account || {};
		var usage = this.usage || emptyUsage();
		var self = this;
		var signedIn = !!(status.session && status.session.logged_in);
		var refreshBtn = api.pressable('ecycloud-icon-btn' + (this.refreshingProfile ? ' is-refreshing' : ''), {
			title: _('Refresh profile'),
			'aria-label': _('Refresh profile')
		});

		refreshBtn.addEventListener('click', function() {
			if (self.refreshingProfile)
				return;

			self.refreshingProfile = true;
			refreshBtn.classList.add('is-refreshing');
			self.fetch(true).then(function(data) {
				self.update(data);
			}).finally(function() {
				self.refreshingProfile = false;
				self.paint();
			});
		});

		var logout = signedIn
			? api.pressable('ecycloud-jump is-danger', {
				click: ui.createHandlerFn(this, function() {
					return api.dialog({
						title: _('Sign out'),
						text: _('This disconnects and clears saved sign-in credentials on this device.'),
						cancel: true,
						ok: _('Quit')
					}).then(function(ok) {
						if (ok !== true)
							return;

						return api.logout().then(function(res) {
							api.notify(res, _('Signed out'));
							window.location = api.page('overview');
						});
					});
				})
			}, [ _('Sign out') ])
			: '';

		var info = [
			E('div', { 'class': 'ecycloud-meta' }, [
				E('span', {}, [ _('Account') ]),
				E('span', {}, [ account.email || (status.session && status.session.email) || '—' ])
			]),
			E('div', { 'class': 'ecycloud-meta' }, [
				E('span', {}, [ _('Plan') ]),
				E('span', {}, [ account.plan
					? _('%s, %d days left').format(account.plan, account.plan_days)
					: _('no active plan') ])
			]),
			E('div', { 'class': 'ecycloud-meta' }, [
				E('span', {}, [ _('Expires') ]),
				E('span', {}, [ account.expire_in || '—' ])
			])
		];

		if (signedIn)
			info.push(E('div', { 'class': 'ecycloud-meta' }, [
				E('span', {}, [ _('Online clients') ]),
				E('span', {}, [ api.onlineDeviceText(account) ])
			]));

		var cards = [
			api.section('', _('Account info'), E('div', {}, info),
				logout ? E('div', { 'class': 'ecycloud-card-actions' }, [ logout ]) : '')
		];

		if (signedIn)
			cards.push(api.section('', _('Online clients in the last %d days').format(usage.log_keep_days || 1), E('div', {}, [
				E('div', { 'class': 'ecycloud-hint' }, [
					_('Confirm these IPs are yours. Change your password if anything looks wrong.')
				]),
				this.renderDevices()
			])));

		dom.content(this.body, E('div', {}, [
			E('div', { 'class': 'ecycloud-toolbar is-end' }, [ refreshBtn ]),
			E('div', { 'class': 'ecycloud-home' }, cards)
		]));
	},

	render: function(data) {
		var self = this;

		return api.ensureStyle().then(function() {
			if (!api.signedIn(data && data.status))
				return api.shell([ api.signedOut() ], true);

			self.body = E('div', {});
			self.update(data);
			poll.add(L.bind(self.refresh, self), 30);
			return api.shell([ self.body ]);
		});
	}
});
