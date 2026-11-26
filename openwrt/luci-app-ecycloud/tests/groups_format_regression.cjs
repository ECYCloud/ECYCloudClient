'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

const resources = process.argv[2] || path.join(__dirname, '../htdocs/luci-static/resources');
const source = fs.readFileSync(path.join(resources, 'ecycloud/api.js'), 'utf8');

const member = (name, extra) => Object.assign({
    name, label: name, type: 'Shadowsocks', protocol: 'Shadowsocks', network: '', tls: '', udp: 'UDP', is_group: false,
    group_selectable: false, via: '', via_label: '', delay: 0, testing: false, failed: false, speed: 0,
    speed_testing: false, speed_failed: false
}, extra);
const legacyMembers = [
    member('自动选择', { label: '自动选择', type: 'URLTest', protocol: '', udp: '', is_group: true, via: 'node-2', via_label: '🇯🇵 日本 02', delay: 88 }),
    member('手动', { type: 'Selector', protocol: '', udp: '', is_group: true, group_selectable: true, via: 'node-3', via_label: '美国 03' }),
    member('node-10', { label: '🇭🇰 香港 10', delay: 120, speed: 2500000 }),
    member('node-2', { label: '🇯🇵 日本 02', network: 'ws', tls: 'TLS', udp: 'XUDP', delay: 88, testing: true }),
    member('node-3', { label: '美国 03', failed: true, speed_failed: true }),
    member('node-4', { label: '新加坡 04', udp: '', speed_testing: true })
];
const legacy = () => JSON.parse(JSON.stringify({
    flag_regex: '(香港|日本)', testing: true,
    groups: [
        { name: '主节点', label: 'Main', icon: '', type: 'Selector', now: 'node-2', now_label: '🇯🇵 日本 02', now_via_label: '',
            testing: false, speed_testing: false, members: legacyMembers },
        { name: '自动选择', label: '自动选择', icon: '', type: 'URLTest', now: 'node-2', now_label: '🇯🇵 日本 02', now_via_label: '',
            testing: true, speed_testing: false, members: legacyMembers.slice(2) },
        { name: '空分组', label: '空分组', icon: '', type: 'Selector', now: '', now_label: '', now_via_label: '',
            testing: false, speed_testing: false, members: [] }
    ]
}));
const compact = () => {
    const data = legacy();
    data.nodes = {};
    for (const group of data.groups) {
        group.members = group.members.map(item => {
            data.nodes[item.name] = Object.fromEntries(Object.entries(item).filter(([key, value]) =>
                key != 'name' && value !== '' && value !== false && value !== 0));
            return item.name;
        });
    }
    return data;
};

async function main() {
    const reply = compact();
    assert.ok(!('network' in reply.nodes['node-10']) && reply.nodes['node-2'].network == 'ws' &&
        Object.keys(reply.nodes).length == 6, '夹具必须是每个节点只出现一次、默认值省略的新格式');
    const defaults = source.slice(source.indexOf('var memberDefaults = {'), source.indexOf('var groupsRequest'));
    const method = source.slice(source.indexOf('\tgroups: function(search) {'), source.indexOf('\n\tlogs: declare('));
    const api = vm.runInNewContext(defaults + 'var groupsRequest = 0, groupsResponse = 0, groupsData;' +
        'var groupTests = { testing: new Map(), speed_testing: new Map() }; ({' + method + '})', { groupsRpc: async () => compact() });
    const restored = JSON.parse(JSON.stringify(await api.groups()));
    delete restored.nodes;
    assert.deepEqual(restored, legacy(), '按名字查表后，各分组成员必须还原成与旧格式逐字段相同的对象');
    const failed = vm.runInNewContext(defaults + 'var groupsRequest = 0, groupsResponse = 0, groupsData;' +
        'var groupTests = { testing: new Map(), speed_testing: new Map() }; ({' + method + '})',
    { groupsRpc: async () => ({ error: '节点与策略组数量过多，节点列表超出路由器单次应答上限' }) });
    assert.equal((await failed.groups()).error, '节点与策略组数量过多，节点列表超出路由器单次应答上限', '超限错误必须原样交给页面显示');

    const node = (tag, attrs = {}, children) => ({ tag, attrs, children: children || [], style: {}, listeners: {},
        get firstElementChild() { return this.children[0]; }, get firstChild() { return this.children[0]; },
        setAttribute(name, value) { this.attrs[name] = value; },
        addEventListener(event, handler) { this.listeners[event] = handler; }, classList: { add() {}, remove() {}, toggle() {} } });
    const dump = value => Array.isArray(value) ? value.map(dump) : value && typeof value == 'object'
        ? { tag: value.tag, attrs: value.attrs, children: dump(value.children) } : value;
    const sortSource = source.slice(source.indexOf('\tsortGroupMembers: function('), source.indexOf('\n\trankSkip: function('));
    const sorter = vm.runInNewContext('({' + sortSource.replace(/,\s*$/, '') + '})');
    const apiView = new Proxy({
        messageText: String, pressable: (cls, attrs) => node('button', Object.assign({ class: cls }, attrs)),
        section: (icon, title, content, actions) => node('section', {}, [title, content, actions]),
        isSelector: type => type == 'Selector', sortGroupMembers: sorter.sortGroupMembers, nodeLabel: String,
        delayBadge: item => 'delay ' + [item.delay, item.testing, item.failed].join('/'),
        speedBadge: item => 'speed ' + [item.speed, item.speed_testing, item.speed_failed].join('/'),
        flagCode: String, flagImg: code => 'flag ' + code,
        input: attrs => node('input', { placeholder: attrs.placeholder, value: attrs.value }),
        dropdown: (items, now) => node('select', { now }, items.map(item => JSON.stringify(item)))
    }, { get: (target, key) => key in target ? target[key] : () => '' });
    const loadView = file => vm.runInNewContext('String.prototype.format = function() { var args = arguments, i = 0; return this.replace(/%[sd]/g, () => String(args[i++])); }; (function(){' +
        fs.readFileSync(path.join(resources, 'view/ecycloud/' + file + '.js'), 'utf8') + '})()', {
        view: { extend: value => value }, api: apiView, E: node, _: String,
        dom: { content: (target, content) => target.children = [content] }, poll: {}, document: { addEventListener() {} },
        ui: { createHandlerFn: () => () => {} }, L: { bind: (fn, context, ...args) => fn.bind(context, ...args) }
    });
    const render = data => {
        const out = [];
        for (const sort of ['name', 'latency', 'speed']) {
            for (const query of ['', '日本']) {
                const nodes = loadView('nodes');
                Object.assign(nodes, { open: {}, sort: {}, searchOpen: {}, query: {}, searchText: {}, listed: {}, listing: {} });
                for (const group of data.groups) {
                    Object.assign(nodes.open, { [group.name]: true });
                    Object.assign(nodes.sort, { [group.name]: sort });
                    Object.assign(nodes.searchOpen, { [group.name]: query != '' });
                    Object.assign(nodes.query, { [group.name]: query });
                    out.push(dump(nodes.renderGroup(group)));
                }
            }
        }
        const overview = loadView('overview');
        Object.assign(overview, { cache: { groups: data.groups, status: {} } });
        out.push(dump(overview.renderCurrentNode({ route_mode: 'rule', profile: { main_group: '主节点' } }, data.groups)));
        return JSON.parse(JSON.stringify(out));
    };
    const before = render(legacy());
    const after = render(await api.groups());
    assert.deepEqual(after, before, '节点页与首页用新格式渲染的分组、成员顺序、选中项和徽标必须与旧格式一致');
    const text = JSON.stringify(after);
    for (const expected of ['🇯🇵 日本 02', 'delay 88/true/false', 'speed 2500000/false/false', 'delay 0/false/true', 'flag '])
        assert.ok(text.includes(expected), '渲染结果必须包含：' + expected);
    console.log('OpenWrt 节点列表去重格式回归通过。');
}

main().catch(error => {
    console.error(error);
    process.exit(1);
});
