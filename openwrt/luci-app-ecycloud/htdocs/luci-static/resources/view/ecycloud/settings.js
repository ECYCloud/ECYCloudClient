'use strict';
'require view';
'require form';
'require tools.widgets as widgets';

return view.extend({
	render: function() {
		var m, s, o;

		m = new form.Map('ecycloud', _('ECY Cloud'),
			_('Transparent proxy settings. Saving restarts the service, connections are dropped for a moment.'));

		s = m.section(form.NamedSection, 'config', 'ecycloud');
		s.addremove = false;

		s.tab('general', _('General'));
		s.tab('ports', _('Ports'));
		s.tab('advanced', _('Advanced'));

		o = s.taboption('general', form.ListValue, 'mode', _('Proxy mode'));
		o.value('tproxy', _('TPROXY'));
		o.value('tun', _('TUN'));
		o.rmempty = false;

		o = s.taboption('general', widgets.NetworkSelect, 'lan_interface', _('LAN interfaces'),
			_('Traffic from these interfaces is sent to the kernel.'));
		o.multiple = true;
		o.nocreate = true;
		o.rmempty = false;

		o = s.taboption('general', form.Flag, 'dns_hijack', _('Hijack DNS'),
			_('Redirect port 53 of LAN clients and point dnsmasq at the kernel resolver.'));
		o.default = '1';
		o.rmempty = false;

		o = s.taboption('general', form.Flag, 'router_proxy', _('Proxy the router itself'),
			_('Also send traffic originating on the router through the kernel.'));
		o.default = '0';
		o.rmempty = false;

		o = s.taboption('general', form.Flag, 'ipv6', _('IPv6'),
			_('Handle IPv6 traffic as well.'));
		o.default = '1';
		o.rmempty = false;

		o = s.taboption('general', form.Value, 'refresh_interval', _('Profile refresh'),
			_('Minutes between panel checks, 0 disables the periodic check.'));
		o.datatype = 'uinteger';
		o.rmempty = false;

		o = s.taboption('ports', form.Value, 'mixed_port', _('Mixed port'),
			_('HTTP and SOCKS proxy port of the kernel.'));
		o.datatype = 'port';
		o.rmempty = false;

		o = s.taboption('ports', form.Value, 'tproxy_port', _('TPROXY port'));
		o.datatype = 'port';
		o.depends('mode', 'tproxy');
		o.rmempty = false;

		o = s.taboption('ports', form.Value, 'dns_port', _('DNS port'),
			_('Loopback port the kernel resolver listens on.'));
		o.datatype = 'port';
		o.rmempty = false;

		o = s.taboption('ports', form.Flag, 'allow_lan', _('Allow LAN'),
			_('Let LAN clients use the mixed port directly.'));
		o.default = '1';
		o.rmempty = false;

		o = s.taboption('advanced', form.ListValue, 'log_level', _('Log level'));
		o.value('silent', _('Silent'));
		o.value('error', _('Error'));
		o.value('warning', _('Warning'));
		o.value('info', _('Info'));
		o.value('debug', _('Debug'));
		o.rmempty = false;

		o = s.taboption('advanced', form.Value, 'tun_device', _('TUN device'));
		o.depends('mode', 'tun');
		o.rmempty = false;

		o = s.taboption('advanced', form.ListValue, 'tun_stack', _('TUN stack'));
		o.value('mixed', _('Mixed'));
		o.value('system', _('System'));
		o.value('gvisor', _('gVisor'));
		o.depends('mode', 'tun');
		o.rmempty = false;

		o = s.taboption('advanced', form.Value, 'geox_base', _('GeoData mirror'),
			_('Base URL for geoip.metadb and GeoSite.dat. Leave empty to keep the URLs sent by the panel.'));
		o.placeholder = 'https://rules.ecydy.com/Clash';

		return m.render();
	}
});
