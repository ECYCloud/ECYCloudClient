'use strict';
'require baseclass';
'require rpc';
'require ui';

function declare(method, params, expect) {
	return rpc.declare({
		object: 'luci.ecycloud',
		method: method,
		params: params,
		expect: expect || { '': {} }
	});
}

var stages = {
	stopped: _('Stopped'),
	preparing: _('Preparing configuration'),
	validating: _('Validating configuration'),
	starting: _('Starting kernel'),
	running: _('Running'),
	recovering: _('Recovering'),
	failed: _('Failed')
};

return baseclass.extend({
	status: declare('status'),
	groups: declare('groups'),
	logs: declare('logs', [ 'lines' ], { log: '' }),
	login: declare('login', [ 'email', 'password', 'code' ]),
	logout: declare('logout'),
	start: declare('start'),
	stop: declare('stop'),
	update: declare('update'),
	select: declare('select', [ 'group', 'name' ]),
	delay: declare('delay', [ 'name' ]),
	reselect: declare('reselect', [ 'group' ]),
	mode: declare('mode', [ 'mode' ]),

	stageText: function(status) {
		return stages[status.stage] || status.stage || '-';
	},

	bytes: function(value) {
		return '%1024.2mB'.format(value || 0);
	},

	delayText: function(delay) {
		return delay > 0 ? _('%d ms').format(delay) : _('untested');
	},

	timestamp: function(seconds) {
		return seconds > 0 ? new Date(seconds * 1000).toLocaleString() : '-';
	},

	notify: function(result, success) {
		var message = result.msg || (result.ok ? success : _('Request failed'));

		ui.addNotification(null, E('p', {}, [ message ]), result.ok ? 'info' : 'warning');

		return result;
	}
});
