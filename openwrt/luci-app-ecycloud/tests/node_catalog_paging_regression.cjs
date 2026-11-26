'use strict';

// 节点目录分页的界面离线回归：联网搜索的权限归属、换版重试、节点页的翻页与搜索状态、整组测试带上列出的节点。
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

const root = path.join(__dirname, '..');
const resources = process.argv[2] || path.join(root, 'htdocs/luci-static/resources');
const source = fs.readFileSync(path.join(resources, 'ecycloud/api.js'), 'utf8');
const slice = (from, to) => source.slice(source.indexOf(from), source.indexOf(to));

async function main() {
    const acl = JSON.parse(fs.readFileSync(path.join(root, 'root/usr/share/rpcd/acl.d/luci-app-ecycloud.json'), 'utf8'))['luci-app-ecycloud'];
    assert.ok(acl.write.ubus['luci.ecycloud'].includes('search_nodes') && !acl.read.ubus['luci.ecycloud'].includes('search_nodes'),
        '联网搜索只能放在写权限里');
    assert.ok(source.includes("declare('search_nodes', [ 'group', 'keyword', 'offset' ])") &&
        source.includes("declare('test_group', [ 'group', 'names' ])") && source.includes("declare('test_group_speed', [ 'group', 'names' ])"),
        'RPC 声明必须带上搜索与列出节点的参数');

    // api.searchNodes：补默认字段；目录换版时等后台刷新完再从第一页重取
    const defaults = slice('var memberDefaults = {', 'var groupsRequest');
    const calls = [];
    const replies = [];
    const waits = [];
    const api = vm.runInNewContext(defaults + '({' + slice('\tsearchNodes: function(', '\n\tisSelector: function(').replace(/,\s*$/, '') + '})', { _: String });
    api.searchNodesRpc = async (...args) => { calls.push(args); return replies.shift(); };
    api.waitUpdate = async id => { waits.push(id); return { ok: true }; };
    replies.push({ ok: true, nodes: [{ name: 'node-9', label: '夹具 9', protocol: 'Trojan' }], more: true, next: 105 });
    let res = await api.searchNodes('代理', '夹具', null);
    assert.deepEqual(calls.pop(), ['代理', '夹具', -1], '省略 offset 表示取第一页');
    assert.ok(res.ok && res.more && res.next == 105 && !res.restarted && res.nodes[0].delay === 0 && res.nodes[0].via === '' &&
        res.nodes[0].protocol == 'Trojan', '搜到的节点补齐与分组成员相同的默认字段');
    replies.push({ ok: true, pending: true, id: 'task-1' }, { ok: true, nodes: [], more: false, next: 100 });
    res = await api.searchNodes('代理', '夹具', 300);
    assert.deepEqual(JSON.parse(JSON.stringify([calls, waits])), [[['代理', '夹具', 300], ['代理', '夹具', -1]], ['task-1']],
        '目录换版：等后台刷新完成后从第一页重取');
    assert.ok(res.ok && res.restarted === true, '重取的结果标记 restarted');
    api.waitUpdate = async () => ({ ok: false, msg: '后台更新已中断，请重试' });
    replies.push({ ok: true, pending: true, id: 'task-2' });
    res = await api.searchNodes('代理', '', null);
    assert.ok(!res.ok && res.msg == '后台更新已中断，请重试', '后台刷新失败时把原因交给页面');
    replies.push({ ok: true, pending: true, id: 'task-3' });
    res = await api.searchNodes('代理', '', null, true);
    assert.ok(!res.ok, '刷新后仍然对不上时不再循环重试');
    replies.push({ ok: false, msg: '面板繁忙，请约 6 秒后再试' });
    assert.equal((await api.searchNodes('代理', 'x', null)).msg, '面板繁忙，请约 6 秒后再试', '接口失败原样返回');
    api.searchNodesRpc = async () => { throw new Error('ubus timeout'); };
    assert.deepEqual(JSON.parse(JSON.stringify(await api.searchNodes('代理', 'x', null))), { ok: false, msg: 'ubus timeout' }, '请求异常转成失败结果');

    // api.testGroup：把界面列出的节点一并交给后端
    const tested = [];
    const tester = vm.runInNewContext('var groupTests = { testing: new Map(), speed_testing: new Map() }; ({' +
        slice('\ttestGroup: function(', '\n\tjump: function(').replace(/,\s*$/, '') + '})');
    tester.test_group = async (...args) => { tested.push(['delay', ...args]); return { ok: true }; };
    tester.test_group_speed = async (...args) => { tested.push(['speed', ...args]); return { ok: true }; };
    await tester.testGroup({ name: '甲' }, false, ['node-7']);
    await tester.testGroupSpeed({ name: '乙' }, ['node-8']);
    await tester.testGroup('丙');
    assert.deepEqual(JSON.parse(JSON.stringify(tested)), [['delay', '甲', ['node-7']], ['speed', '乙', ['node-8']], ['delay', '丙', []]],
        '整组测延迟与测速都带上列出的节点，没有时传空表');

    // 节点页
    const node = (tag, attrs = {}, children) => ({ tag, attrs, children: children || [], style: {}, listeners: {},
        get firstElementChild() { return this.children[0]; }, get firstChild() { return this.children[0]; },
        setAttribute(name, value) { this.attrs[name] = value; },
        addEventListener(event, handler) { this.listeners[event] = handler; }, classList: { add() {}, remove() {}, toggle() {} } });
    const searches = [];
    const notices = [];
    const groupTests = [];
    let searchReply = () => ({ ok: true, nodes: [], more: false, next: 0 });
    let groupsArg;
    const apiView = new Proxy({
        messageText: String, isSelector: type => type == 'Selector', sortGroupMembers: list => list, nodeLabel: String,
        pressable: (cls, attrs, children) => {
            const button = node('button', Object.assign({ class: cls }, attrs), children);
            if (attrs && attrs.click)
                button.listeners.click = attrs.click;
            return button;
        },
        input: attrs => Object.assign(node('input', { placeholder: attrs.placeholder, value: attrs.value }), { listeners: { input: attrs.input } }),
        searchNodes: async (...args) => { searches.push(args); return searchReply(...args); },
        notify: res => { notices.push(res.msg); return res; },
        testGroup: async (...args) => { groupTests.push(args); return { ok: true }; },
        testGroupSpeed: async (...args) => { groupTests.push(['speed', ...args]); return { ok: true }; },
        status: async () => ({ session: {} }), signedIn: () => true,
        groups: async search => { groupsArg = search; return { groups: [] }; }
    }, { get: (target, key) => key in target ? target[key] : () => '' });
    const view = () => {
        const nodes = vm.runInNewContext('String.prototype.format = function() { var args = arguments, i = 0; return this.replace(/%[sd]/g, () => String(args[i++])); }; (function(){' +
            fs.readFileSync(path.join(resources, 'view/ecycloud/nodes.js'), 'utf8') + '})()', {
            view: { extend: value => value }, api: apiView, E: node, _: String, Promise, Set, Array, setTimeout: fn => fn, clearTimeout() {},
            dom: {}, poll: {}, document: { addEventListener() {} },
            ui: { createHandlerFn: () => () => {} }, L: { bind: (fn, context, ...args) => fn.bind(context, ...args) }
        });
        Object.assign(nodes, { open: {}, sort: {}, searchOpen: {}, searchText: {}, query: {}, listed: {}, listing: {}, refreshed: 0, painted: 0 });
        nodes.refresh = function() { this.refreshed++; return Promise.resolve(); };
        nodes.repaint = function() { this.painted++; };
        return nodes;
    };
    const member = (name, label) => ({ name, label, type: 'Trojan', protocol: 'Trojan', network: '', tls: '', udp: '', is_group: false,
        group_selectable: false, via: '', via_label: '', delay: 0, testing: false, failed: false, speed: 0, speed_testing: false, speed_failed: false });
    const group = extra => Object.assign({ name: '代理', label: '代理', type: 'Selector', now: 'node-1', now_label: '香港 1',
        members: [member('node-1', '香港 1'), member('node-2', '日本 2')], partial: true, remote: true }, extra);
    const find = (value, test, out = []) => {
        if (Array.isArray(value))
            value.forEach(item => find(item, test, out));
        else if (value && typeof value == 'object') {
            if (test(value))
                out.push(value);
            find(value.children, test, out);
        }
        return out;
    };
    const keys = card => find(card, item => item.attrs && /^node-/.test(item.attrs['data-ecy-key'] || '')).map(item => item.attrs['data-ecy-key']);
    const has = (card, key) => find(card, item => item.attrs && item.attrs['data-ecy-key'] == key).length > 0;

    // 取其余成员只经 search_nodes；本机冷目录（旧面板）仍经 groups 的 search 参数
    let nodes = view();
    nodes.groups = [group(), group({ name: '旧面板', remote: false })];
    Object.assign(nodes.searchOpen, { '代理': true, '旧面板': true });
    Object.assign(nodes.query, { '代理': '香港', '旧面板': '香港' });
    await nodes.load();
    assert.deepEqual(JSON.parse(JSON.stringify(groupsArg)), { '旧面板': '香港' }, '节点留在面板的分组不再把搜索词交给只读的 groups');

    // 不带搜索词：按顺序往下取，接着上一页的位置，取完为止
    nodes = view();
    const target = group();
    nodes.open['代理'] = true;
    let card = nodes.renderGroup(target);
    assert.ok(has(card, 'more') && has(card, 'partial') && keys(card).join() == 'node-1,node-2', '还有成员留在面板时显示提示与「加载更多」');
    searchReply = () => ({ ok: true, nodes: [member('node-3', '美国 3'), member('node-2', '日本 2')], more: true, next: 104 });
    const first = nodes.fetchListed(target);
    assert.equal(nodes.listing['代理'], '', '请求期间记下正在取的搜索词');
    assert.equal(find(nodes.renderGroup(target), item => item.attrs && item.attrs.class == 'ecycloud-jump')[0].attrs.disabled, true, '请求期间按钮停用');
    await nodes.fetchListed(target);
    await first;
    assert.deepEqual(JSON.parse(JSON.stringify(searches)), [['代理', '', null]], '同一搜索词的请求进行中不重复发');
    assert.equal(keys(nodes.renderGroup(target)).join(), 'node-1,node-2,node-3', '取到的节点排在已有成员之后，已有的不重复');
    searchReply = () => ({ ok: true, nodes: [member('node-4', '德国 4')], more: false, next: 204 });
    await nodes.fetchListed(target);
    assert.deepEqual(JSON.parse(JSON.stringify(searches[1])), ['代理', '', 104], '下一页从上一页给的位置接着取');
    card = nodes.renderGroup(target);
    assert.ok(keys(card).join() == 'node-1,node-2,node-3,node-4' && !has(card, 'more'), '取完后不再显示「加载更多」');
    await nodes.fetchListed(target);
    assert.equal(searches.length, 2, '取完后不再请求');

    // 整组测试带上列出的节点
    card = nodes.renderGroup(target);
    find(card, item => item.attrs && item.attrs['data-ico'] == 'bolt')[0].listeners.click({ stopPropagation() {} });
    find(card, item => item.attrs && item.attrs['data-ico'] == 'speed')[0].listeners.click({ stopPropagation() {} });
    assert.deepEqual(JSON.parse(JSON.stringify(groupTests.map(args => args.slice(-1)[0]))), [['node-3', 'node-4'], ['node-3', 'node-4']],
        '整组测延迟、测速把列出的未装入节点一并交给后端');

    // 搜索：换搜索词从头取，结果只在该搜索词下显示；搜索词超过 64 个字符时截断后发给面板
    searches.length = 0;
    nodes.searchOpen['代理'] = true;
    nodes.query['代理'] = '香港';
    card = nodes.renderGroup(target);
    assert.ok(keys(card).join() == 'node-1' && has(card, 'more') && !has(card, 'empty'), '搜索结果返回前只显示本机匹配的成员');
    searchReply = () => ({ ok: true, nodes: [member('node-30', '香港 30')], more: false, next: 100 });
    await nodes.fetchListed(target);
    assert.deepEqual(JSON.parse(JSON.stringify(searches[0])), ['代理', '香港', null], '换搜索词后从第一页取');
    assert.equal(keys(nodes.renderGroup(target)).join(), 'node-1,node-30', '搜到的节点补在本机匹配的成员之后');
    nodes.query['代理'] = '不存在';
    card = nodes.renderGroup(target);
    assert.ok(!has(card, 'empty') && has(card, 'more'), '面板还没答复时不显示「没有匹配的节点」');
    searchReply = () => ({ ok: true, nodes: [], more: false, next: 100 });
    await nodes.fetchListed(target);
    card = nodes.renderGroup(target);
    assert.ok(has(card, 'empty') && !has(card, 'more'), '面板也没有匹配时才显示「没有匹配的节点」');
    const long = '长'.repeat(70);
    nodes.query['代理'] = long;
    await nodes.fetchListed(target);
    assert.ok(searches.slice(-1)[0][1] == '长'.repeat(64) && nodes.listed['代理'].keyword == long, '发给面板的搜索词截到 64 个字符，页面仍按完整搜索词记结果');

    // 失败：提示原因，已显示的内容不动
    nodes.query['代理'] = '香港';
    await nodes.fetchListed(target);
    const kept = JSON.stringify(nodes.listed);
    searchReply = () => ({ ok: false, msg: '面板繁忙，请约 6 秒后再试' });
    nodes.query['代理'] = '日本';
    await nodes.fetchListed(target);
    assert.ok(notices.join() == '面板繁忙，请约 6 秒后再试' && JSON.stringify(nodes.listed) == kept && nodes.listing['代理'] == null,
        '面板不可达时按接口失败提示，不清空已取到的内容');

    // 目录换版：别的分组取到的也作废，并刷新分组
    nodes.listed['另一组'] = { keyword: '', nodes: [member('node-9', 'x')], more: true, next: 100 };
    searchReply = () => ({ ok: true, restarted: true, nodes: [member('node-31', '日本 31')], more: false, next: 100 });
    const refreshed = nodes.refreshed;
    await nodes.fetchListed(target);
    assert.ok(nodes.listed['另一组'] == null && nodes.listed['代理'].nodes.length == 1 && nodes.refreshed == refreshed + 1,
        '目录换版后清空全部浏览结果并刷新分组');

    // 页面里最多留 2000 个
    nodes.query['代理'] = '';
    nodes.searchOpen['代理'] = false;
    let page = 0;
    searchReply = () => ({ ok: true, nodes: Array.from({ length: 900 }, (_, i) => member('node-' + (1000 + page * 900 + i), 'n')), more: true, next: ++page * 900 });
    for (let i = 0; i < 3; i++)
        await nodes.fetchListed(target);
    assert.ok(nodes.listed['代理'].nodes.length == 2000 && nodes.listed['代理'].nodes[0].name == 'node-1700', '浏览结果超过 2000 个时丢最早的');

    // 整份下发或本机冷目录的分组没有「加载更多」
    for (const plain of [group({ partial: false, remote: false }), group({ partial: true, remote: false })]) {
        nodes = view();
        nodes.open['代理'] = true;
        nodes.listed['代理'] = { keyword: '', nodes: [member('node-77', '残留')], more: true, next: 100 };
        card = nodes.renderGroup(plain);
        assert.ok(!has(card, 'more') && keys(card).join() == 'node-1,node-2', '节点不在面板上取的分组不显示「加载更多」，也不混入浏览结果');
    }
    console.log('OpenWrt 节点目录分页界面回归通过。');
}

main().catch(error => {
    console.error(error);
    process.exit(1);
});
