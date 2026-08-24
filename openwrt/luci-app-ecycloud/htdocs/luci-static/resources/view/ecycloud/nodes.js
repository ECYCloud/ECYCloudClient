'use strict';
'require view';
'require dom';
'require poll';
'require ui';
'require ecycloud.api as api';

/* 每次测速都要过 uhttpd → rpcd → curl，路由器上并发压到 4；应用端直连内核用 8 */
var CONCURRENCY = 4;

return view.extend({
	handleSave: null,
	handleSaveApply: null,
	handleReset: null,

	load: function() {
		return api.groups();
	},

	refresh: function() {
		return api.groups().then(L.bind(this.update, this));
	},

	update: function(data) {
		dom.content(this.body, this.renderGroups(data));
	},

	renderGroups: function(data) {
		var groups = data.groups || [];

		if (!groups.length)
			return E('div', { 'class': 'cbi-section' }, [
				E('p', {}, [ data.error || _('The kernel is not running, no proxy group to show.') ])
			]);

		return groups.map(L.bind(this.renderGroup, this));
	},

	renderGroup: function(group) {
		var members = E('div', { 'class': 'table' }, [
			E('div', { 'class': 'tr table-titles' }, [
				E('div', { 'class': 'th', 'width': '5%' }, []),
				E('div', { 'class': 'th left' }, [ _('Node') ]),
				E('div', { 'class': 'th left', 'width': '20%' }, [ _('Type') ]),
				E('div', { 'class': 'th left', 'width': '20%' }, [ _('Latency') ])
			])
		].concat(group.members.map(L.bind(this.renderMember, this, group))));

		var details = E('details', { 'open': this.open[group.name] ? '' : null }, [
			E('summary', {}, [ _('%d members').format(group.members.length) ]),
			members
		]);

		details.addEventListener('toggle', L.bind(function(ev) {
			this.open[group.name] = ev.target.open;
		}, this));

		return E('div', { 'class': 'cbi-section' }, [
			E('h3', {}, [ group.name ]),
			E('div', { 'class': 'cbi-section-descr' }, [
				_('%s, current node: %s').format(
					group.type == 'Selector' ? _('manual') : _('automatic'),
					group.now_label || '-')
			]),
			details,
			E('div', { 'class': 'cbi-page-actions' }, [
				E('button', {
					'class': 'btn cbi-button cbi-button-action',
					'click': ui.createHandlerFn(this, 'handleTest', group)
				}, [ _('Test latency') ])
			])
		]);
	},

	renderMember: function(group, member) {
		var radio = E('input', {
			'type': 'radio',
			'name': 'ecycloud-%s'.format(group.name),
			'value': member.name,
			'checked': member.name == group.now ? '' : null,
			'disabled': group.type == 'Selector' ? null : 'disabled'
		});

		radio.addEventListener('change', ui.createHandlerFn(this, 'handleSelect', group.name, member.name));

		return E('div', { 'class': 'tr' }, [
			E('div', { 'class': 'td', 'width': '5%' }, [ radio ]),
			E('div', { 'class': 'td left' }, [ member.label ]),
			E('div', { 'class': 'td left', 'width': '20%' }, [ member.type ]),
			E('div', { 'class': 'td left', 'width': '20%' }, [ api.delayText(member.delay) ])
		]);
	},

	handleSelect: function(group, member) {
		return api.select(group, member).then(L.bind(function(res) {
			api.notify(res, _('Switched to %s').format(member));
			return this.refresh();
		}, this));
	},

	/* 逐个成员测：整组接口会忽略 urltest 组的 url/timeout，还会静默跳过刚测过的成员 */
	handleTest: function(group) {
		var names = group.members.map(function(member) { return member.name; });
		var workers = [];

		function next() {
			if (!names.length)
				return Promise.resolve();

			return api.delay(names.shift()).then(next, next);
		}

		/* next() 同步 shift，循环上限须先算好，否则实际并发会被缩短的队列压小 */
		var parallel = Math.min(CONCURRENCY, names.length);

		for (var i = 0; i < parallel; i++)
			workers.push(next());

		return Promise.all(workers).then(function() {
			return group.type == 'Selector' ? null : api.reselect(group.name);
		}).then(L.bind(this.refresh, this));
	},

	render: function(data) {
		this.body = E('div', {});
		this.open = {};

		this.update(data);

		poll.add(L.bind(this.refresh, this), 5);

		return this.body;
	}
});
