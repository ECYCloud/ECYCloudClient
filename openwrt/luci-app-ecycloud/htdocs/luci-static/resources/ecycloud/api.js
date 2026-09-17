'use strict';
'require baseclass';
'require rpc';

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
	recovering: _('Recovering'),
	failed: _('Failed')
};

var BYPASS = {
	direct: 1, reject: 1, 'reject-drop': 1, rejectdrop: 1,
	compatible: 1, pass: 1, dns: 1
};

var CLOSED_KEY = 'ecycloud.closed';
var ALIVE_KEY = 'ecycloud.alive';
var SINCE_KEY = 'ecycloud.connectedAt';
var RANK_KEY = 'ecycloud.trafficRank';
var CLOSED_LIMIT = 1000;
var RANK_LIMIT = 10;
var kickWatch = false;
var kickBusy = false;
var groupTests = { testing: new Map(), speed_testing: new Map() };
var groupsRpc = declare('groups');
var groupsRequest = 0;
var groupsResponse = 0;
var groupsData;
var stopRpc = declare('stop');
var connectGeneration = 0;
var connectPending = null;

function loadJson(key, fallback) {
	try {
		var value = JSON.parse(sessionStorage.getItem(key) || '');
		return value == null ? fallback : value;
	}
	catch (e) {
		return fallback;
	}
}

function saveJson(key, value) {
	sessionStorage.setItem(key, JSON.stringify(value));
}

function loadLocal(key, fallback) {
	try {
		var value = JSON.parse(localStorage.getItem(key) || '');
		return value == null ? fallback : value;
	}
	catch (e) {
		return fallback;
	}
}

function saveLocal(key, value) {
	localStorage.setItem(key, JSON.stringify(value));
}

function dayKey(date) {
	return date.getFullYear() + '-' + two(date.getMonth() + 1) + '-' + two(date.getDate());
}

function neighborDay(date, delta) {
	var next = new Date(date.getTime());
	next.setDate(next.getDate() + delta);
	return next;
}

function topRank(map, skip) {
	return Object.keys(map || {}).map(function(name) {
		return { name: name, bytes: map[name] || 0 };
	}).filter(function(row) {
		return row.bytes > 0 && !(skip && skip[String(row.name).toLowerCase()]);
	}).sort(function(a, b) {
		return b.bytes - a.bytes;
	}).slice(0, RANK_LIMIT);
}

function skipHosts(list) {
	var skip = {};
	(list || []).forEach(function(item) {
		var key = String(item || '').replace(/^\s+|\s+$/g, '').toLowerCase();
		if (key)
			skip[key] = 1;
	});
	return skip;
}

function two(value) {
	return (value < 10 ? '0' : '') + value;
}

function svgEl(name, attrs) {
	var node = document.createElementNS('http://www.w3.org/2000/svg', name);

	for (var key in attrs)
		node.setAttribute(key, attrs[key]);

	return node;
}

return baseclass.extend({
	status: declare('status'),
	groups: function() {
		var request = ++groupsRequest;
		var ready = {};
		Object.keys(groupTests).forEach(function(field) {
			ready[field] = new Map();
			groupTests[field].forEach(function(test, name) {
				if (!test.pending)
					ready[field].set(name, test);
			});
		});
		return groupsRpc().then(function(data) {
			var fresh = request >= groupsResponse && !data.error;
			if (!fresh)
				data = groupsData || data;
			else {
				groupsResponse = request;
				groupsData = data;
			}
			(data.groups || []).forEach(function(group) {
				Object.keys(groupTests).forEach(function(field) {
					var test = groupTests[field].get(group.name);
					if (!test)
						return;
					if (fresh && ready[field].get(group.name) === test)
						groupTests[field].delete(group.name);
					else
						group[field] = true;
				});
			});
			return data;
		});
	},
	logs: declare('logs', [ 'lines' ], { log: '' }),
	login: declare('login', [ 'email', 'password', 'code' ]),
	sendLoginVerify: declare('send_login_verify', [ 'email' ]),
	loginCode: declare('login_code', [ 'email', 'code' ]),
	logout: declare('logout'),
	start: declare('start'),
	stop: function() {
		connectGeneration++;
		return stopRpc();
	},
	update: declare('update', [ 'what', 'path' ]),
	selectRpc: declare('select', [ 'group', 'name' ]),
	delay: declare('delay', [ 'name' ]),
	test_group: declare('test_group', [ 'group' ]),
	speed_test: declare('speed_test', [ 'name' ]),
	test_group_speed: declare('test_group_speed', [ 'group' ]),
	reselect: declare('reselect', [ 'group' ]),
	mode: declare('mode', [ 'mode' ]),
	set: declare('set', [ 'name', 'value' ]),
	connections: declare('connections'),
	refreshAccount: declare('refresh_account'),
	onlineDevices: declare('online_devices'),
	devices: declare('devices', [ 'page', 'length' ]),
	ensureKernel: declare('ensure_kernel'),

	updateGeo: function() {
		return this.update('geo');
	},

	runtimeConfig: function() {
		return this.update('runtime');
	},

	ruleProviders: function() {
		return this.update('rules');
	},

	ruleProvider: function(path) {
		return this.update('rule', path);
	},

	checkUpdate: function(target) {
		return this.update(target == 'kernel' ? 'check_kernel' : 'check_app');
	},

	appUpdateText: function(res) {
		if (!res || !res.ok)
			return _('Check failed: %s').format((res && res.msg) || _('Request failed'));
		if (!res.outdated)
			return _('Up to date (%s)').format(res.latest || res.current);
		return _('Update available (%s). This page cannot install it. Open the releases page, extract the OpenWrt package, then install via SSH. apk: apk add --allow-untrusted /tmp/luci-app-ecycloud-*.apk; ipk: opkg install /tmp/luci-app-ecycloud_*.ipk').format(res.latest);
	},

	watchAppUpdate: function() {
		if (this._updateTimer)
			return;

		var self = this;
		var busy = false;
		var key = 'ecycloud.appUpdate';
		var cached = loadJson(key, {});
		var tick = function() {
			if (busy || document.hidden || !document.querySelector('#ecycloud-root'))
				return;

			if (!cached.checked || Date.now() - cached.checked >= 3600000) {
				busy = true;
				return self.checkUpdate('app').then(function(res) {
					cached.result = res && res.ok ? res : null;
				}).catch(function() {
					cached.result = null;
				}).finally(function() {
					busy = false;
					cached.checked = Date.now();
					saveJson(key, cached);
					tick();
				});
			}

			var res = cached.result;
			if (!res || !res.outdated || document.querySelector('.ecycloud-modal'))
				return;
			var version = res.current + '|' + res.latest;
			if (cached.prompted == version)
				return;

			self.alert(E('div', {}, [
				E('p', {}, [ self.appUpdateText(res) ]),
				self.jump(res.releases_url, _('Open releases'), { external: true })
			]));
			cached.prompted = version;
			saveJson(key, cached);
		};
		this._updateTimer = setInterval(tick, 60000);
		setTimeout(tick, 1000);
	},

	fetchAnnouncements: function(force) {
		return this.update('announcements', force ? 'refresh' : '');
	},

	markAnnouncementsSeen: function() {
		return this.update('announcements', 'seen');
	},

	markAnnouncementSeen: function(id) {
		return this.update('announcements', 'seen:' + id);
	},

	dismissAnnouncementPopup: function() {
		return this.update('announcements', 'popup');
	},
	reclaimDeviceSlot: declare('device_reclaim', [ 'target_device_id' ]),
	ackDeviceKick: declare('device_kick_ack'),
	kickDevice: declare('kick_device', [ 'device_id' ]),

	ensureStyle: function() {
		var href = L.resource('view/ecycloud/style.css');
		var link = document.getElementById('ecycloud-style');
		var self = this;

		if (!link)
			link = E('link', {
				id: 'ecycloud-style',
				rel: 'stylesheet',
				href: href
			});
		else if (link.getAttribute('href') !== href)
			link.href = href;

		(document.body || document.documentElement).appendChild(link);

		/* uhttpd 不发 Cache-Control，URL 也没版本号：不强制回源校验就会拿到旧样式 */
		if (!this._sheet)
			this._sheet = fetch(href, { cache: 'no-cache' }).then(function(res) {
				return res.ok ? res.text() : '';
			}).then(function(css) {
				self._shadowCss = self.rewriteShadowCss(css);
			}).catch(function() {
				self._shadowCss = self._shadowCss || '';
			});

		return Promise.all([ this.applyI18n(), this._sheet ]);
	},

	findId: function(id) {
		if (!id)
			return null;

		var node = document.getElementById(id);
		if (node)
			return node;

		var hosts = document.querySelectorAll('.ecycloud-ui, .ecycloud-modal');
		var i;
		var found;

		for (i = 0; i < hosts.length; i++) {
			if (!hosts[i].shadowRoot)
				continue;
			found = hosts[i].shadowRoot.getElementById(id);
			if (found)
				return found;
		}

		return null;
	},

	formField: function(option, section_id) {
		var id = option && section_id != null ? option.cbid(section_id) : '';
		var node;

		if (!id)
			return null;
		if (option.map && option.map.findElement)
			node = option.map.findElement('id', id);
		return node || this.findId(id);
	},

	saveMaps: function() {
		var tasks = [];

		this.findAll('.cbi-map').forEach(function(map) {
			var inst = L.dom.findClassInstance(map);
			if (inst && typeof inst.save == 'function')
				tasks.push(inst.save());
		});
		return Promise.all(tasks);
	},

	isIpNet: function(value) {
		var item = String(value || '').replace(/^\s+|\s+$/g, '');
		var m;

		if (!item || /[^0-9A-Fa-f:./]/.test(item))
			return false;
		if (item.indexOf(':') >= 0)
			return /^[0-9A-Fa-f:]+(\/([0-9]|[1-9][0-9]|1[01][0-9]|12[0-8]))?$/.test(item)
				&& item.indexOf(':::') < 0;

		m = item.match(/^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})(\/([0-9]|[12][0-9]|3[0-2]))?$/);
		return !!(m && +m[1] <= 255 && +m[2] <= 255 && +m[3] <= 255 && +m[4] <= 255);
	},

	isIpCidr: function(value) {
		return String(value || '').indexOf('/') >= 0 && this.isIpNet(value);
	},

	findAll: function(selector) {
		var list = [];

		function add(root) {
			if (!root || !root.querySelectorAll)
				return;
			root.querySelectorAll(selector).forEach(function(node) {
				list.push(node);
			});
		}

		add(document);
		document.querySelectorAll('.ecycloud-ui, .ecycloud-modal').forEach(function(host) {
			add(host.shadowRoot);
		});
		return list;
	},

	stage: function(host) {
		if (!host)
			return null;
		if (host.shadowRoot)
			return host.shadowRoot.querySelector('.ecycloud-stage') || host.shadowRoot;
		return host;
	},

	hostReset: function() {
		return ':host{all:initial;display:block;box-sizing:border-box;width:100%;max-width:100%;'
			+ 'position:relative;font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,'
			+ '"Helvetica Neue",Arial,sans-serif;font-size:14px;line-height:1.4;'
			+ 'color:var(--ecy-fg);background:var(--ecy-band)}'
			+ ':host(.ecycloud-modal){position:fixed;inset:0;z-index:20000;display:flex;'
			+ 'align-items:center;justify-content:center;width:auto;max-width:none;'
			+ 'background:rgba(15,18,28,.42)}'
			+ ':host(.ecycloud-modal)[hidden]{display:none}'
			+ ':host(.ecycloud-modal) .ecycloud-stage{display:flex;align-items:center;'
			+ 'justify-content:center;width:100%;height:100%;max-width:none;'
			+ 'background:transparent}'
			+ ':host *,:host *::before,:host *::after{box-sizing:border-box}'
			+ '.ecycloud-stage{display:block;width:100%;color:inherit}';
	},

	rewriteShadowCss: function(css) {
		var dark = ':host([data-theme="dark"])';
		var light = ':host([data-theme="light"])';
		var token = function(name) {
			return name.replace(/[.*+?^${}()|[\]\\]/g, '\\$&') + '(?![\\w-])';
		};

		return String(css || '')
			.replace(new RegExp('html\\.dark ' + token('.ecycloud-ui'), 'g'), dark)
			.replace(new RegExp('body\\.dark ' + token('.ecycloud-ui'), 'g'), dark)
			.replace(new RegExp('html\\[data-theme="dark"\\] ' + token('.ecycloud-ui'), 'g'), dark)
			.replace(new RegExp('body\\[data-theme="dark"\\] ' + token('.ecycloud-ui'), 'g'), dark)
			.replace(new RegExp('\\.dark ' + token('.ecycloud-ui'), 'g'), dark)
			.replace(new RegExp(token('.ecycloud-ui') + '\\[data-theme="dark"\\]', 'g'), dark)
			.replace(new RegExp(token('.ecycloud-modal') + '\\[data-theme="dark"\\]', 'g'), dark)
			.replace(new RegExp(token('.ecycloud-ui') + '\\[data-theme="light"\\]', 'g'), light)
			.replace(new RegExp(token('.ecycloud-modal') + '\\[data-theme="light"\\]', 'g'), light)
			.replace(new RegExp('html\\.dark ' + token('.ecycloud-modal'), 'g'), dark)
			.replace(new RegExp('body\\.dark ' + token('.ecycloud-modal'), 'g'), dark)
			.replace(new RegExp('html\\[data-theme="dark"\\] ' + token('.ecycloud-modal'), 'g'), dark)
			.replace(new RegExp('body\\[data-theme="dark"\\] ' + token('.ecycloud-modal'), 'g'), dark)
			.replace(/html\.dark /g, dark + ' ')
			.replace(/body\.dark /g, dark + ' ')
			.replace(/html\[data-theme="dark"\] /g, dark + ' ')
			.replace(/body\[data-theme="dark"\] /g, dark + ' ')
			.replace(/html body #maincontent /g, '')
			.replace(/html body #main-content /g, '')
			.replace(/html body \.main-right /g, '')
			.replace(/html body #view /g, '')
			.replace(/html body /g, '')
			.replace(/html\[data-page\^="admin-services-ecycloud"\] /g, '')
			.replace(/html:has\(\.ecycloud-ui\) /g, '')
			.replace(new RegExp('(?:html\\s+)?body\\s+' + token('.ecycloud-ui'), 'g'), ':host(.ecycloud-ui)')
			.replace(new RegExp('html\\s+' + token('.ecycloud-ui'), 'g'), ':host(.ecycloud-ui)')
			.replace(new RegExp('(?:html\\s+)?body\\s+' + token('.ecycloud-modal'), 'g'), ':host(.ecycloud-modal)')
			.replace(new RegExp('html\\s+' + token('.ecycloud-modal'), 'g'), ':host(.ecycloud-modal)')
			.replace(new RegExp(token('.ecycloud-ui'), 'g'), ':host(.ecycloud-ui)')
			.replace(new RegExp(token('.ecycloud-modal'), 'g'), ':host(.ecycloud-modal)')
			.replace(/\b(?:html|body)\s+:host/g, ':host')
			.replace(/(?:#maincontent|#main-content|\.main-right|#view)\s+:host/g, ':host')
			.replace(/:host\(:host(\(\.[^)]+\))\)/g, ':host$1');
	},

	isolate: function(host) {
		if (!host)
			return host;
		if (host.getAttribute('data-ecy-shadow') == '1' && host.shadowRoot)
			return this.sealShadow(host);

		var shadow = host.attachShadow({ mode: 'open' });
		var style = E('style', { id: 'ecycloud-shadow-style' });
		var inner = E('div', { 'class': 'ecycloud-stage' });
		var self = this;

		host.setAttribute('data-ecy-shadow', '1');
		style.textContent = this.hostReset() + (this._shadowCss || '');
		shadow.appendChild(style);
		shadow.appendChild(inner);

		while (host.firstChild)
			inner.appendChild(host.firstChild);

		if (!this._shadowCss) {
			this.ensureStyle().then(function() {
				style.textContent = self.hostReset() + (self._shadowCss || '');
			});
		}

		this.parkFields(host);
		return host;
	},

	sealShadow: function(host) {
		var shadow = host.shadowRoot;
		var inner = this.stage(host);
		var park = host._ecyPark;
		var kids;

		if (!shadow || !inner)
			return host;

		kids = Array.prototype.slice.call(host.childNodes);
		kids.forEach(function(kid) {
			if (kid === park)
				return;
			inner.appendChild(kid);
		});
		this.parkFields(host);
		return host;
	},

	parkFields: function(host) {
		var inner = this.stage(host);
		var park = host._ecyPark;

		if (!inner)
			return;

		if (!park) {
			park = host._ecyPark = E('div', {
				'class': 'ecycloud-native-hide',
				'aria-hidden': 'true'
			});
			host.appendChild(park);
		}

		inner.querySelectorAll('input[type="hidden"][id], input[type="checkbox"][id], select[id], textarea[id], .ecycloud-native-hide').forEach(function(el) {
			if (park.contains(el) || el === park || el.closest('.cbi-dynlist') || el.closest('.ecycloud-switch'))
				return;
			park.appendChild(el);
		});
	},

	onBackdrop: function(host, run) {
		host.addEventListener('click', function(ev) {
			var path = ev.composedPath ? ev.composedPath() : [];
			var i;

			for (i = 0; i < path.length; i++) {
				if (path[i] && path[i].classList && path[i].classList.contains('ecycloud-modal-card'))
					return;
			}
			if (path.indexOf(host) >= 0)
				run(ev);
		});
	},

	applyI18n: function() {
		if (this._i18n)
			return this._i18n;

		var name = null;

		try {
			name = this.i18nFile();
		}
		catch (e) {
			this.installI18n({});
			return this._i18n = Promise.resolve();
		}

		if (!name) {
			this.installI18n({});
			return this._i18n = Promise.resolve();
		}

		var self = this;

		this._i18n = fetch(L.resource('view/ecycloud/' + name)).then(function(res) {
			return res.ok ? res.json() : {};
		}).then(function(map) {
			self.installI18n(map);
		}).catch(function() {});

		return this._i18n;
	},

	luciGlobals: function() {
		return (L && L.globals) || {};
	},

	uiLang: function() {
		try {
			return window.localStorage.getItem('ecycloud-lang') || '';
		}
		catch (e) {
			return '';
		}
	},

	setUiLang: function(code) {
		var before = this.resolveLang();

		try {
			window.localStorage.setItem('ecycloud-lang', code);
		}
		catch (e) {}

		if (this.resolveLang() != before)
			location.reload();
	},

	detectLang: function() {
		var globals = this.luciGlobals();
		var lang = String(document.documentElement.lang || globals.locale || navigator.language || '')
			.toLowerCase().replace(/_/g, '-');
		var catalog = globals.catalog || {};

		if (lang == 'auto')
			lang = String(navigator.language || '').toLowerCase().replace(/_/g, '-');

		if (lang.indexOf('zh-tw') == 0 || lang.indexOf('zh-hk') == 0 || lang.indexOf('zh-hant') == 0)
			return 'zh_TW';
		if (lang.indexOf('zh') == 0)
			return 'zh_CN';
		if (catalog.Home == '首頁' || catalog.Settings == '設定' || catalog.Connect == '連接')
			return 'zh_TW';
		if (catalog.Home == '首页' || catalog.Settings == '设置' || catalog.Connect == '连接')
			return 'zh_CN';

		return 'en';
	},

	resolveLang: function() {
		var stored = this.uiLang();
		if (stored == 'zh_CN' || stored == 'zh_TW' || stored == 'en')
			return stored;
		return this.detectLang();
	},

	i18nFile: function() {
		var lang = this.resolveLang();
		if (lang == 'zh_TW')
			return 'i18n.zh-tw.json';
		if (lang == 'zh_CN')
			return 'i18n.zh-cn.json';
		return null;
	},

	installI18n: function(map) {
		if (!map)
			return;

		var extra = this._phrases || (this._phrases = {});
		var globals = this.luciGlobals();
		var key;

		for (key in map)
			extra[key] = map[key];

		if (!this._patchedGettext) {
			this._patchedGettext = true;
			var orig = window._;
			var self = this;
			window._ = function(msg) {
				if (extra[msg] != null)
					return extra[msg];
				if (self.resolveLang() == 'en')
					return msg;
				return typeof orig == 'function' ? orig.apply(this, arguments) : msg;
			};
		}

		if (globals.catalog) {
			try {
				for (key in extra)
					globals.catalog[key] = extra[key];
			}
			catch (e) {}
		}
	},

	uiTheme: function() {
		try {
			return window.localStorage.getItem('ecycloud-theme') || 'auto';
		}
		catch (e) {
			return 'auto';
		}
	},

	setUiTheme: function(mode) {
		try {
			window.localStorage.setItem('ecycloud-theme', mode);
		}
		catch (e) {}

		this.paintTheme();
	},

	paintTheme: function() {
		var theme = this.detectTheme();
		document.querySelectorAll('.ecycloud-ui, .ecycloud-modal').forEach(function(item) {
			item.setAttribute('data-theme', theme);
		});
	},

	detectTheme: function() {
		var forced = this.uiTheme();
		if (forced == 'light' || forced == 'dark')
			return forced;

		if (document.body.classList.contains('dark')
			|| document.documentElement.classList.contains('dark')
			|| document.body.getAttribute('data-theme') == 'dark'
			|| document.documentElement.getAttribute('data-theme') == 'dark'
			|| document.documentElement.getAttribute('data-dark') == 'true')
			return 'dark';

		var node = document.querySelector('#maincontent')
			|| document.querySelector('.main-right')
			|| document.body;

		while (node) {
			var bg = getComputedStyle(node).backgroundColor;
			var m = /^rgba?\((\d+),\s*(\d+),\s*(\d+)(?:,\s*([0-9.]+))?/.exec(bg || '');

			if (m && (m[4] == null || +m[4] > 0.05))
				return (0.2126 * m[1] + 0.7152 * m[2] + 0.0722 * m[3]) < 140 ? 'dark' : 'light';

			node = node.parentElement;
		}

		if (window.matchMedia && window.matchMedia('(prefers-color-scheme: dark)').matches)
			return 'dark';

		return 'light';
	},

	profileNotice: function(res) {
		if (!res || !res.ok)
			return (res && res.msg) || _('Update failed');
		if (res.reloaded)
			return _('Update succeeded');
		if (res.changed)
			return _('Update saved, takes effect the next time the kernel starts');
		return _('Already up to date');
	},

	isProfileFormatError: function(message) {
		var text = String(message || '');
		return text.indexOf('面板配置不规范') == 0
			|| text.indexOf('配置未通过内核校验') == 0
			|| text.indexOf('配置校验未通过') == 0
			|| text.indexOf('面板下发的不是一份完整配置') == 0;
	},

	alertProfileFormat: function(message) {
		this._lastFormatError = message;
		return this.dialog({
			title: _('Clash profile is invalid'),
			text: message,
			ok: _('Got it')
		});
	},

	applyTheme: function(node) {
		node.setAttribute('data-theme', this.detectTheme());
		this.watchTheme();
		return node;
	},

	releaseChrome: function(root) {
		var node = root && root.parentElement;

		while (node && node !== document.documentElement) {
			if (node.id == 'maincontent' || node.id == 'main-content' || node.id == 'view'
				|| node.classList.contains('container')
				|| node.classList.contains('main-content')
				|| node.classList.contains('main-right')
				|| node.classList.contains('cbi-map')) {
				['display', 'float', 'flex', 'height', 'max-height', 'overflow', 'max-width', 'width'].forEach(function(name) {
					node.style.removeProperty(name);
				});
			}
			node = node.parentElement;
		}
	},

	watchTheme: function() {
		var self = this;

		if (this._themeWatch)
			return;

		this._themeWatch = true;

		var paint = function() {
			self.paintTheme();
		};
		var opts = { attributes: true, attributeFilter: [ 'class', 'data-theme', 'data-dark' ] };

		new MutationObserver(paint).observe(document.documentElement, opts);
		new MutationObserver(paint).observe(document.body, opts);

		if (window.matchMedia)
			window.matchMedia('(prefers-color-scheme: dark)').addEventListener('change', paint);
	},

	inputCss: function() {
		return ':host{all:initial;display:block;width:100%;max-width:100%;line-height:0;font:inherit;color:inherit}'
			+ 'input{box-sizing:border-box;width:100%;min-width:0;height:36px;margin:0;padding:0 12px;'
			+ 'border:1px solid var(--ecy-input-line);border-radius:999px;background:var(--ecy-card);'
			+ 'color:var(--ecy-fg);font:inherit;line-height:1.4;outline:none;box-shadow:none;appearance:none}'
			+ 'input:focus{border-color:var(--ecy-primary);'
			+ 'box-shadow:0 0 0 3px color-mix(in srgb,var(--ecy-primary) 28%,transparent)}'
			+ ':host(.cbi-input-invalid) input{border-color:var(--ecy-danger)}';
	},

	input: function(attrs) {
		attrs = attrs || {};
		var host = document.createElement('span');
		var input = document.createElement('input');
		var shadow;
		var style;
		var key;

		host.className = 'ecycloud-input-host' + (attrs.class ? ' ' + attrs.class : '');
		input.type = attrs.type || 'text';
		if (attrs.value != null)
			input.value = attrs.value;
		if (attrs.placeholder)
			input.placeholder = attrs.placeholder;
		if (attrs.autocomplete)
			input.autocomplete = attrs.autocomplete;
		if (attrs.inputmode)
			input.inputMode = attrs.inputmode;
		if (attrs.readonly)
			input.readOnly = true;
		input.tabIndex = attrs.tabindex != null ? attrs.tabindex : 0;

		shadow = host.attachShadow({ mode: 'open' });
		style = document.createElement('style');
		style.textContent = this.inputCss();
		shadow.appendChild(style);
		shadow.appendChild(input);

		Object.defineProperty(host, 'value', {
			get: function() { return input.value; },
			set: function(value) { input.value = value == null ? '' : String(value); }
		});
		['addEventListener', 'removeEventListener', 'focus', 'blur', 'select'].forEach(function(name) {
			host[name] = function() {
				return input[name].apply(input, arguments);
			};
		});

		for (key in attrs) {
			if (typeof attrs[key] == 'function' && key.indexOf('on') != 0)
				host.addEventListener(key, attrs[key]);
		}

		return host;
	},

	pressable: function(cls, attrs, children) {
		attrs = attrs || {};
		var click = attrs.click;
		var disabled = !!attrs.disabled;
		var node;
		var key;

		node = E('div', {
			'class': cls,
			'role': attrs.role || 'button',
			'tabindex': disabled ? '-1' : '0',
			'title': attrs.title || null,
			'aria-label': attrs['aria-label'] || null,
			'aria-pressed': attrs['aria-pressed'] || null,
			'aria-disabled': disabled ? 'true' : null,
			'data-ico': attrs['data-ico'] || null
		}, children || []);

		Object.defineProperty(node, 'disabled', {
			configurable: true,
			get: function() {
				return node.getAttribute('aria-disabled') == 'true';
			},
			set: function(value) {
				if (value) {
					node.setAttribute('aria-disabled', 'true');
					node.setAttribute('tabindex', '-1');
					node.classList.add('is-disabled');
				}
				else {
					node.removeAttribute('aria-disabled');
					node.setAttribute('tabindex', '0');
					node.classList.remove('is-disabled');
				}
			}
		});

		if (disabled)
			node.disabled = true;

		node.addEventListener('click', function(ev) {
			if (node.disabled) {
				ev.preventDefault();
				ev.stopPropagation();
				return;
			}
			if (click)
				click.call(node, ev);
		});
		node.addEventListener('keydown', function(ev) {
			if (node.disabled)
				return;
			if (ev.key == 'Enter' || ev.key == ' ') {
				ev.preventDefault();
				node.click();
			}
		});

		for (key in attrs) {
			if (key.indexOf('data-') == 0 && attrs[key] != null)
				node.setAttribute(key, attrs[key]);
			if (typeof attrs[key] == 'function' && key != 'click')
				node.addEventListener(key, attrs[key]);
		}

		return node;
	},

	btn: function(label, kind, run) {
		var node = this.pressable(
			'ecycloud-btn' + (kind ? ' is-' + kind : ''),
			{},
			typeof label == 'string' ? [ label ] : label
		);

		if (!run)
			return node;

		node.addEventListener('click', function() {
			if (node.disabled)
				return;
			node.disabled = true;
			Promise.resolve(run()).catch(function(err) {
				this.notify({
					ok: false,
					msg: (err && err.message) || _('Request failed')
				});
			}.bind(this)).finally(function() {
				node.disabled = false;
			});
		}.bind(this));

		return node;
	},

	hideNative: function(node) {
		if (!node || node.closest('.ecycloud-native-hide'))
			return node;
		var wrap = E('span', { 'class': 'ecycloud-native-hide', 'aria-hidden': 'true' });
		node.parentNode.insertBefore(wrap, node);
		wrap.appendChild(node);
		return wrap;
	},

	optionItems: function(option, native) {
		var items = [];
		var keys = option && option.keylist;
		var vals = option && option.vallist;
		var seen = {};
		var i;

		if (keys) {
			for (i = 0; i < keys.length; i++) {
				items.push({
					value: keys[i],
					label: String(vals && vals[i] != null ? vals[i] : keys[i])
				});
				seen[String(keys[i])] = true;
			}
		}

		if (items.length || !native || !native.querySelectorAll)
			return items;

		native.querySelectorAll('li[data-value], option').forEach(function(el) {
			var value = el.getAttribute('data-value');
			if (value == null && el.tagName == 'OPTION')
				value = el.value;
			if (value == null || seen[String(value)])
				return;
			if (el.hasAttribute('placeholder') || el.hasAttribute('unselectable'))
				return;
			seen[String(value)] = true;
			items.push({
				value: value,
				label: String(el.textContent || value).replace(/\s+/g, ' ').trim() || String(value)
			});
		});

		return items;
	},

	skinListValue: function(option) {
		var self = this;
		var orig = option.renderWidget.bind(option);

		option.renderWidget = function(section_id, option_index, cfgvalue) {
			var opt = this;

			return Promise.resolve(orig(section_id, option_index, cfgvalue)).then(function(native) {
				var items = self.optionItems(opt, native);
				var value = (cfgvalue != null && cfgvalue !== '')
					? String(cfgvalue)
					: String(opt.default || (items[0] && items[0].value) || '');
				var input = E('input', {
					'id': opt.cbid(section_id),
					'type': 'hidden',
					'value': value
				});
				var wrap = E('div', { 'class': 'ecycloud-list-drop' }, [
					input,
					self.dropdown(items, value, function(next) {
						input.value = next;
						input.dispatchEvent(new CustomEvent('widget-change', { bubbles: true }));
						wrap.dispatchEvent(new CustomEvent('widget-change', { bubbles: true }));
					})
				]);

				return wrap;
			});
		};

		option.formvalue = function(section_id) {
			var node = self.formField(this, section_id);
			return node ? node.value : null;
		};
	},

	skinValue: function(option) {
		var self = this;

		option.renderWidget = function(section_id, option_index, cfgvalue) {
			var value = (cfgvalue != null && cfgvalue !== '')
				? String(cfgvalue)
				: String(this.default || '');
			var hidden = E('input', {
				'id': this.cbid(section_id),
				'type': 'hidden',
				'value': value
			});
			var field = self.input({
				type: this.password ? 'password' : 'text',
				value: value,
				placeholder: this.placeholder || '',
				inputmode: this.datatype == 'port' || this.datatype == 'uinteger' ? 'numeric' : null
			});

			field.addEventListener('input', function() {
				hidden.value = field.value;
			});
			field.addEventListener('change', function() {
				hidden.value = field.value;
				hidden.dispatchEvent(new CustomEvent('widget-change', { bubbles: true }));
				wrap.dispatchEvent(new CustomEvent('widget-change', { bubbles: true }));
			});

			var wrap = E('div', { 'class': 'ecycloud-list-drop' }, [ hidden, field ]);
			return wrap;
		};

		option.formvalue = function(section_id) {
			var node = self.formField(this, section_id);
			return node ? node.value : null;
		};
	},

	skinFlag: function(option) {
		var self = this;

		option.renderWidget = function(section_id, option_index, cfgvalue) {
			var enabled = this.enabled != null ? String(this.enabled) : '1';
			var raw = (cfgvalue != null && cfgvalue !== '') ? cfgvalue : this.default;
			var id = this.cbid(section_id);
			var on = raw === true || raw === 1 || String(raw) === String(enabled);
			var input = E('input', {
				'id': id,
				'type': 'checkbox',
				'value': enabled
			});
			var wrap = E('div', {
				'class': 'ecycloud-switch' + (on ? ' is-on' : ''),
				'role': 'switch',
				'tabindex': '0',
				'aria-checked': on ? 'true' : 'false'
			}, [
				input,
				E('span', { 'class': 'ecycloud-switch-ui' })
			]);

			input.checked = on;
			function toggle(ev) {
				if (ev)
					ev.preventDefault();
				input.checked = !input.checked;
				wrap.classList.toggle('is-on', input.checked);
				wrap.setAttribute('aria-checked', input.checked ? 'true' : 'false');
				input.dispatchEvent(new Event('change', { bubbles: true }));
				wrap.dispatchEvent(new CustomEvent('widget-change', { bubbles: true }));
			}
			wrap.addEventListener('click', toggle);
			wrap.addEventListener('keydown', function(ev) {
				if (ev.key == 'Enter' || ev.key == ' ') {
					ev.preventDefault();
					toggle();
				}
			});

			return wrap;
		};

		option.formvalue = function(section_id) {
			var node = self.formField(this, section_id);
			return (node && node.checked) ? this.enabled : this.disabled;
		};
	},

	skinNetworkSelect: function(option) {
		var self = this;
		var orig = option.renderWidget.bind(option);

		option.renderWidget = function(section_id, option_index, cfgvalue) {
			var opt = this;

			return Promise.resolve(orig(section_id, option_index, cfgvalue)).then(function(native) {
				var items = self.optionItems(opt, native);
				var current = [];

				if (Array.isArray(cfgvalue))
					current = cfgvalue.map(String);
				else if (cfgvalue != null && cfgvalue !== '')
					current = String(cfgvalue).split(/\s+/);

				var hidden = E('input', {
					'id': opt.cbid(section_id),
					'type': 'hidden',
					'value': current.join(' ')
				});

				var wrap = E('div', { 'class': 'ecycloud-list-drop' }, [
					hidden,
					self.dropdown(items, current, function(next) {
						hidden.value = (next || []).join(' ');
						hidden.dispatchEvent(new CustomEvent('widget-change', { bubbles: true }));
						wrap.dispatchEvent(new CustomEvent('widget-change', { bubbles: true }));
					}, { multiple: true, optional: true })
				]);

				return wrap;
			});
		};

		option.formvalue = function(section_id) {
			var node = self.formField(this, section_id);
			if (!node || !node.value)
				return [];
			return node.value.split(/\s+/).filter(Boolean);
		};
	},

	skinDynlist: function(list, accept) {
		var self = this;

		function hideInPlace(el) {
			if (el && el.classList)
				el.classList.add('ecycloud-native-hide');
		}

		function skinItem(item) {
			var hidden = item.querySelector('input[type="hidden"]');
			var chip = item.querySelector('.ecycloud-input-host[data-ecy-chip]');
			var del = item.querySelector('.ecycloud-dyn-del');
			var value = hidden ? hidden.value : '';
			var kids = Array.prototype.slice.call(item.children || []);
			var i, el;

			for (i = 0; i < kids.length; i++) {
				el = kids[i];
				if (el === chip || el === hidden || el === del)
					continue;
				if (el.classList.contains('cbi-button') || el.classList.contains('ecycloud-btn') ||
					el.classList.contains('ecycloud-dyn-del'))
					continue;
				if (!value && el.tagName === 'INPUT')
					value = el.value;
				if (!value && el.tagName === 'SPAN')
					value = el.textContent;
				if (el.tagName === 'SPAN' || (el.tagName === 'INPUT' && el.type !== 'hidden'))
					hideInPlace(el);
			}

			if (!chip) {
				chip = self.input({ value: value || '', readonly: true, tabindex: -1 });
				chip.setAttribute('data-ecy-chip', '1');
				item.insertBefore(chip, item.firstChild);
			}
			chip.value = value || '';

			if (!del) {
				del = self.pressable('ecycloud-dyn-del', { 'aria-label': _('Remove') }, []);
				del.addEventListener('click', function(ev) {
					ev.preventDefault();
					ev.stopPropagation();
					var node = item.querySelector('input[type="hidden"]');
					var val = node ? node.value : '';
					if (item.parentNode)
						item.parentNode.removeChild(item);
					list.dispatchEvent(new CustomEvent('cbi-dynlist-change', {
						bubbles: true,
						detail: { element: list, value: val, add: false }
					}));
				});
				item.appendChild(del);
			}
		}

		function skinAdd() {
			var add = list.querySelector('.add-item');
			var native;
			var field;
			var addBtn;
			var plus;

			if (!add || add.getAttribute('data-ecy-add') == '1')
				return;
			native = add.querySelector('input[type="text"], input:not([type="hidden"]):not([type="checkbox"]):not([type="button"]):not([type="submit"])');
			if (!native)
				return;
			add.setAttribute('data-ecy-add', '1');
			addBtn = add.querySelector('.cbi-button-add, .cbi-button, button, input[type="button"], input[type="submit"]');
			field = self.input({
				value: native.value,
				placeholder: native.placeholder || ''
			});
			plus = self.pressable('ecycloud-dyn-add', { 'aria-label': _('Add') }, []);
			function mark(ok) {
				field.classList.toggle('cbi-input-invalid', !ok);
				native.classList.toggle('cbi-input-invalid', !ok);
			}
			function allowed(value) {
				if (!value)
					return false;
				if (typeof accept == 'function')
					return !!accept(value);
				return !native.classList.contains('cbi-input-invalid');
			}
			function commit() {
				var value = String(field.value || '').replace(/^\s+|\s+$/g, '');
				native.value = value;
				native.dispatchEvent(new Event('keyup', { bubbles: true }));
				if (!allowed(value)) {
					mark(false);
					if (typeof list._ecyReject == 'function')
						list._ecyReject(value);
					return;
				}
				mark(true);
				if (typeof list._ecyReject == 'function')
					list._ecyReject('');
				if (addBtn)
					addBtn.click();
				else
					native.dispatchEvent(new KeyboardEvent('keydown', {
						key: 'Enter',
						keyCode: 13,
						which: 13,
						bubbles: true,
						cancelable: true
					}));
				field.value = native.value;
			}
			field.addEventListener('input', function() {
				var value = String(field.value || '').replace(/^\s+|\s+$/g, '');
				native.value = field.value;
				if (field.classList.contains('cbi-input-invalid'))
					mark(!value || allowed(value));
			});
			field.addEventListener('keydown', function(ev) {
				if (ev.key == 'Enter') {
					ev.preventDefault();
					commit();
				}
			});
			plus.addEventListener('click', function(ev) {
				ev.preventDefault();
				commit();
			});
			hideInPlace(native);
			if (addBtn)
				hideInPlace(addBtn);
			add.insertBefore(field, add.firstChild);
			add.appendChild(plus);
			add.appendChild(native);
			if (addBtn)
				add.appendChild(addBtn);
		}

		function skinAll() {
			var kids = list.children;
			var i;
			for (i = 0; i < kids.length; i++)
				if (kids[i].classList && kids[i].classList.contains('item'))
					skinItem(kids[i]);
			skinAdd();
		}

		if (!list || !list.children)
			return;

		skinAll();
		if (list.getAttribute('data-ecy-skin') == '1')
			return;
		list.setAttribute('data-ecy-skin', '1');
		new MutationObserver(skinAll).observe(list, { childList: true });
	},

	upgradeChecks: function(root) {
		var self = this;

		if (!root || !root.querySelectorAll)
			return;

		root.querySelectorAll('.cbi-checkbox').forEach(function(box) {
			if (box.getAttribute('data-ecy-switch') == '1' || box.closest('.ecycloud-switch'))
				return;

			var input = box.querySelector('input[type="checkbox"]');
			if (!input || input.closest('.ecycloud-switch'))
				return;

			box.setAttribute('data-ecy-switch', '1');
			var wrap = E('label', { 'class': 'ecycloud-switch' });
			box.parentNode.insertBefore(wrap, box);
			wrap.appendChild(input);
			wrap.appendChild(E('span', { 'class': 'ecycloud-switch-ui' }));
			self.hideNative(box);
		});

		root.querySelectorAll('input[type="checkbox"]').forEach(function(input) {
			if (input.closest('.ecycloud-switch') || input.closest('.ecycloud-login-remember'))
				return;

			if (input.closest('.cbi-dropdown') || input.closest('.cbi-dynlist') || input.closest('.ecycloud-native-hide'))
				return;

			var wrap = E('label', { 'class': 'ecycloud-switch' });
			if (input.id)
				wrap.setAttribute('for', input.id);
			input.parentNode.insertBefore(wrap, input);
			wrap.appendChild(input);
			wrap.appendChild(E('span', { 'class': 'ecycloud-switch-ui' }));
			if (input.id) {
				wrap.addEventListener('click', function(ev) {
					ev.preventDefault();
					input.checked = !input.checked;
					input.dispatchEvent(new Event('change', { bubbles: true }));
				});
			}
		});
	},

	bindSelects: function(root) {
		var self = this;

		if (!root || !root.querySelectorAll)
			return;

		root.querySelectorAll('select').forEach(function(sel) {
			if (sel.getAttribute('data-ecy-drop') || sel.multiple || sel.closest('.cbi-dropdown'))
				return;

			var items = [];
			var i;
			var options = sel.options || [];

			for (i = 0; i < options.length; i++)
				items.push({ value: options[i].value, label: options[i].text });

			if (!items.length)
				return;

			sel.setAttribute('data-ecy-drop', '1');
			sel.parentNode.insertBefore(self.dropdown(items, sel.value, function(value) {
				if (sel.value == value)
					return;

				sel.value = value;
				sel.dispatchEvent(new Event('change', { bubbles: true }));
			}, { disabled: sel.disabled }), sel.nextSibling);
			self.hideNative(sel);
		});

		this.bindCbiDropdowns(root);
		this.lockDropdownWidth(root);
	},

	bindCbiDropdowns: function(root) {
		var self = this;

		root.querySelectorAll('.cbi-dropdown').forEach(function(drop) {
			if (drop.getAttribute('data-ecy-drop')
				|| drop.closest('.cbi-page-actions')
				|| drop.closest('.ecycloud-actions'))
				return;

			var multiple = drop.hasAttribute('multiple') || drop.multiple;

			var items = [];
			var seen = {};
			var collect = function(li) {
				if (li.hasAttribute('placeholder') || li.hasAttribute('unselectable'))
					return;

				var value = li.getAttribute('data-value');
				if (value == null || seen[value])
					return;

				var openLabel = li.querySelector('.hide-open');
				var label = openLabel
					? openLabel.textContent.replace(/\s+/g, ' ').trim()
					: li.textContent.replace(/\s+/g, ' ').trim();
				var icon = li.querySelector('img, .ifacebadge');

				seen[value] = true;
				items.push({
					value: value,
					label: label || value,
					icon: icon ? icon.cloneNode(true) : null
				});
			};

			drop.querySelectorAll('ul.dropdown > li[data-value]').forEach(collect);
			if (!items.length)
				drop.querySelectorAll('li[data-value]').forEach(collect);

			if (!items.length)
				return;

			var widgetOf = function() {
				try {
					return L.dom.findClassInstance(drop);
				}
				catch (e) {
					return null;
				}
			};

			var inst = widgetOf();
			var current = multiple ? [] : '';
			if (inst && typeof inst.getValue === 'function') {
				current = inst.getValue();
				if (multiple && !Array.isArray(current))
					current = current != null && current !== '' ? [ current ] : [];
				if (!multiple && Array.isArray(current))
					current = current[0] || '';
			}
			if (!multiple && (current == null || current === '')) {
				var hidden = drop.querySelector('input[type="hidden"]');
				if (hidden)
					current = hidden.value;
			}
			if (!multiple && (current == null || current === ''))
				current = items[0].value;

			drop.setAttribute('data-ecy-drop', '1');
			drop.parentNode.insertBefore(self.dropdown(items, current, function(value) {
				var widget = widgetOf() || inst;
				if (widget && typeof widget.setValue === 'function')
					widget.setValue(value);
				else {
					var box = drop.querySelector('input[type="hidden"]');
					if (box)
						box.value = multiple ? (value || []).join(' ') : value;
				}
				if (widget && typeof widget.triggerChange === 'function')
					widget.triggerChange();
				else
					drop.dispatchEvent(new Event('change', { bubbles: true }));
			}, { disabled: drop.hasAttribute('disabled'), multiple: multiple, optional: multiple }), drop.nextSibling);
			self.hideNative(drop);
		});
	},

	pinMenu: function(menu, face) {
		if (!menu || !face)
			return;
		var w = Math.round(face.getBoundingClientRect().width);
		if (w <= 0)
			return;
		menu.style.width = w + 'px';
		menu.style.maxWidth = w + 'px';
		menu.style.minWidth = '0';
		menu.style.boxSizing = 'border-box';
	},

	lockDropdownWidth: function(root) {
		var self = this;

		root.querySelectorAll('.cbi-dropdown').forEach(function(drop) {
			if (drop.getAttribute('data-ecy-width') || drop.getAttribute('data-ecy-drop'))
				return;
			drop.setAttribute('data-ecy-width', '1');
			var sync = function() {
				self.pinMenu(drop.querySelector('ul.dropdown'), drop);
			};
			drop.addEventListener('click', function() {
				requestAnimationFrame(sync);
			});
			new MutationObserver(sync).observe(drop, {
				attributes: true,
				attributeFilter: [ 'open' ]
			});
		});
	},

	menuOpen: function() {
		return !!this.findAll('.ecycloud-drop.is-open, .cbi-dropdown[open]').length;
	},

	fixPageActions: function() {
		var self = this;
		var bar = document.querySelector('.cbi-page-actions');
		var ui = document.querySelector('.ecycloud-ui');
		if (!bar || !ui || bar.closest('.ecycloud-actions-card') || (ui.shadowRoot && ui.shadowRoot.contains(bar)))
			return;

		if (ui.classList.contains('is-guest')) {
			bar.classList.add('ecycloud-hidden');
			return;
		}

		var combo = bar.querySelector('.cbi-dropdown');
		if (combo) {
			var inst = L.dom.findClassInstance(combo);
			var apply = this.pressable('ecycloud-btn is-cta', {
				click: function(ev) {
					if (inst && inst.options && typeof inst.options.click === 'function')
						return inst.options.click.call(inst, ev, '0');
				}
			}, [ _('Save & Apply') ]);
			combo.parentNode.replaceChild(apply, combo);
		}

		bar.querySelectorAll('.cbi-button, .btn').forEach(function(el) {
			if (el.classList.contains('ecycloud-btn') || el.closest('.ecycloud-native-hide'))
				return;
			var kind = (el.classList.contains('cbi-button-reset') || el.classList.contains('cbi-button-negative'))
				? 'danger'
				: (el.classList.contains('cbi-button-apply') || el.classList.contains('cbi-button-save')
					|| el.classList.contains('cbi-button-action') || el.classList.contains('cbi-button-positive'))
					? 'cta' : '';
			var face = self.pressable('ecycloud-btn' + (kind ? ' is-' + kind : ''), {
				click: function() { el.click(); }
			}, [ el.textContent ]);
			el.parentNode.insertBefore(face, el);
			self.hideNative(el);
		});

		bar.classList.add('ecycloud-actions');
		bar.style.removeProperty('display');
		bar.style.removeProperty('padding');
		bar.style.removeProperty('padding-left');
		bar.style.removeProperty('padding-right');
		bar.style.removeProperty('margin-left');
		this.stage(ui).appendChild(E('div', { 'class': 'cbi-section ecycloud-actions-card' }, [ bar ]));
	},

	dropdown: function(items, value, onChange, opts) {
		opts = opts || {};
		items = items || [];
		var self = this;
		var multiple = !!opts.multiple;
		var open = false;
		var current = multiple
			? (Array.isArray(value) ? value.slice() : (value != null && value !== '' ? [ value ] : []))
			: value;
		var faceIco = E('span', { 'class': 'ecycloud-drop-face-ico' });
		var label = E('span', { 'class': 'ecycloud-drop-label' }, [ '' ]);
		var hint = E('span', { 'class': 'ecycloud-drop-hint' });
		var arrow = E('span', { 'class': 'ecycloud-drop-arrow' });
		var btn = this.pressable('ecycloud-drop', {
			disabled: opts.disabled
		}, [ faceIco, label, hint, arrow ]);
		var menu = E('div', { 'class': 'ecycloud-drop-menu' });
		var wrap = E('div', { 'class': 'ecycloud-drop-wrap' }, [ btn, menu ]);

		function itemOf(val) {
			return items.filter(function(item) { return item.value == val; })[0];
		}

		function picked(val) {
			if (!multiple)
				return val == current;
			for (var i = 0; i < current.length; i++)
				if (current[i] == val)
					return true;
			return false;
		}

		function textOf() {
			if (!multiple) {
				var hit = itemOf(current);
				return hit ? hit.label : (opts.placeholder || '');
			}
			var labels = [];
			items.forEach(function(item) {
				if (picked(item.value))
					labels.push(item.label);
			});
			return labels.length ? labels.join(', ') : (opts.placeholder || '');
		}

		function paintHint(node, item) {
			while (node.firstChild)
				node.removeChild(node.firstChild);
			var mark = self.delayHint(item);
			if (mark)
				node.appendChild(mark);
		}

		function faceItem() {
			if (!multiple)
				return itemOf(current);
			for (var i = 0; i < items.length; i++)
				if (picked(items[i].value))
					return items[i];
			return null;
		}

		function paintFace() {
			while (faceIco.firstChild)
				faceIco.removeChild(faceIco.firstChild);
			var hit = faceItem();
			if (hit && hit.icon) {
				faceIco.appendChild(hit.icon.cloneNode(true));
				faceIco.hidden = false;
			}
			else {
				faceIco.hidden = true;
			}
			label.textContent = textOf();
		}

		function paint() {
			paintFace();
			paintHint(hint, multiple ? null : itemOf(current));
			btn.classList.toggle('is-open', open);
			wrap.classList.toggle('is-open', open);
			menu.style.display = open ? 'flex' : 'none';
			while (menu.firstChild)
				menu.removeChild(menu.firstChild);
			items.forEach(function(item) {
				var row = [];
				if (item.icon)
					row.push(item.icon.cloneNode(true));
				row.push(E('span', { 'class': 'ecycloud-drop-item-label' }, [ item.label ]));
				row.push(self.delayHint(item));
				menu.appendChild(self.pressable(
					'ecycloud-drop-item' + (picked(item.value) ? ' is-on' : ''),
					{
						role: 'option',
						click: function(ev) {
							ev.preventDefault();
							ev.stopPropagation();
							if (multiple) {
								var next = [];
								var found = false;
								current.forEach(function(val) {
									if (val == item.value)
										found = true;
									else
										next.push(val);
								});
								if (!found)
									next.push(item.value);
								else if (!next.length && !opts.optional)
									return;
								current = next;
								paint();
								onChange(current.slice());
								return;
							}
							current = item.value;
							open = false;
							paint();
							onChange(item.value);
						}
					},
					row
				));
			});
			if (open)
				self.pinMenu(menu, btn);
		}

		btn.addEventListener('click', function(ev) {
			ev.preventDefault();
			ev.stopPropagation();
			if (opts.disabled)
				return;
			self.findAll('.ecycloud-drop.is-open').forEach(function(face) {
				if (face == btn)
					return;
				face.classList.remove('is-open');
				var box = face.parentNode;
				if (box)
					box.classList.remove('is-open');
				var list = box && box.querySelector('.ecycloud-drop-menu');
				if (list)
					list.style.display = 'none';
			});
			open = !btn.classList.contains('is-open');
			paint();
		});

		if (!this._dropClose) {
			this._dropClose = function(ev) {
				var path = ev.composedPath ? ev.composedPath() : [ ev.target ];
				self.findAll('.ecycloud-drop-wrap').forEach(function(node) {
					if (path.indexOf(node) >= 0)
						return;
					var face = node.querySelector('.ecycloud-drop');
					var list = node.querySelector('.ecycloud-drop-menu');
					node.classList.remove('is-open');
					if (face)
						face.classList.remove('is-open');
					if (list)
						list.style.display = 'none';
				});
			};
			document.addEventListener('click', this._dropClose);
		}

		paint();
		return wrap;
	},

	select: function(group, name) {
		return this.selectRpc(group, name).then(function(res) {
			if (res && typeof res.ok == 'boolean')
				return res;
			return { ok: false, msg: (res && res.msg) || _('Request failed') };
		}).catch(function(err) {
			return { ok: false, msg: (err && err.message) || _('Request failed') };
		});
	},

	isSelector: function(type) {
		return type == 'Selector' || type == 'select';
	},

	signedIn: function(status) {
		return !!(status && status.session && status.session.logged_in);
	},

	signedOut: function() {
		return E('div', { 'class': 'ecycloud-empty' }, [
			E('span', { 'class': 'ecycloud-ico ecycloud-empty-ico', 'data-ico': 'inbox' }),
			E('div', {}, [ _('Not signed in') ])
		]);
	},

	releaseValueTitles: function(root) {
		if (!root || !root.querySelectorAll)
			return;

		root.querySelectorAll('label.cbi-value-title').forEach(function(title) {
			var field = title.nextElementSibling;
			if (field && field.querySelector('input[type="checkbox"], input[type="radio"]'))
				return;

			var node = document.createElement('div');
			node.className = title.className;
			while (title.firstChild)
				node.appendChild(title.firstChild);
			title.parentNode.replaceChild(node, title);
		});
	},

	lockFormRows: function(root) {
		if (!root || !root.querySelectorAll)
			return;

		root.querySelectorAll('.cbi-value').forEach(function(row) {
			var inner;
			var next;

			if (row.querySelector('.ecycloud-form-row'))
				return;

			inner = E('div', { 'class': 'ecycloud-form-row' });
			while (row.firstChild) {
				next = row.firstChild;
				if (next.classList && next.classList.contains('ecycloud-form-row'))
					break;
				inner.appendChild(next);
			}
			row.appendChild(inner);
		});
	},

	shell: function(children, guest) {
		var node = E('div', {
			'id': 'ecycloud-root',
			'class': guest ? 'ecycloud-ui is-guest' : 'ecycloud-ui'
		}, children);
		var self = this;
		var root;

		node.id = 'ecycloud-root';
		this.isolate(node);
		root = this.stage(node);
		this.upgradeChecks(root);
		this.bindSelects(root);
		this.releaseValueTitles(root);
		this.lockFormRows(root);
		this.applyTheme(node);
		this.parkFields(node);
		this.releaseChrome(node);
		this.watchKick();
		this.watchAppUpdate();
		var polish = function() {
			var inner;
			self.sealShadow(node);
			inner = self.stage(node);
			self.upgradeChecks(inner);
			self.bindSelects(inner);
			self.releaseValueTitles(inner);
			self.lockFormRows(inner);
			self.fixPageActions();
			self.parkFields(node);
			self.releaseChrome(node);
		};
		setTimeout(polish, 0);
		setTimeout(polish, 120);
		return node;
	},

	deviceLimitReached: function(account) {
		var limit = +((account && account.node_connector) || 0);
		var count = +((account && account.online_client_count) || 0);
		return limit > 0 && count >= limit && !(account && account.online_client_self);
	},

	onlineDeviceText: function(account) {
		var count = +((account && account.online_client_count) || 0);
		var limit = +((account && account.node_connector) || 0);
		return limit > 0 ? '%d / %d'.format(count, limit) : _('%d / unlimited').format(count);
	},

	deviceLabel: function(device) {
		return (device && device.device) ? device.device : _('Third-party client');
	},

	deviceDetail: function(device) {
		var ip = (device && device.ip) || '';
		var location = (device && device.location) || '';
		return location ? ip + ' · ' + location : ip;
	},

	confirmDeviceLimitKick: function(devices) {
		var choices = (devices || []).filter(function(item) {
			return item && item.device_id;
		}).map(function(item) {
			return {
				value: item.device_id,
				label: item.device || item.device_id,
				detail: this.deviceDetail(item)
			};
		}, this);

		return this.dialog({
			title: _('Online client limit reached'),
			text: choices.length
				? _('The online client limit has been reached. Pick a client to disconnect:')
				: _('The online client limit has been reached. Disconnect one client to make room?'),
			choices: choices,
			value: '',
			cancel: true,
			ok: _('OK')
		});
	},

	connect: function(opts) {
		var self = this;
		opts = opts || {};
		var generation = ++connectGeneration;
		connectPending = generation;
		var cancelled = { ok: false, cancelled: true };
		var limitDenied = opts.forceDeviceLimit === true;

		var withAccount = function(account) {
			if (generation != connectGeneration)
				return cancelled;
			limitDenied = limitDenied || (account.device_kick_notice && account.device_kick_reason == 'limit_denied');
			if (!limitDenied && !self.deviceLimitReached(account))
				return self.start();

			return self.onlineDevices().then(function(res) {
				return res && res.devices ? res.devices : [];
			}, function() {
				return [];
			}).then(function(devices) {
				if (generation != connectGeneration)
					return cancelled;
				return self.confirmDeviceLimitKick(devices).then(function(targetDeviceId) {
					if (targetDeviceId == null || generation != connectGeneration)
						return cancelled;

					return self.reclaimDeviceSlot(targetDeviceId).then(function(reclaim) {
						if (generation != connectGeneration)
							return cancelled;
						if (!reclaim || !reclaim.ok)
							return reclaim || { ok: false, msg: _('Request failed') };
						return self.start();
					});
				});
			});
		};

		var afterProfile = function() {
			return self.refreshAccount().then(function(res) {
				if (!res || !res.ok || !res.account)
					return { ok: false, msg: (res && res.msg) || _('Request failed') };
				return withAccount(res.account);
			});
		};

		var noticeReason = opts.device_kick_reason || (opts.account && opts.account.device_kick_reason);
		var request = limitDenied ? withAccount({})
			: noticeReason != 'limit_denied' && (opts.device_kicked || (opts.account && opts.account.device_kick_notice))
				? this.ackDeviceKick().then(afterProfile, afterProfile) : afterProfile();
		return request.then(function(res) {
			if (limitDenied && res && res.cancelled)
				return self.ackDeviceKick().then(function() { return res; }, function() { return res; });
			return res;
		}).catch(function(err) {
			return { ok: false, msg: err.message || _('Request failed') };
		}).finally(function() {
			if (connectPending == generation)
				connectPending = null;
		});
	},

	watchKick: function() {
		if (kickWatch)
			return;

		kickWatch = true;
		var self = this;
		var tick = function() {
			if (connectPending == connectGeneration)
				return;
			var generation = connectGeneration;
			self.status().then(function(status) {
				if (generation == connectGeneration && status && status.session && status.session.logged_in)
					self.handleDeviceKick(status);
			});
		};

		tick();
		setInterval(tick, 5000);
	},

	handleDeviceKick: function(status) {
		if (kickBusy)
			return;

		if (!(status.device_kicked || (status.account && status.account.device_kick_notice)))
			return;

		var self = this;
		var reason = status.device_kick_reason || (status.account && status.account.device_kick_reason) || '';
		if (reason == 'limit_denied' && connectPending == connectGeneration)
			return;
		kickBusy = true;
		if (reason == 'limit_denied' && !status.enabled)
			return this.ackDeviceKick().finally(function() { kickBusy = false; });
		var phase = this.phase(status);
		var stop = (status.running || phase == 'connecting')
			? this.stop() : Promise.resolve({ ok: true });
		var generation = connectGeneration;

		return stop.then(function(stopped) {
			if (reason == 'limit_denied') {
				if (generation != connectGeneration)
					return self.ackDeviceKick();
				if (!stopped || !stopped.ok)
					return self.notify(stopped || { ok: false });
				return self.connect({ forceDeviceLimit: true }).then(function(res) {
					if (!res.ok && !res.cancelled)
						self.notify(res);
					return res;
				});
			}
			return self.dialog({
				title: _('Device disconnected'),
				text: reason == 'remove'
					? _('This device was removed from the usage list, so it was disconnected.')
					: _('A new client connected after the online client limit was reached, so this device was disconnected.'),
				ok: _('Got it'),
				dismissible: false
			}).then(function() {
				return self.ackDeviceKick();
			});
		}).finally(function() {
			kickBusy = false;
		});
	},

	page: function(name) {
		return L.url('admin/services/ecycloud/' + name);
	},

	stageText: function(status) {
		return status.enabled && status.stage == 'stopped' ? _('Connecting') : stages[status.stage] || status.stage || '-';
	},

	phase: function(status) {
		if (status.stage == 'failed')
			return 'failed';
		if (!status.enabled && status.network_applied)
			return 'disconnecting';
		if (status.enabled && status.running && status.stage == 'running')
			return 'connected';
		if (status.enabled)
			return 'connecting';
		return 'disconnected';
	},

	bytes: function(value) {
		return '%1024.2mB'.format(value || 0);
	},

	bytesCompact: function(value) {
		return this.bytes(value).replace(/\s+/g, '');
	},

	speed: function(value) {
		return _('%s/s').format(this.bytes(value));
	},

	speedSi: function(bytesPerSecond) {
		return (bytesPerSecond / 1000 / 1000).toFixed(1) + ' MB/s';
	},

	duration: function(ms) {
		var seconds = Math.max(0, Math.floor((ms || 0) / 1000));
		var hours = Math.floor(seconds / 3600);
		var minutes = Math.floor((seconds % 3600) / 60);
		var rest = seconds % 60;

		return hours > 0
			? hours + ':' + two(minutes) + ':' + two(rest)
			: two(minutes) + ':' + two(rest);
	},

	elapsed: function(ms) {
		var seconds = Math.max(0, Math.floor((ms || 0) / 1000));
		var years = Math.floor(seconds / (365 * 24 * 3600));
		seconds %= 365 * 24 * 3600;
		var months = Math.floor(seconds / (30 * 24 * 3600));
		seconds %= 30 * 24 * 3600;
		var days = Math.floor(seconds / (24 * 3600));
		seconds %= 24 * 3600;
		var hours = Math.floor(seconds / 3600);
		seconds %= 3600;
		var minutes = Math.floor(seconds / 60);
		seconds %= 60;
		var parts = [];

		if (years)
			parts.push(_('%d years').format(years));
		if (months)
			parts.push(_('%d months').format(months));
		if (days)
			parts.push(_('%d days').format(days));
		if (hours)
			parts.push(_('%d hours').format(hours));
		if (minutes)
			parts.push(_('%d minutes').format(minutes));
		if (seconds || !parts.length)
			parts.push(_('%d seconds').format(seconds));

		return parts.join(' ');
	},

	clock: function(ms) {
		var d = new Date(ms || Date.now());
		return two(d.getHours()) + ':' + two(d.getMinutes()) + ':' + two(d.getSeconds());
	},

	connectedSince: function(running) {
		if (!running) {
			sessionStorage.removeItem(SINCE_KEY);
			return 0;
		}

		var raw = sessionStorage.getItem(SINCE_KEY);

		if (!raw) {
			raw = String(Date.now());
			sessionStorage.setItem(SINCE_KEY, raw);
		}

		return Date.now() - +raw;
	},

	delayText: function(delay) {
		return delay > 0 ? _('%d ms').format(delay) : _('untested');
	},

	delayHint: function(item) {
		if (!item)
			return '';
		if (item.delay > 0)
			return E('span', {
				'class': 'ecycloud-delay' + (item.delay < 200 ? ' is-fast'
					: item.delay < 500 ? ' is-mid' : ' is-slow')
			}, [ String(item.delay) ]);
		if (item.failed)
			return E('span', { 'class': 'ecycloud-delay is-slow' }, [ _('Timeout') ]);
		return '';
	},

	delayBadge: function(item, onTest) {
		var delay = item ? +(item.delay || 0) : 0;
		var testing = !!(item && item.testing);
		var failed = !!(item && item.failed);
		var cls = 'ecycloud-delay';
		var text = '';
		var btn;

		if (testing)
			cls += ' is-testing';
		else if (delay > 0) {
			cls += delay < 200 ? ' is-fast' : delay < 500 ? ' is-mid' : ' is-slow';
			text = String(delay);
		}
		else if (failed) {
			cls += ' is-slow';
			text = _('Timeout');
		}

		btn = (!testing && delay <= 0 && !failed)
			? this.pressable('ecycloud-icon-btn', {
				title: _('Test this node'),
				'aria-label': _('Test this node'),
				'data-ico': 'bolt'
			})
			: this.pressable(cls, {
				title: _('Test this node')
			}, [ text ]);

		btn.addEventListener('click', function(ev) {
			ev.stopPropagation();
			if (btn.classList.contains('is-testing'))
				return;
			btn.className = 'ecycloud-delay is-testing';
			btn.textContent = '';
			onTest(ev);
		});
		return btn;
	},

	speedBadge: function(item, onTest) {
		var bytes = item ? +(item.speed || 0) : 0;
		var testing = !!(item && item.speed_testing);
		var failed = !!(item && item.speed_failed);
		var cls = 'ecycloud-delay';
		var text = '';
		var btn;

		if (testing)
			cls += ' is-testing';
		else if (bytes > 0) {
			cls += bytes >= 5 * 1024 * 1024 ? ' is-fast' : bytes >= 1024 * 1024 ? ' is-mid' : ' is-slow';
			text = this.speedSi(bytes);
		}
		else if (failed) {
			cls += ' is-slow';
			text = _('Failed');
		}

		btn = (!testing && bytes <= 0 && !failed)
			? this.pressable('ecycloud-icon-btn', {
				title: _('Test this node speed'),
				'aria-label': _('Test this node speed'),
				'data-ico': 'speed'
			})
			: this.pressable(cls, {
				title: _('Test this node speed')
			}, [ text ]);

		btn.addEventListener('click', function(ev) {
			ev.stopPropagation();
			if (btn.classList.contains('is-testing'))
				return;
			btn.className = 'ecycloud-delay is-testing';
			btn.textContent = '';
			onTest(ev);
		});
		return btn;
	},

	officialNode: function(name) {
		return /^node-\d+$/.test(name || '');
	},

	sortGroupMembers: function(members, mode) {
		var list = members || [];
		if (mode == 'name' || list.length < 2)
			return list;

		var slots = [];
		var nodes = [];
		list.forEach(function(member, index) {
			if (/^node-\d+$/.test(member.name || '')) {
				slots.push(index);
				nodes.push(member);
			}
		});
		if (nodes.length < 2)
			return list;

		nodes.sort(function(a, b) {
			var aOk;
			var bOk;
			if (mode == 'latency') {
				aOk = +(a.delay || 0) > 0;
				bOk = +(b.delay || 0) > 0;
				if (aOk != bOk)
					return aOk ? -1 : 1;
				if (aOk && a.delay != b.delay)
					return a.delay - b.delay;
			}
			else if (mode == 'speed') {
				aOk = +(a.speed || 0) > 0;
				bOk = +(b.speed || 0) > 0;
				if (aOk != bOk)
					return aOk ? -1 : 1;
				if (aOk && a.speed != b.speed)
					return b.speed - a.speed;
			}
			return String(a.label || a.name).localeCompare(String(b.label || b.name));
		});

		var out = list.slice();
		slots.forEach(function(slot, i) {
			out[slot] = nodes[i];
		});
		return out;
	},

	nextGroupSort: function(mode) {
		return mode == 'name' ? 'latency' : mode == 'latency' ? 'speed' : 'name';
	},

	timestamp: function(seconds) {
		return seconds > 0 ? new Date(seconds * 1000).toLocaleString() : '-';
	},

	viaProxy: function(item) {
		var leaf = String(item.leaf || '').toLowerCase();
		return leaf.length > 0 && !BYPASS[leaf];
	},

	processName: function(item) {
		var name = String(item.process || '');
		var slash = Math.max(name.lastIndexOf('/'), name.lastIndexOf('\\'));

		return slash < 0 ? name : name.slice(slash + 1);
	},

	ingestConnections: function(list) {
		var snapshot = list || [];
		var prev = loadJson(ALIVE_KEY, {});
		var alive = {};
		var closed = loadJson(CLOSED_KEY, []);
		var now = new Date().toISOString();

		if (typeof prev != 'object' || prev == null || Array.isArray(prev))
			prev = {};

		if (!Array.isArray(closed))
			closed = [];

		snapshot.forEach(function(item) {
			if (item.id)
				alive[item.id] = item;
		});

		Object.keys(prev).forEach(function(id) {
			if (!alive[id])
				closed.unshift(Object.assign({}, prev[id], { closed_at: now }));
		});

		if (closed.length > CLOSED_LIMIT)
			closed = closed.slice(0, CLOSED_LIMIT);

		saveJson(ALIVE_KEY, alive);
		saveJson(CLOSED_KEY, closed);

		return { active: snapshot, closed: closed };
	},

	noteTrafficRank: function(item, bytes, skip) {
		var now;
		var today;
		var yest;
		var all;
		var bucket;
		var chains;
		var host;
		var i;
		var name;

		if (!(bytes > 0))
			return;

		now = new Date();
		today = dayKey(now);
		yest = dayKey(neighborDay(now, -1));
		all = loadLocal(RANK_KEY, {});
		if (typeof all != 'object' || all == null || Array.isArray(all))
			all = {};
		bucket = all[today];
		if (typeof bucket != 'object' || bucket == null || Array.isArray(bucket))
			bucket = { groups: {}, hosts: {} };
		if (typeof bucket.groups != 'object' || bucket.groups == null)
			bucket.groups = {};
		if (typeof bucket.hosts != 'object' || bucket.hosts == null)
			bucket.hosts = {};

		chains = item && item.chains ? item.chains : [];
		for (i = 1; i < chains.length; i++) {
			name = String(chains[i] || '');
			if (name)
				bucket.groups[name] = (bucket.groups[name] || 0) + bytes;
		}

		host = String((item && item.host) || '').replace(/^\s+|\s+$/g, '')
			|| String((item && item.destination_ip) || '').replace(/^\s+|\s+$/g, '');
		if (host && !(skip && skip[host.toLowerCase()]))
			bucket.hosts[host] = (bucket.hosts[host] || 0) + bytes;

		all[today] = bucket;
		Object.keys(all).forEach(function(key) {
			if (key != today && key != yest)
				delete all[key];
		});
		saveLocal(RANK_KEY, all);
	},

	trafficRank: function(day, skip) {
		var now = new Date();
		var key = day == 'yesterday' ? dayKey(neighborDay(now, -1)) : dayKey(now);
		var all = loadLocal(RANK_KEY, {});
		var bucket = all && all[key] ? all[key] : {};

		return {
			groups: topRank(bucket.groups),
			hosts: topRank(bucket.hosts, skip)
		};
	},

	rankSkip: function(status) {
		return skipHosts(status && status.profile ? status.profile.servers : []);
	},

	groupsForMode: function(groups, routeMode) {
		if (routeMode == 'direct')
			return [];

		var list = groups || [];

		if (routeMode == 'global') {
			return list.filter(function(group) { return group.name == 'GLOBAL'; });
		}

		return list.filter(function(group) { return group.name != 'GLOBAL'; });
	},

	testGroup: function(group, speed) {
		var name = group && group.name ? group.name : group;
		var field = speed ? 'speed_testing' : 'testing';
		var tests = groupTests[field];
		if (tests.has(name))
			return tests.get(name).request;
		var test = { pending: true };
		tests.set(name, test);
		if (group && group.name)
			group[field] = true;
		test.request = (speed ? this.test_group_speed(name) : this.test_group(name)).then(function(res) {
			if (res && res.ok)
				test.pending = false;
			return res;
		}).finally(function() {
			if (test.pending) {
				tests.delete(name);
				if (group && group.name)
					group[field] = false;
			}
		});
		return test.request;
	},

	testSpeed: function(name) {
		return this.speed_test(name);
	},

	testGroupSpeed: function(group) {
		return this.testGroup(group, true);
	},

	jump: function(href, label, opts) {
		opts = opts || {};
		var attrs = { 'class': 'ecycloud-jump', 'href': href };

		if (opts.external) {
			attrs.target = '_blank';
			attrs.rel = 'noreferrer';
		}

		return E('a', attrs, [ label, ' ›' ]);
	},

	card: function(children, cls) {
		return E('div', { 'class': 'ecycloud-card' + (cls ? ' ' + cls : '') }, children);
	},

	section: function(icon, title, child, action) {
		return E('div', { 'class': 'ecycloud-card' }, [
			E('div', { 'class': 'ecycloud-card-head' }, [
				icon ? E('span', { 'class': 'ecycloud-ico', 'data-ico': icon }) : '',
				E('div', { 'class': 'ecycloud-card-title' }, [ title ]),
				action || ''
			]),
			child
		]);
	},

	pair: function(a, b) {
		return E('div', { 'class': 'ecycloud-pair' }, [ a, b ]);
	},

	segments: function(items, value, onChange) {
		return E('div', { 'class': 'ecycloud-seg' }, items.map(function(item) {
			return this.pressable(
				'ecycloud-seg-btn' + (item.value == value ? ' is-on' : ''),
				{
					click: function(ev) {
						ev.preventDefault();
						if (item.value != value)
							onChange(item.value);
					}
				},
				[ item.label ]
			);
		}, this));
	},

	sparkline: function(samples, color) {
		var width = 240;
		var height = 72;
		var windowMs = 60000;
		var now = Date.now();
		var start = now - windowMs;
		var list = (samples || []).filter(function(item) {
			return item && item.at >= start;
		});
		var peak = 0;
		var i;

		for (i = 0; i < list.length; i++)
			if (list[i].value > peak)
				peak = list[i].value;

		var scale = peak <= 0 ? 0 : height / peak;
		var d = '';

		for (i = 0; i < list.length; i++) {
			var x = ((list[i].at - start) / windowMs) * width;
			var y = height - list[i].value * scale;
			d += (i == 0 ? 'M' : 'L') + x + ' ' + y;
		}

		if (!list.length)
			d = 'M0 ' + height + ' L' + width + ' ' + height;

		var firstX = list.length ? ((list[0].at - start) / windowMs) * width : 0;
		var lastX = list.length ? ((list[list.length - 1].at - start) / windowMs) * width : width;

		var svg = svgEl('svg', {
			viewBox: '0 0 ' + width + ' ' + height,
			preserveAspectRatio: 'none'
		});
		svg.appendChild(svgEl('line', {
			x1: '0', y1: '0', x2: '0', y2: height,
			stroke: 'currentColor', 'stroke-opacity': '0.55'
		}));
		svg.appendChild(svgEl('line', {
			x1: '0', y1: '0', x2: width, y2: '0',
			stroke: 'currentColor', 'stroke-opacity': '0.28'
		}));
		svg.appendChild(svgEl('line', {
			x1: '0', y1: height / 2, x2: width, y2: height / 2,
			stroke: 'currentColor', 'stroke-opacity': '0.28'
		}));
		svg.appendChild(svgEl('line', {
			x1: '0', y1: height, x2: width, y2: height,
			stroke: 'currentColor', 'stroke-opacity': '0.55'
		}));
		if (list.length) {
			svg.appendChild(svgEl('path', {
				d: d + ' L' + lastX + ' ' + height + ' L' + firstX + ' ' + height + ' Z',
				fill: color,
				'fill-opacity': '0.22'
			}));
		}
		svg.appendChild(svgEl('path', {
			d: d,
			fill: 'none',
			stroke: color,
			'stroke-width': '1.6',
			'stroke-linejoin': 'round',
			'stroke-linecap': 'round'
		}));

		var cursor = E('div', { 'class': 'ecycloud-chart-cursor' });
		var tip = E('div', { 'class': 'ecycloud-chart-tip' });
		var plot = E('div', { 'class': 'ecycloud-chart-plot' }, [ svg, cursor, tip ]);
		var self = this;

		function hide() {
			cursor.classList.remove('is-on');
			tip.classList.remove('is-on');
		}

		function inspect(ev) {
			if (!list.length)
				return;

			var rect = plot.getBoundingClientRect();
			var ratio = rect.width <= 0 ? 1 : (ev.clientX - rect.left) / rect.width;
			ratio = Math.max(0, Math.min(1, ratio));
			var target = start + ratio * windowMs;
			var best = 0;
			var bestDelta = Infinity;

			for (i = 0; i < list.length; i++) {
				var delta = Math.abs(list[i].at - target);
				if (delta < bestDelta) {
					best = i;
					bestDelta = delta;
				}
			}

			var point = list[best];
			var left = ((point.at - start) / windowMs) * 100;
			cursor.style.left = left + '%';
			cursor.classList.add('is-on');
			tip.textContent = self.clock(point.at) + '\n' + self.speed(point.value);
			tip.style.left = left + '%';
			tip.style.transform = left < 12
				? 'translateX(0)'
				: left > 88 ? 'translateX(-100%)' : 'translateX(-50%)';
			tip.classList.add('is-on');
		}

		plot.addEventListener('mousemove', inspect);
		plot.addEventListener('mouseleave', hide);

		return E('div', { 'class': 'ecycloud-chart' }, [
			E('div', { 'class': 'ecycloud-chart-y' }, [
				E('span', {}, [ this.speed(peak) ]),
				E('span', {}, [ this.speed(Math.floor(peak / 2)) ]),
				E('span', {}, [ this.speed(0) ])
			]),
			plot,
			E('div', { 'class': 'ecycloud-chart-x' }, [
				E('span', {}, [ this.clock(start) ]),
				E('span', {}, [ this.clock(start + windowMs / 2) ]),
				E('span', {}, [ this.clock(now) ])
			])
		]);
	},

	alert: function(message) {
		document.querySelectorAll('.ecycloud-modal.is-alert').forEach(function(node) {
			if (node.parentNode)
				node.parentNode.removeChild(node);
		});

		/* 与客户端的 AlertDialog 同版式：正文在上、按钮在右下，不再左右并排 */
		var node = E('div', {
			'class': 'ecycloud-modal is-dialog is-alert',
			'data-theme': this.detectTheme()
		}, [
			E('div', { 'class': 'ecycloud-modal-card is-dialog' }, [
				E('div', { 'class': 'ecycloud-modal-title' }, [ _('Notice') ]),
				E('div', { 'class': 'ecycloud-modal-text' }, [ message ]),
				E('div', { 'class': 'ecycloud-modal-actions' }, [
					this.pressable('ecycloud-modal-ok', {}, [ _('Got it') ])
				])
			])
		]);

		var close = function() {
			if (node.parentNode)
				node.parentNode.removeChild(node);
		};

		node.querySelector('.ecycloud-modal-ok').addEventListener('click', close);
		this.onBackdrop(node, close);
		document.body.appendChild(node);
		this.isolate(node);
		return node;
	},

	showText: function(title, text) {
		document.querySelectorAll('.ecycloud-modal.is-textview').forEach(function(node) {
			if (node.parentNode)
				node.parentNode.removeChild(node);
		});

		var body = text || '';
		try {
			if (/^\s*[\[{]/.test(body))
				body = JSON.stringify(JSON.parse(body), null, 2);
		}
		catch (e) {}

		var node = E('div', {
			'class': 'ecycloud-modal is-dialog is-textview',
			'data-theme': this.detectTheme()
		}, [
			E('div', { 'class': 'ecycloud-modal-card is-dialog is-wide' }, [
				E('div', { 'class': 'ecycloud-modal-title' }, [ title ]),
				E('pre', { 'class': 'ecycloud-textview' }, [ body ]),
				E('div', { 'class': 'ecycloud-modal-actions' }, [
					this.pressable('ecycloud-modal-ok', {}, [ _('Got it') ])
				])
			])
		]);

		var close = function() {
			if (node.parentNode)
				node.parentNode.removeChild(node);
		};

		node.querySelector('.ecycloud-modal-ok').addEventListener('click', close);
		this.onBackdrop(node, close);
		document.body.appendChild(node);
		this.isolate(node);
		return node;
	},

	dialog: function(opts) {
		opts = opts || {};
		var self = this;

		document.querySelectorAll('.ecycloud-modal.is-dialog').forEach(function(node) {
			if (node.parentNode)
				node.parentNode.removeChild(node);
		});

		return new Promise(function(resolve) {
			var choices = opts.choices || [];
			var selected = choices.length ? choices[0].value : '';
			var body = [];

			if (opts.title)
				body.push(E('div', { 'class': 'ecycloud-modal-title' }, [ opts.title ]));

			if (opts.text)
				body.push(E('div', { 'class': 'ecycloud-modal-text' }, [ opts.text ]));

			var list = null;
			if (choices.length) {
				list = E('div', { 'class': 'ecycloud-modal-choices' });
				body.push(list);
			}

			var perItem = !!opts.action;
			var actions = E('div', { 'class': 'ecycloud-modal-actions' });
			/* 与客户端一致：主操作在左、取消在右 */
			if (!perItem)
				actions.appendChild(self.pressable('ecycloud-modal-ok', {}, [ opts.ok || _('OK') ]));
			if (opts.cancel)
				actions.appendChild(self.pressable('ecycloud-modal-cancel', {}, [ _('Cancel') ]));
			if (actions.firstChild)
				body.push(actions);

			var node = E('div', {
				'class': 'ecycloud-modal is-dialog',
				'data-theme': self.detectTheme()
			}, [
				E('div', { 'class': 'ecycloud-modal-card is-dialog' }, body)
			]);

			var done = function(value) {
				if (node.parentNode)
					node.parentNode.removeChild(node);
				resolve(value);
			};

			function paintChoices() {
				if (!list)
					return;

				while (list.firstChild)
					list.removeChild(list.firstChild);

				choices.forEach(function(item) {
					var info = E('span', { 'class': 'ecycloud-modal-choice-body' }, [
						E('span', { 'class': 'ecycloud-modal-choice-label' }, [ item.label ]),
						item.detail
							? E('span', { 'class': 'ecycloud-modal-choice-detail' }, [ item.detail ])
							: ''
					]);

					if (perItem) {
						var open = self.pressable('ecycloud-modal-ok', {}, [ opts.action ]);
						open.addEventListener('click', function() {
							if (opts.onAction)
								opts.onAction(item);
						});
						list.appendChild(E('div', {
							'class': 'ecycloud-modal-choice is-action'
						}, [ info, open ]));
						return;
					}

					list.appendChild(E('label', {
						'class': 'ecycloud-modal-choice' + (item.value == selected ? ' is-on' : '')
					}, [
						E('input', {
							'type': 'radio',
							'name': 'ecycloud-dialog-choice',
							'value': item.value,
							'checked': item.value == selected ? 'checked' : null
						}),
						info
					]));
				});

				list.querySelectorAll('input[type="radio"]').forEach(function(input) {
					input.addEventListener('change', function() {
						selected = input.value;
						paintChoices();
					});
				});
			}

			paintChoices();

			var cancelBtn = node.querySelector('.ecycloud-modal-cancel');
			if (cancelBtn)
				cancelBtn.addEventListener('click', function() {
					done(null);
				});

			var okBtn = node.querySelector('.ecycloud-modal-actions .ecycloud-modal-ok');
			if (okBtn)
				okBtn.addEventListener('click', function() {
					done(choices.length ? selected : (opts.value === undefined ? true : opts.value));
				});

			if (opts.dismissible !== false)
				self.onBackdrop(node, function() {
					done(null);
				});

			document.body.appendChild(node);
			self.isolate(node);
		});
	},

	notify: function(result, success) {
		var message = result.msg || (result.ok ? success : _('Request failed'));
		if (!result.ok && this.isProfileFormatError(message)) {
			this.alertProfileFormat(message);
			return result;
		}
		this.alert(message, result.ok ? 'info' : 'warning');
		return result;
	},

	closeAnnounce: function() {
		document.querySelectorAll('.ecycloud-modal.is-announce').forEach(function(node) {
			if (node.parentNode)
				node.parentNode.removeChild(node);
		});
	},

	announceHtml: function(html, site) {
		var box = E('div', { 'class': 'ecycloud-ann-html' });
		var scratch = document.createElement('div');
		scratch.innerHTML = String(html || '');
		scratch.querySelectorAll(
			'script,iframe,object,embed,form,input,button,select,textarea,style,link,meta,base,svg,math,applet,frame,frameset'
		).forEach(function(node) {
			if (node.parentNode)
				node.parentNode.removeChild(node);
		});
		scratch.querySelectorAll('*').forEach(function(node) {
			for (var i = node.attributes.length - 1; i >= 0; i--) {
				var name = node.attributes[i].name;
				var value = node.getAttribute(name) || '';
				if (/^on/i.test(name) || name == 'srcdoc' ||
					((name == 'href' || name == 'src' || name == 'xlink:href') &&
						/^\s*javascript:/i.test(value)))
					node.removeAttribute(name);
			}
		});
		scratch.querySelectorAll('a[href], img[src], video[src], source[src]').forEach(function(node) {
			var attr = node.hasAttribute('href') ? 'href' : 'src';
			var url = String(node.getAttribute(attr) || '').trim();
			if (url.charAt(0) == '/' && site)
				node.setAttribute(attr, String(site).replace(/\/$/, '') + url);
		});
		scratch.querySelectorAll('a[href]').forEach(function(node) {
			node.setAttribute('target', '_blank');
			node.setAttribute('rel', 'noreferrer');
		});
		box.innerHTML = scratch.innerHTML;
		return box;
	},

	announcePopup: function(item, opts) {
		opts = opts || {};
		this.closeAnnounce();

		var body = [
			E('div', { 'class': 'ecycloud-modal-title' }, [ item.title || _('Announcements') ])
		];

		if (item.id != 1 && item.date)
			body.push(E('div', { 'class': 'ecycloud-ann-date' }, [ item.date ]));

		body.push(this.announceHtml(item.content, opts.site));
		body.push(E('div', { 'class': 'ecycloud-modal-actions' }, [
			this.pressable('ecycloud-modal-ok', {}, [ _('Got it') ])
		]));

		var node = E('div', {
			'class': 'ecycloud-modal is-dialog is-announce',
			'data-theme': this.detectTheme()
		}, [
			E('div', { 'class': 'ecycloud-modal-card is-dialog is-announce' }, body)
		]);

		var done = function(gotIt) {
			if (node.parentNode)
				node.parentNode.removeChild(node);
			if (opts.onClose)
				opts.onClose(gotIt);
		};

		node.querySelector('.ecycloud-modal-ok').addEventListener('click', function() {
			done(true);
		});
		this.onBackdrop(node, function() {
			done(false);
		});
		document.body.appendChild(node);
		this.isolate(node);
		return node;
	},

	announceBrowser: function(opts) {
		opts = opts || {};
		this.closeAnnounce();

		var self = this;
		var items = opts.items || [];
		var index = items.length
			? Math.max(0, Math.min(+(opts.index || 0), items.length - 1))
			: 0;
		var card = E('div', { 'class': 'ecycloud-modal-card is-dialog is-announce' });
		var node = E('div', {
			'class': 'ecycloud-modal is-dialog is-announce',
			'data-theme': this.detectTheme()
		}, [ card ]);

		var done = function() {
			if (node.parentNode)
				node.parentNode.removeChild(node);
			if (opts.onClose)
				opts.onClose();
		};

		var paint = function() {
			var nodes = [];

			if (!items.length) {
				nodes.push(E('div', { 'class': 'ecycloud-modal-title' }, [ _('Announcements') ]));
				if (!opts.loaded && opts.busy)
					nodes.push(E('div', { 'class': 'ecycloud-ann-spin' }));
				else
					nodes.push(E('div', { 'class': 'ecycloud-modal-text' }, [
						opts.error || (opts.loaded
							? _('No announcements')
							: _('Unable to load announcements. Try again later.'))
					]));
				nodes.push(E('div', { 'class': 'ecycloud-modal-actions' }, [
					self.pressable('ecycloud-modal-cancel', {}, [ _('Close') ])
				]));
			}
			else {
				var item = items[index];
				nodes.push(E('div', { 'class': 'ecycloud-modal-title' }, [
					item.title || _('Announcements')
				]));
				if (item.id != 1 && item.date)
					nodes.push(E('div', { 'class': 'ecycloud-ann-date' }, [ item.date ]));
				nodes.push(self.announceHtml(item.content, opts.site));
				if (items.length > 1) {
					nodes.push(E('div', { 'class': 'ecycloud-ann-nav' }, [
						self.pressable('ecycloud-modal-cancel', { 'data-ann': 'prev' }, [ _('Previous') ]),
						E('span', { 'class': 'ecycloud-ann-count' }, [
							(index + 1) + ' / ' + items.length
						]),
						self.pressable('ecycloud-modal-cancel', { 'data-ann': 'next' }, [ _('Next') ])
					]));
				}
				nodes.push(E('div', { 'class': 'ecycloud-modal-actions' }, [
					self.pressable('ecycloud-modal-cancel', {}, [ _('Close') ])
				]));
			}

			while (card.firstChild)
				card.removeChild(card.firstChild);
			nodes.forEach(function(child) {
				card.appendChild(child);
			});

			var prev = card.querySelector('[data-ann="prev"]');
			var next = card.querySelector('[data-ann="next"]');
			if (prev)
				prev.addEventListener('click', function() {
					index = (index - 1 + items.length) % items.length;
					paint();
				});
			if (next)
				next.addEventListener('click', function() {
					index = (index + 1) % items.length;
					paint();
				});
			card.querySelector('.ecycloud-modal-actions .ecycloud-modal-cancel')
				.addEventListener('click', done);
		};

		document.body.appendChild(node);
		paint();
		this.onBackdrop(node, done);
		this.isolate(node);
		return node;
	}
});
