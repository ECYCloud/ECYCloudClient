'use strict';
'require view';
'require dom';
'require poll';
'require ui';
'require ecycloud.api as api';

function row(label, value) {
	return E('div', { 'class': 'tr' }, [
		E('div', { 'class': 'td left', 'width': '33%' }, [ label ]),
		E('div', { 'class': 'td left' }, value)
	]);
}

function section(title, rows) {
	return E('div', { 'class': 'cbi-section' }, [
		E('h3', {}, [ title ]),
		E('div', { 'class': 'table' }, rows)
	]);
}

return view.extend({
	handleSave: null,
	handleSaveApply: null,
	handleReset: null,

	load: function() {
		return api.status();
	},

	act: function(promise, success) {
		return promise.then(L.bind(function(res) {
			api.notify(res || {}, success);
			return this.refresh();
		}, this));
	},

	refresh: function() {
		return api.status().then(L.bind(this.update, this));
	},

	update: function(reply) {
		/* ubus 调用被 ACL 挡掉或会话过期时 reply 是空对象，补齐嵌套段避免整页白屏 */
		var status = Object.assign({
			session: {}, account: {}, profile: {}, traffic: {}, lan: []
		}, reply);

		dom.content(this.body, this.renderStatus(status));
		this.loginBox.style.display = status.session.logged_in ? 'none' : '';
	},

	renderStatus: function(status) {
		var nodes = [ section(_('Service'), [
			row(_('Status'), [
				api.stageText(status),
				status.error ? E('div', { 'class': 'alert-message warning' }, [ status.error ])
					: (status.message ? E('div', {}, [ status.message ]) : '')
			]),
			row(_('Kernel'), [ status.running
				? _('Running (%s)').format(status.kernel_version || _('unknown version'))
				: _('Not running') ]),
			row(_('Proxy mode'), [ status.mode == 'tun' ? _('TUN') : _('TPROXY') ]),
			row(_('Routing'), [ this.renderMode(status) ]),
			row(_('Firewall rules'), [ status.network_applied ? _('Applied') : _('Not applied') ]),
			row(_('DNS hijack'), [ status.dns_hijack
				? (status.dns_applied ? _('dnsmasq forwards to the kernel') : _('Waiting for the kernel'))
				: _('Disabled') ]),
			row(_('LAN devices'), [ status.lan.length ? status.lan.join(', ') : _('none') ]),
			row(_('Connections'), [ '%d'.format(status.traffic.connections) ]),
			row(_('Traffic since start'), [ _('%s up / %s down').format(
				api.bytes(status.traffic.upload), api.bytes(status.traffic.download)) ]),
			row(_('Profile'), [ status.profile.revision
				? _('%d nodes, fetched %s').format(status.profile.nodes, api.timestamp(status.profile.fetched_at))
				: _('not fetched yet') ]),
			row(_('Plugin version'), [ status.version || '-' ])
		]) ];

		if (status.session.logged_in) {
			nodes.push(this.renderAccount(status));
			nodes.push(this.renderActions(status));
		}

		return nodes;
	},

	renderAccount: function(status) {
		var account = status.account || {};
		var used = (account.upload || 0) + (account.download || 0);
		var today = Math.max(0, used - (account.last_day_t || 0));

		return section(_('Account'), [
			row(_('Account'), [ account.email || status.session.email || '-' ]),
			row(_('Plan'), [ account.plan
				? _('%s, %d days left').format(account.plan, account.plan_days)
				: _('no active plan') ]),
			row(_('Expires'), [ account.expire_in || '-' ]),
			row(_('Traffic'), [ _('%s used of %s, %s today').format(
				api.bytes(used), api.bytes(account.transfer_enable), api.bytes(today)) ]),
			row(_('Panel'), [ status.site
				? E('a', { 'href': status.site, 'target': '_blank', 'rel': 'noreferrer' }, [ status.site ])
				: '-' ])
		]);
	},

	renderMode: function(status) {
		var select = E('select', { 'class': 'cbi-input-select' }, [
			E('option', { 'value': 'rule' }, [ _('Rule') ]),
			E('option', { 'value': 'global' }, [ _('Global') ]),
			E('option', { 'value': 'direct' }, [ _('Direct') ])
		]);

		select.value = status.route_mode;
		select.addEventListener('change', ui.createHandlerFn(this, function(ev) {
			return this.act(api.mode(ev.target.value), _('Routing mode updated'));
		}));

		return select;
	},

	renderActions: function(status) {
		var toggle = status.enabled
			? E('button', {
				'class': 'btn cbi-button cbi-button-reset',
				'click': ui.createHandlerFn(this, function() {
					return this.act(api.stop(), _('Service stopped'));
				})
			}, [ _('Stop') ])
			: E('button', {
				'class': 'btn cbi-button cbi-button-apply',
				'click': ui.createHandlerFn(this, function() {
					return this.act(api.start(), _('Service starting'));
				})
			}, [ _('Start') ]);

		return E('div', { 'class': 'cbi-page-actions' }, [
			toggle,
			E('button', {
				'class': 'btn cbi-button cbi-button-action',
				'click': ui.createHandlerFn(this, function() {
					return this.act(api.update(), _('Fetching the profile in the background'));
				})
			}, [ _('Refresh profile') ]),
			E('button', {
				'class': 'btn cbi-button cbi-button-remove',
				'click': ui.createHandlerFn(this, function() {
					return this.act(api.logout(), _('Signed out'));
				})
			}, [ _('Sign out') ])
		]);
	},

	renderLogin: function() {
		var email = E('input', { 'type': 'text', 'class': 'cbi-input-text', 'autocomplete': 'username' });
		var password = E('input', { 'type': 'password', 'class': 'cbi-input-password', 'autocomplete': 'current-password' });
		var code = E('input', { 'type': 'text', 'class': 'cbi-input-text', 'autocomplete': 'one-time-code' });
		var codeRow = E('div', { 'class': 'cbi-value' }, [
			E('label', { 'class': 'cbi-value-title' }, [ _('Two-factor code') ]),
			E('div', { 'class': 'cbi-value-field' }, [ code ])
		]);

		codeRow.style.display = 'none';

		var submit = ui.createHandlerFn(this, function() {
			return api.login(email.value, password.value, code.value).then(L.bind(function(res) {
				api.notify(res, _('Signed in, the service is starting'));

				if (res.need_code) {
					codeRow.style.display = '';
					code.focus();
				}
				else if (res.ok) {
					password.value = '';
					code.value = '';
					codeRow.style.display = 'none';
				}

				return this.refresh();
			}, this));
		});

		password.addEventListener('keydown', function(ev) {
			if (ev.key == 'Enter')
				submit(ev);
		});

		return E('div', { 'class': 'cbi-section' }, [
			E('h3', {}, [ _('Sign in') ]),
			E('div', { 'class': 'cbi-section-descr' }, [
				_('Use the account of the panel this plugin was built for. Signing in enables the service.')
			]),
			E('div', { 'class': 'cbi-value' }, [
				E('label', { 'class': 'cbi-value-title' }, [ _('Email') ]),
				E('div', { 'class': 'cbi-value-field' }, [ email ])
			]),
			E('div', { 'class': 'cbi-value' }, [
				E('label', { 'class': 'cbi-value-title' }, [ _('Password') ]),
				E('div', { 'class': 'cbi-value-field' }, [ password ])
			]),
			codeRow,
			E('div', { 'class': 'cbi-page-actions' }, [
				E('button', { 'class': 'btn cbi-button cbi-button-apply', 'click': submit }, [ _('Sign in') ])
			])
		]);
	},

	render: function(status) {
		this.body = E('div', {});
		this.loginBox = this.renderLogin();

		this.update(status);

		poll.add(L.bind(this.refresh, this), 5);

		return E('div', {}, [ this.body, this.loginBox ]);
	}
});
