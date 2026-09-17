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
		this.error = (data[1] && data[1].error) || '';
		this.paint();
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
			dom.content(this.body, E('div', { 'class': 'ecycloud-empty' }, [ this.error ]));
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

		if (network)
			chips.push(E('span', { 'class': 'ecycloud-tag' }, [ network ]));

		if (out)
			chips.push(E('span', { 'class': 'ecycloud-tag' }, [ out ]));

		if (process)
			chips.push(E('span', { 'class': 'ecycloud-tag' }, [ process ]));

		if (item.rule)
			chips.push(E('span', { 'class': 'ecycloud-row-sub' }, [ item.rule ]));

		return E('div', { 'class': 'ecycloud-row' + (row.active ? '' : ' is-closed') }, [
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
