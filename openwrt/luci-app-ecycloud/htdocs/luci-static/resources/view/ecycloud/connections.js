'use strict';
'require view';
'require dom';
'require poll';
'require ecycloud.api as api';

function haystack(item) {
	return [
		item.host, item.destination_ip, item.destination_port,
		item.process, item.rule, item.network, item.inbound
	].concat(item.chains || []).join(' ').toLowerCase();
}

function target(item) {
	var host = String(item.host || '').trim();
	var ip = String(item.destination_ip || '').trim();
	var port = String(item.destination_port || '').trim();
	var address = host || ip || '—';

	return port ? address + ':' + port : address;
}

function outbound(item) {
	var chains = item.chains || [];

	return chains.length ? chains.slice().reverse().join(' → ') : '';
}

function startedAt(item) {
	return Date.parse(item.start || '') || 0;
}

function lifetime(item, active) {
	var start = startedAt(item);
	var end = active ? Date.now() : (Date.parse(item.closed_at || '') || Date.now());

	return start ? api.duration(end - start) : '';
}

function text(value) {
	return String(value || '').trim();
}

function connectedAt(item) {
	var start = startedAt(item);
	var date = new Date(start);

	return start
		? '%04d-%02d-%02d %s'.format(date.getFullYear(), date.getMonth() + 1, date.getDate(), api.clock(start))
		: '';
}

function detailFields(item, speed) {
	var name = api.processName(item);
	var path = text(item.process_path);
	var network = text(item.network);
	var inbound = text(item.inbound);
	var rule = text(item.rule);
	var payload = text(item.rule_payload);

	return [
		[ _('Host'), target(item) ],
		[ _('Downloaded'), api.bytes(item.download) ],
		[ _('Uploaded'), api.bytes(item.upload) ],
		[ _('Download speed'), api.speed(speed.down) ],
		[ _('Upload speed'), api.speed(speed.up) ],
		[ _('Chain'), outbound(item) ],
		[ _('Rule'), payload ? rule + '(' + payload + ')' : rule ],
		[ _('Process'), !path || path == name ? name : name + ' (' + path + ')' ],
		[ _('Connected at'), connectedAt(item) ],
		[ _('Source address'), api.connectionSource(item) ],
		[ _('Destination address'), text(item.remote_destination) || text(item.destination_ip) ],
		[ _('Destination port'), text(item.destination_port) ],
		[ _('Type'), network ? inbound + '(' + network + ')' : inbound ]
	];
}

return view.extend({
	handleSave: null,
	handleSaveApply: null,
	handleReset: null,

	load: function() {
		return api.status().then(function(status) {
			if (!api.signedIn(status))
				return [ status, { connections: [] } ];

			return api.connections().then(function(conns) {
				return [ status, conns ];
			});
		});
	},

	refresh: function() {
		return this.load().then(L.bind(this.update, this));
	},

	update: function(data) {
		this.signedIn = api.signedIn(data[0]);
		this.running = !!(data[0] && data[0].running);
		this.store = api.ingestConnections((data[1] && data[1].connections) || []);
		this.at = +((data[1] && data[1].at) || 0);
		this.error = (data[1] && data[1].error) || '';
		this.paint();
		this.refreshDetail();
	},

	rows: function() {
		var store = this.store || { active: [], closed: [] };
		var keyword = (this.keyword || '').toLowerCase();
		var scope = this.scope || 'all';
		var list = [];

		if (scope != 'closed')
			store.active.forEach(function(item) {
				list.push({ item: item, active: true });
			});

		if (scope != 'active')
			store.closed.forEach(function(item) {
				list.push({ item: item, active: false });
			});

		if (keyword)
			list = list.filter(function(row) {
				return haystack(row.item).indexOf(keyword) != -1;
			});

		list.sort(function(a, b) {
			return startedAt(b.item) - startedAt(a.item);
		});

		return list;
	},

	matchCount: function(items, keyword) {
		if (!keyword)
			return items.length;

		return items.filter(function(item) {
			return haystack(item).indexOf(keyword) != -1;
		}).length;
	},

	paint: function() {
		if (!this.signedIn) {
			dom.content(this.body, api.signedOut());
			return;
		}

		if (!this.running) {
			dom.content(this.body, E('div', { 'class': 'ecycloud-empty' }, [
				_('Connect to see connection details')
			]));
			this.paintFilter();
			return;
		}

		var rows = this.rows();

		if (this.error && !rows.length) {
			dom.content(this.body, E('div', { 'class': 'ecycloud-empty' }, [ api.messageText(this.error) ]));
			this.paintFilter();
			return;
		}

		if (!rows.length) {
			dom.content(this.body, E('div', { 'class': 'ecycloud-empty' }, [
				_('No matching connections')
			]));
			this.paintFilter();
			return;
		}

		dom.content(this.body, E('div', { 'class': 'ecycloud-list' }, rows.map(L.bind(this.renderRow, this))));
		this.paintFilter();
	},

	paintFilter: function() {
		var store = this.store || { active: [], closed: [] };
		var keyword = (this.keyword || '').toLowerCase();
		var active = this.matchCount(store.active, keyword);
		var closed = this.matchCount(store.closed, keyword);

		dom.content(this.filterBar, api.segments([
			{ value: 'all', label: _('All %d').format(active + closed) },
			{ value: 'active', label: _('Active %d').format(active) },
			{ value: 'closed', label: _('Closed %d').format(closed) }
		], this.scope || 'all', L.bind(function(value) {
			this.scope = value;
			this.paint();
		}, this)));
	},

	renderRow: function(row) {
		var item = row.item;
		var chips = [];
		var network = (item.network || '').toUpperCase();
		var out = outbound(item);
		var process = api.processName(item);
		var time = lifetime(item, row.active);

		if (item.inbound)
			chips.push(E('span', { 'class': 'ecycloud-tag' }, [ item.inbound ]));

		if (network)
			chips.push(E('span', { 'class': 'ecycloud-tag' }, [ network ]));

		if (out)
			chips.push(E('span', { 'class': 'ecycloud-tag' }, [ out ]));

		if (process)
			chips.push(E('span', { 'class': 'ecycloud-tag' }, [ process ]));

		if (item.rule)
			chips.push(E('span', { 'class': 'ecycloud-row-sub' }, [ item.rule ]));

		return E('div', {
			'class': 'ecycloud-row is-clickable' + (row.active ? '' : ' is-closed'),
			'click': L.bind(function() {
				if (!String(window.getSelection() || ''))
					this.openDetail(row);
			}, this)
		}, [
			E('div', { 'class': 'ecycloud-row-main' }, [
				E('div', { 'class': 'ecycloud-row-title' }, [
					E('span', { 'class': 'ecycloud-dot' }),
					E('span', { 'class': 'ecycloud-row-host' }, [ target(item) ])
				]),
				chips.length ? E('div', { 'class': 'ecycloud-row-tags' }, chips) : ''
			]),
			E('div', { 'class': 'ecycloud-row-side' }, [
				E('div', {}, [ '↑ %s　↓ %s'.format(api.bytes(item.upload), api.bytes(item.download)) ]),
				E('div', { 'class': 'ecycloud-row-sub' }, [
					row.active ? time : _('Closed · %s').format(time)
				])
			])
		]);
	},

	openDetail: function(row) {
		var fields = E('div', { 'class': 'ecycloud-modal-fields' });
		var node = E('div', {
			'class': 'ecycloud-modal is-dialog is-detail',
			'data-theme': api.detectTheme()
		});
		var close = function() {
			node.remove();
		};
		var closeBtn = api.pressable('ecycloud-modal-ok', {}, [ _('Close connection') ]);
		var detail = {
			node: node,
			fields: fields,
			closeBtn: closeBtn,
			item: row.item,
			active: row.active,
			at: this.at,
			speed: { up: 0, down: 0 }
		};

		closeBtn.addEventListener('click', function() {
			if (closeBtn.disabled)
				return;

			closeBtn.disabled = true;
			api.closeConnection(detail.item.id).then(function(res) {
				if (res.ok)
					close();
				else
					api.notify(res);
			}).catch(function(err) {
				api.notify({ ok: false, msg: (err && err.message) || _('Request failed') });
			}).finally(function() {
				closeBtn.disabled = false;
			});
		});

		document.querySelectorAll('.ecycloud-modal.is-detail').forEach(function(item) {
			item.remove();
		});
		node.appendChild(E('div', { 'class': 'ecycloud-modal-card is-dialog' }, [
			E('div', { 'class': 'ecycloud-modal-title' }, [ _('Connection details') ]),
			fields,
			E('div', { 'class': 'ecycloud-modal-actions' }, [
				closeBtn,
				api.pressable('ecycloud-modal-cancel', { click: close }, [ _('Close') ])
			])
		]));
		this.detail = detail;
		this.paintDetail();
		api.onBackdrop(node, close);
		document.body.appendChild(node);
		api.isolate(node);
	},

	refreshDetail: function() {
		var detail = this.detail;
		var store = this.store;

		if (!detail)
			return;

		if (!detail.node.isConnected) {
			this.detail = null;
			return;
		}

		if (detail.active && this.at != detail.at) {
			var find = function(list) {
				return list.filter(function(item) {
					return item.id == detail.item.id;
				})[0];
			};
			var live = find(store.active);
			var seconds = this.at - detail.at;

			if (live) {
				if (detail.at > 0 && seconds > 0)
					detail.speed = {
						up: Math.round(Math.max(0, live.upload - detail.item.upload) / seconds),
						down: Math.round(Math.max(0, live.download - detail.item.download) / seconds)
					};
				detail.item = live;
			}
			else {
				detail.item = find(store.closed) || detail.item;
				detail.active = false;
				detail.speed = { up: 0, down: 0 };
			}

			detail.at = this.at;
		}

		this.paintDetail();
	},

	paintDetail: function() {
		var detail = this.detail;

		detail.closeBtn.style.display = detail.active ? '' : 'none';
		dom.content(detail.fields, detailFields(detail.item, detail.speed).map(function(field) {
			return E('div', {}, [
				E('span', { 'class': 'ecycloud-modal-label' }, [ field[0] + ': ' ]),
				field[1] || '—'
			]);
		}));
	},

	render: function(data) {
		var self = this;

		return api.ensureStyle().then(function() {
			if (!api.signedIn(data[0]))
				return api.shell([ api.signedOut() ], true);

			self.keyword = '';
			self.scope = 'all';
			self.body = E('div', {});
			self.filterBar = E('div', {});

			var search = api.input({
				placeholder: _('Search host, IP, process, rule')
			});
			search.addEventListener('input', function() {
				self.keyword = search.value.trim();
				self.paint();
			});

			self.update(data);
			poll.add(L.bind(self.refresh, self), 5);

			return api.shell([
				E('div', { 'class': 'ecycloud-toolbar' }, [ self.filterBar, search ]),
				self.body
			]);
		});
	}
});
