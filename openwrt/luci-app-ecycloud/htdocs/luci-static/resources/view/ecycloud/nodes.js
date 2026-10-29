'use strict';
'require view';
'require dom';
'require poll';
'require ui';
'require ecycloud.api as api';

return view.extend({
	handleSave: null,
	handleSaveApply: null,
	handleReset: null,

	load: function() {
		return api.status().then(function(status) {
			if (!api.signedIn(status))
				return [ { groups: [] }, status ];

			return api.groups().then(function(groups) {
				return [ groups, status ];
			});
		});
	},

	refresh: function() {
		if (api.menuOpen())
			return Promise.resolve();

		return this.load().then(L.bind(this.update, this));
	},

	update: function(data) {
		var status = data[1] || {};
		this.routeMode = status.route_mode || 'rule';
		var header = document.querySelector('header');
		var top = 0;
		if (header) {
			var style = window.getComputedStyle(header);
			if (style.position == 'fixed' || style.position == 'sticky')
				top = Math.max(0, header.getBoundingClientRect().height + (parseFloat(style.top) || 0));
		}
		this.body.style.setProperty('--ecy-group-top', top + 'px');

		if (!api.signedIn(status)) {
			this.groups = [];
			dom.content(this.body, api.signedOut());
			return;
		}

		var reply = data[0] || {};
		var previous = new Map((this.groups || []).map(function(group) { return [ group.name, group ]; }));
		this.groups = (reply.groups || []).map(function(group) {
			var saved = previous.get(group.name);
			if (!saved || saved.type != group.type)
				return group;
			var members = new Map(saved.members.map(function(member) { return [ member.name, member ]; }));
			var updated = group.members.map(function(member) {
				return Object.assign(members.get(member.name) || {}, member);
			});
			return Object.assign(saved, group, { members: updated });
		});
		var content = this.renderGroups(Object.assign({}, reply, { groups: this.groups }));
		if (this.body.firstChild)
			this.patchNode(this.body.firstChild, content);
		else
			this.body.appendChild(content);
		this.focusPendingSearch();
		this.warmFlags(reply.flag_regex);
	},

	warmFlags: function(regex) {
		var names = [];
		var generation = (this.flagGeneration || 0) + 1;

		(this.groups || []).forEach(function(group) {
			(group.members || []).forEach(function(member) {
				if (member.label)
					names.push(member.label);
				if (member.via_label)
					names.push(member.via_label);
			});
		});
		this.flagGeneration = generation;
		return api.warmFlags(names, regex).then(L.bind(function(changed) {
			if (changed && generation == this.flagGeneration)
				this.repaint();
		}, this));
	},

	repaint: function() {
		if (!this.body)
			return;

		var content = this.renderGroups({ groups: this.groups || [] });
		if (this.body.firstChild)
			this.patchNode(this.body.firstChild, content);
		else
			this.body.appendChild(content);
		this.focusPendingSearch();
	},

	focusPendingSearch: function() {
		var name = this.pendingSearchFocus;
		var fields;
		var i;

		if (!name || !this.body)
			return;

		this.pendingSearchFocus = '';
		fields = this.body.querySelectorAll('[data-ecy-search]');
		for (i = 0; i < fields.length; i++) {
			if (fields[i].getAttribute('data-ecy-search') == name) {
				fields[i].focus();
				return;
			}
		}
	},

	memberShown: function(member) {
		return member.label || member.name || '';
	},

	patchNode: function(current, next) {
		if (current.nodeType != next.nodeType || current.nodeName != next.nodeName ||
			(current.nodeType == 1 && current.getAttribute('data-ecy-key') != next.getAttribute('data-ecy-key'))) {
			current.replaceWith(next);
			return;
		}
		if (current.nodeType != 1) {
			if (current.nodeValue != next.nodeValue)
				current.nodeValue = next.nodeValue;
			return;
		}
		Array.from(current.attributes).forEach(function(attr) {
			if (!next.hasAttribute(attr.name))
				current.removeAttribute(attr.name);
		});
		Array.from(next.attributes).forEach(function(attr) {
			if (current.getAttribute(attr.name) != attr.value)
				current.setAttribute(attr.name, attr.value);
		});
		var keyed = new Map();
		Array.from(current.children).forEach(function(child) {
			if (child.hasAttribute('data-ecy-key'))
				keyed.set(child.getAttribute('data-ecy-key'), child);
		});
		var children = Array.from(next.childNodes);
		children.forEach(L.bind(function(child, index) {
			var key = child.nodeType == 1 ? child.getAttribute('data-ecy-key') : null;
			var saved = key != null ? keyed.get(key) : current.childNodes[index];
			var position = current.childNodes[index] || null;
			if (!saved)
				current.insertBefore(child, position);
			else {
				if (saved != position) {
					if (current.moveBefore)
						current.moveBefore(saved, position);
					else
						current.insertBefore(saved, position);
				}
				this.patchNode(saved, child);
			}
		}, this));
		while (current.childNodes.length > children.length)
			current.lastChild.remove();
	},

	renderGroups: function(data) {
		var groups = api.groupsForMode(data.groups || [], this.routeMode);

		if (!groups.length)
			return E('div', { 'class': 'ecycloud-empty' }, [
				E('span', { 'class': 'ecycloud-ico ecycloud-empty-ico',
					'data-ico': this.routeMode == 'direct' ? 'tower' : 'inbox' }),
				E('div', {}, [
					this.routeMode == 'direct' ? _('Direct')
						: api.messageText(data.error || _('The panel did not publish any node groups.'))
				])
			]);

		if (this.routeMode == 'global' && !this.openedGlobal) {
			this.openedGlobal = true;
			groups.forEach(L.bind(function(group) {
				this.open[group.name] = true;
			}, this));
		}

		return E('div', { 'class': 'ecycloud-groups' },
			groups.map(L.bind(this.renderGroup, this)));
	},

	leafName: function(member) {
		return member.via || member.name;
	},

	renderGroup: function(group) {
		var opened = this.open[group.name] === true;
		var selectable = api.isSelector(group.type);
		var testing = !!group.testing;
		var sortMode = this.sort[group.name] || 'name';
		var speedTesting = !!group.speed_testing;
		var testBtn = api.pressable('ecycloud-icon-btn' + (testing ? ' is-testing' : ''), {
			title: _('Test all nodes in this group'),
			'aria-label': _('Test all nodes in this group'),
			'data-ico': 'bolt'
		});
		var speedBtn = api.pressable('ecycloud-icon-btn' + (speedTesting ? ' is-testing' : ''), {
			title: _('Test all nodes in this group speed'),
			'aria-label': _('Test all nodes in this group speed'),
			'data-ico': 'speed'
		});
		var sortBtn = api.pressable('ecycloud-icon-btn', {
			title: sortMode == 'name'
				? _('Currently sorted by name. Tap to sort by lowest latency')
				: sortMode == 'latency'
					? _('Currently sorted by lowest latency. Tap to sort by highest speed')
					: _('Currently sorted by highest speed. Tap to sort by name'),
			'data-ico': sortMode == 'name' ? 'sort-alpha' : sortMode == 'latency' ? 'sort-delay' : 'sort-speed'
		});
		var searching = !!this.searchOpen[group.name];
		var query = searching ? (this.query[group.name] || '') : '';
		var searchBtn = api.pressable('ecycloud-icon-btn' + (searching ? ' is-on' : ''), {
			title: _('Search node name'),
			'aria-label': _('Search node name'),
			'aria-pressed': searching ? 'true' : 'false',
			'data-ico': 'search'
		});
		var locateBtn = api.pressable('ecycloud-icon-btn', {
			title: _('Locate selected node'),
			'data-ico': 'locate',
			disabled: !group.now
		});
		var members = api.sortGroupMembers(group.members, sortMode).filter(L.bind(function(member) {
			if (!query)
				return true;
			return String(this.memberShown(member)).toLowerCase().indexOf(query) != -1;
		}, this));
		var hint = '';
		var searchRow = '';
		var list;

		if (!selectable)
			hint = E('div', { 'class': 'ecycloud-group-hint', 'data-ecy-key': 'hint' }, [
				group.type == 'Fallback'
					? _('This group is selected by the kernel in list order; tapping a node does not change the selection. Testing latency refreshes availability and lets the kernel reselect immediately')
					: _('This group is selected by the kernel by latency; tapping a node does not change the selection. Testing latency lets the kernel reselect immediately')
			]);

		if (searching) {
			searchRow = E('div', { 'class': 'ecycloud-group-search', 'data-ecy-key': 'search' }, [
				api.input({
					placeholder: _('Search node name'),
					value: this.searchText[group.name] || '',
					autocomplete: 'off',
					input: L.bind(function(ev) {
						var text = ev.target.value;
						this.searchText[group.name] = text;
						this.query[group.name] = text.trim().toLowerCase();
						this.repaint();
					}, this)
				})
			]);
			searchRow.firstChild.setAttribute('data-ecy-key', 'search-input');
			searchRow.firstChild.setAttribute('data-ecy-search', group.name);
		}

		list = query && !members.length
			? E('div', { 'class': 'ecycloud-group-empty', 'data-ecy-key': 'empty' }, [
				_('No matching nodes')
			])
			: E('div', { 'class': 'ecycloud-node-grid', 'data-ecy-key': 'nodes' },
				members.map(L.bind(this.renderMember, this, group)));

		var bodyChildren = [];
		if (searchRow)
			bodyChildren.push(searchRow);
		if (hint)
			bodyChildren.push(hint);
		bodyChildren.push(list);

		var body = E('div', { 'class': 'ecycloud-group-body' }, bodyChildren);
		var card = E('div', {
			'class': 'ecycloud-group' + (opened ? ' is-open' : ''),
			'data-ecy-key': JSON.stringify([ group.name, group.type ])
		}, [
			E('div', { 'class': 'ecycloud-group-head' }, [
				api.groupMark(group.icon, selectable),
				E('div', { 'class': 'ecycloud-group-title' }, [
					E('div', { 'class': 'ecycloud-group-name' }, [ group.label || group.name ]),
					E('span', { 'class': 'ecycloud-tag' }, [
						selectable ? _('manual') : _('automatic')
					]),
					E('div', { 'class': 'cbi-section-descr' }, (function() {
						var now = group.now_label
							? (group.now_via_label
								? api.nodeLabel(group.now_label) + ' → ' + api.nodeLabel(group.now_via_label)
								: api.nodeLabel(group.now_label))
							: '';
						var line = now
							? _('%d nodes · current %s').format(group.members.length, now)
							: _('%d nodes').format(group.members.length);
						var parts = String(line).split(' · ');
						return [
							E('span', { 'class': 'ecycloud-group-count' }, [ parts[0] || line ]),
							parts[1] ? E('span', { 'class': 'ecycloud-group-sep' }, [ ' · ' ]) : '',
							parts[1] ? E('span', { 'class': 'ecycloud-group-now' }, [ parts[1] ]) : ''
						];
					})())
				]),
				testBtn,
				speedBtn,
				sortBtn,
				searchBtn,
				locateBtn,
				E('span', { 'class': 'ecycloud-group-chevron' })
			]),
			body
		]);

		if (!opened)
			body.style.display = 'none';

		testBtn.addEventListener('click', L.bind(function(ev) {
			ev.stopPropagation();
			if (group.testing)
				return;

			testBtn.classList.add('is-testing');
			api.testGroup(group).then(L.bind(function(res) {
				if (res && !res.ok)
					api.notify(res);
				return this.refresh();
			}, this));
		}, this));

		speedBtn.addEventListener('click', L.bind(function(ev) {
			ev.stopPropagation();
			if (group.speed_testing)
				return;

			speedBtn.classList.add('is-testing');
			api.testGroupSpeed(group).then(L.bind(function(res) {
				if (res && (!res.ok || res.msg))
					api.notify(res);
				return this.refresh();
			}, this));
		}, this));

		sortBtn.addEventListener('click', L.bind(function(ev) {
			ev.stopPropagation();
			this.sort[group.name] = api.nextGroupSort(this.sort[group.name] || 'name');
			return this.refresh();
		}, this));

		searchBtn.addEventListener('click', L.bind(function(ev) {
			ev.stopPropagation();
			var open = !this.searchOpen[group.name];
			this.searchOpen[group.name] = open;
			if (open) {
				this.open[group.name] = true;
				this.pendingSearchFocus = group.name;
			}
			this.repaint();
		}, this));

		locateBtn.addEventListener('click', L.bind(function(ev) {
			ev.stopPropagation();
			this.open[group.name] = true;
			card.classList.add('is-open');
			body.style.display = '';
			var selected = card.querySelector('.ecycloud-node.is-selected');
			if (selected)
				selected.scrollIntoView({ behavior: 'smooth', block: 'center' });
		}, this));

		card.firstElementChild.addEventListener('click', L.bind(function() {
			var next = !this.open[group.name];
			this.open[group.name] = next;
			card.classList.toggle('is-open', next);
			body.style.display = next ? '' : 'none';
		}, this));

		return card;
	},

	renderMember: function(group, member) {
		var selectable = api.isSelector(group.type);
		var selected = member.name == group.now;
		var chips = [];
		var delayBtn = api.delayBadge(member, L.bind(function() {
			api.delay(this.leafName(member)).then(L.bind(function(res) {
				if (res && !res.ok)
					api.notify(res);
				return this.refresh();
			}, this));
		}, this));
		var speedBtn = api.speedBadge(member, L.bind(function() {
			api.testSpeed(this.leafName(member)).then(L.bind(function(res) {
				if (res && !res.ok)
					api.notify(res);
				return this.refresh();
			}, this));
		}, this));

		var region = api.flagCode(member.via_label || member.label);
		var flag = api.flagImg(region);

		if (member.via_label)
			chips.push(E('span', { 'class': 'ecycloud-node-via' }, [
				flag || '', E('span', {}, [ api.nodeLabel(member.via_label) ])
			]));
		else
			[ member.protocol, (member.network || '').toUpperCase(), member.tls, member.udp ].forEach(function(tag) {
				if (tag)
					chips.push(E('span', { 'class': 'ecycloud-tag' }, [ tag ]));
			});

		var node = E('div', {
			'class': 'ecycloud-node' + (selected ? ' is-selected' : '') + (selectable ? '' : ' is-readonly'),
			'data-ecy-key': member.name
		}, [
			E('div', { 'class': 'ecycloud-node-info' }, [
				E('div', { 'class': 'ecycloud-node-name' }, [
					selected ? E('span', { 'class': 'ecycloud-node-check' }) : '',
					member.via_label ? '' : (flag || ''),
					E('span', { 'class': 'ecycloud-node-label', title: member.label }, [ api.nodeLabel(member.label) ]),
					member.is_group ? E('span', { 'class': 'ecycloud-tag' }, [
						member.group_selectable ? _('manual') : _('automatic')
					]) : ''
				]),
				chips.length ? E('div', { 'class': 'ecycloud-tags' }, chips) : ''
			]),
			E('div', { 'class': 'ecycloud-node-actions' }, [ delayBtn, speedBtn ])
		]);

		if (selectable)
			node.addEventListener('click', ui.createHandlerFn(this, 'handleSelect', group.name, member.name));

		return node;
	},

	handleSelect: function(group, member) {
		return api.select(group, member).then(L.bind(function(res) {
			if (res && !res.ok)
				api.notify(res);
			return this.refresh();
		}, this));
	},

	render: function(data) {
		var self = this;

		return api.ensureStyle().then(function() {
			if (!api.signedIn(data[1]))
				return api.shell([ api.signedOut() ], true);

			api.ensureKernel();
			self.body = E('div', {});
			self.open = {};
			self.sort = {};
			self.searchOpen = {};
			self.searchText = {};
			self.query = {};
			self.update(data);
			poll.add(L.bind(self.refresh, self), 2);
			var refreshBtn = api.pressable('ecycloud-icon-btn', {
				title: _('Refresh nodes'),
				'aria-label': _('Refresh nodes')
			});

			refreshBtn.addEventListener('click', function() {
				if (self.refreshingProfile)
					return;

				self.refreshingProfile = true;
				refreshBtn.classList.add('is-refreshing');
				api.update().then(function(res) {
					if (!res.ok)
						api.notify(res, api.profileNotice(res));
					return self.refresh();
				}).finally(function() {
					self.refreshingProfile = false;
					refreshBtn.classList.remove('is-refreshing');
				});
			});

			return api.shell([
				E('div', { 'class': 'ecycloud-toolbar is-end' }, [ refreshBtn ]),
				self.body
			]);
		});
	}
});
