'use strict';
'require view';
'require poll';
'require ecycloud.api as api';

var LINES = 300;

return view.extend({
	handleSave: null,
	handleSaveApply: null,
	handleReset: null,

	load: function() {
		return api.logs(LINES);
	},

	update: function(log) {
		var text = log || _('No entries yet.');

		this.box.rows = text.split('\n').length + 1;
		this.box.value = text;
		this.box.scrollTop = this.box.scrollHeight;
	},

	render: function(log) {
		this.box = E('textarea', {
			'class': 'cbi-input-textarea',
			'readonly': 'readonly',
			'wrap': 'off'
		});

		this.update(log);

		poll.add(L.bind(function() {
			return api.logs(LINES).then(L.bind(this.update, this));
		}, this), 5);

		return E('div', { 'class': 'cbi-section' }, [
			E('div', { 'class': 'cbi-section-descr' }, [
				_('Last %d syslog entries of the plugin and the kernel.').format(LINES)
			]),
			this.box
		]);
	}
});
