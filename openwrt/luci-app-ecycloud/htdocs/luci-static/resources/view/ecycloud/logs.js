'use strict';
'require view';
'require dom';
'require poll';
'require ecycloud.api as api';

var LINES = 300;
var LEVELS = [ 'debug', 'info', 'warning', 'error' ];

function lineLevel(line) {
	var body = line.indexOf(' msg=');
	var head = body < 0 ? line : line.slice(0, body);
	var level = head.match(/(?:^|\s)level=(debug|info|warning|error|fatal|panic)\b/);
	if (level)
		return /^(fatal|panic)$/.test(level[1]) ? 'error' : level[1];
	if (/\.(err|error)\b/i.test(head))
		return 'error';
	if (/\.(warn|warning)\b/i.test(head))
		return 'warning';
	if (/\.debug\b/i.test(head))
		return 'debug';
	return 'info';
}

/* 内核那行是 logfmt（time=... level=... msg="..."），时间与级别界面已单独列出，只留正文 */
function logBody(text) {
	var at = text.indexOf(' msg=');
	if (at < 0)
		return text;

	var raw = text.slice(at + 5);
	if (!raw.length)
		return '';

	if (raw.charAt(0) != '"') {
		var end = raw.indexOf(' ');
		return end < 0 ? raw : raw.slice(0, end);
	}

	var out = '';
	for (var i = 1; i < raw.length; i++) {
		var c = raw.charAt(i);

		if (c == '\\' && i + 1 < raw.length) {
			var next = raw.charAt(++i);
			out += next == 'n' ? '\n' : next == 't' ? '\t' : next == 'r' ? '\r' : next;
			continue;
		}

		if (c == '"')
			break;

		out += c;
	}

	return out;
}

function parseLog(line) {
	var match = line.match(/^(\w{3}\s+\w{3}\s+\d+\s+)(\d{2}:\d{2}:\d{2})(\s+\d{4}\s+)([\w.]+)\s+([^:]+):\s*(.*)$/);

	if (!match)
		return {
			level: lineLevel(line),
			time: '',
			source: '',
			message: line
		};

	var program = match[5].replace(/\[\d+\]$/, '');

	return {
		level: lineLevel(line),
		time: match[2],
		source: program,
		message: logBody(match[6])
	};
}

function logText(data) {
	if (data == null)
		return '';
	if (typeof data == 'string')
		return data;
	return data.log || '';
}

return view.extend({
	handleSave: null,
	handleSaveApply: null,
	handleReset: null,

	load: function() {
		var self = this;

		return api.status().then(function(status) {
			self.signedIn = api.signedIn(status);
			if (!self.signedIn)
				return '';

			return api.logs(LINES);
		});
	},

	entries: function() {
		var keyword = (this.keyword || '').toLowerCase();
		var level = this.level || '';

		return (this.raw || '').split('\n').filter(function(line) {
			return line.length > 0;
		}).map(parseLog).filter(function(entry) {
			if (level && entry.level != level)
				return false;

			if (!keyword)
				return true;

			return (entry.source + ' ' + entry.message).toLowerCase().indexOf(keyword) != -1;
		}).reverse();
	},

	paint: function() {
		if (!this.signedIn) {
			if (this.count)
				this.count.textContent = '';
			if (this.body)
				dom.content(this.body, api.signedOut());
			return;
		}

		var rows = this.entries();

		this.count.textContent = _('%d entries').format(rows.length);
		this.paintFilter();

		if (!rows.length) {
			dom.content(this.body, E('div', { 'class': 'ecycloud-empty' }, [
				_('No matching logs')
			]));
			return;
		}

		dom.content(this.body, E('div', { 'class': 'ecycloud-list' }, rows.map(function(entry) {
			return E('div', { 'class': 'ecycloud-log is-' + entry.level }, [
				E('span', { 'class': 'ecycloud-chip' }, [ entry.level ]),
				E('span', { 'class': 'ecycloud-log-time' }, [ entry.time ]),
				E('span', { 'class': 'ecycloud-log-src' }, [ entry.source ]),
				E('span', { 'class': 'ecycloud-log-msg' }, [ entry.message ])
			]);
		})));
	},

	paintFilter: function() {
		var self = this;

		dom.content(this.filterBar, api.segments(
			[ { value: '', label: _('All') } ].concat(LEVELS.map(function(name) {
				return { value: name, label: name };
			})),
			this.level || '',
			function(value) {
				self.level = value;
				self.paint();
			}
		));
	},

	update: function(log) {
		this.raw = logText(log);
		this.paint();
	},

	render: function(log) {
		var self = this;

		return api.ensureStyle().then(function() {
			if (!self.signedIn)
				return api.shell([ api.signedOut() ], true);

			self.keyword = '';
			self.level = '';
			self.raw = logText(log);
			self.body = E('div', {});
			self.filterBar = E('div', {});
			self.count = E('span', { 'class': 'ecycloud-count' }, [ '' ]);

			var search = api.input({
				placeholder: _('Search log content')
			});
			search.addEventListener('input', function() {
				self.keyword = search.value.trim();
				self.paint();
			});

			self.paint();

			poll.add(L.bind(function() {
				var view = this;

				return api.status().then(function(status) {
					view.signedIn = api.signedIn(status);
					if (!view.signedIn) {
						view.raw = '';
						view.paint();
						return;
					}

					return api.logs(LINES).then(L.bind(view.update, view));
				});
			}, self), 5);

			return api.shell([
				E('div', { 'class': 'ecycloud-toolbar' }, [
					self.filterBar,
					self.count,
					search
				]),
				api.card([ self.body ])
			]);
		});
	}
});
