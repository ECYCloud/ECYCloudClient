'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

async function main() {
    const source = fs.readFileSync(path.join(__dirname, '../htdocs/luci-static/resources/ecycloud/api.js'), 'utf8');
    const catalogs = Object.fromEntries(['zh-cn', 'zh-tw'].map(locale => [locale, JSON.parse(fs.readFileSync(
        path.join(__dirname, '../htdocs/luci-static/resources/view/ecycloud/i18n.' + locale + '.json'), 'utf8'))]));
    let locale = 'en-US';
    const messageApi = vm.runInNewContext('({' + source.slice(source.indexOf('\tmessageText: function('), source.indexOf('\n\tluciGlobals: function()')) + '})', {
        _: key => locale == 'zh_TW' ? catalogs['zh-tw'][key] || key : key
    });
    messageApi.resolveLang = () => locale;
    messageApi._messageSource = catalogs['zh-cn'];
    const node = (tag, attrs, children) => ({ tag, attrs, children: children || [], style: {}, listeners: {},
        get firstElementChild() { return this.children[0]; },
        addEventListener(event, handler) { this.listeners[event] = handler; }, classList: { add() {}, remove() {}, toggle() {} } });
    const textOf = value => typeof value == 'string' ? value : Array.isArray(value)
        ? value.map(textOf).join(' ') : value && value.children ? textOf(value.children) : '';
    for (const language of ['en-US', 'zh_TW']) {
        locale = language;
        const apiView = {
            messageText: messageApi.messageText.bind(messageApi), bytesCompact: String,
            pressable: () => node('button'), section: (icon, title, content, actions) => node('section', {}, [title, content, actions]),
            isSelector: type => type == 'Selector', sortGroupMembers: members => members, nodeLabel: String,
            groupMark: () => '', delayBadge: () => '', speedBadge: () => '', flagCode: () => '', flagImg: () => ''
        };
        let selected;
        const loadView = file => vm.runInNewContext('String.prototype.format = function() { var args = arguments, i = 0; return this.replace(/%[sd]/g, () => String(args[i++])); }; (function(){' + fs.readFileSync(path.join(__dirname,
            '../htdocs/luci-static/resources/view/ecycloud/' + file + '.js'), 'utf8') + '})()', {
            view: { extend: value => value }, api: apiView, E: node, _: key => language == 'zh_TW' ? catalogs['zh-tw'][key] || key : key,
            dom: { content: (target, content) => target.children = [content] }, poll: {},
            ui: { createHandlerFn: (context, method, ...args) => () => selected = args },
            L: { bind: (fn, context, ...args) => fn.bind(context, ...args) }
        });
        const overview = loadView('overview');
        const account = { traffic_reset: '不重置', last_ss_time: '从未使用喵' };
        const output = textOf(overview.renderUsage({ account }));
        assert.ok(output.includes(language == 'en-US' ? 'No reset' : '不重設'), '首页实际渲染翻译流量重置说明');
        assert.ok(output.includes(language == 'en-US' ? 'Never used' : '從未使用'), '首页实际渲染翻译上次使用说明');
        assert.equal(account.last_ss_time, '从未使用喵', '原始账户字段不改写');
        const connections = loadView('connections');
        const body = node('div');
        connections.paint.call({ signedIn: true, running: true, error: '内核未运行', rows: () => [], body, paintFilter() {} });
        assert.equal(textOf(body), language == 'en-US' ? 'The kernel is not running' : catalogs['zh-tw']['The kernel is not running'], '连接页实际渲染翻译接口错误');
        const nodes = loadView('nodes');
        Object.assign(nodes, { open: {}, sort: {}, searchOpen: {}, query: {} });
        const group = { name: '主节点', label: language == 'en-US' ? 'Main nodes' : '主節點', type: 'Selector',
            now: 'node-1', now_label: 'Fixture node', members: [{ name: 'node-1', label: 'Fixture node' }] };
        const card = nodes.renderGroup(group);
        assert.ok(textOf(card).includes(group.label) && textOf(card).includes('Fixture node'), '节点页实际渲染策略组、当前选择和成员译名');
        assert.ok(!textOf(card).includes('主节点'), '目标语言节点页不残留原始策略组标题');
        const visit = value => {
            if (value?.attrs?.['data-ecy-key'] == 'node-1') value.listeners.click();
            if (Array.isArray(value?.children)) value.children.forEach(visit);
        };
        visit(card);
        assert.deepEqual(selected, ['主节点', 'node-1'], '选择节点仍提交原始策略组及节点标识');
    }
    locale = 'en-US';
    assert.equal(messageApi.messageText('面板繁忙，请约 12 秒后再试'), 'The panel is busy. Try again in about 12 seconds.');
    assert.equal(messageApi.messageText('GitHub 返回 HTTP 429'), 'GitHub returned HTTP 429');
    assert.equal(messageApi.messageText('节点名重复：尚未登录'), 'Duplicate node name: 尚未登录', '变量和自定义节点名称保持原文');
    assert.equal(messageApi.messageText('节点名重复：<img onerror="fixture">'), 'Duplicate node name: <img onerror="fixture">');
    assert.equal(messageApi.messageText('未知测试内容'), '未知测试内容');
    assert.equal(messageApi.messageText('拉取配置失败：面板未返回登录令牌；恢复旧配置失败'),
        'Failed to fetch the profile: The panel did not return a sign-in token; could not restore the previous profile');
    assert.equal(messageApi.messageText('面板配置不规范：\n第 2 个策略组没有名称\n规则「DOMAIN,test,主节点」指向了不存在的策略：主节点'),
        'Invalid panel profile:\nProxy group 2 has no name\nRule "DOMAIN,test,主节点" points to a policy that does not exist: 主节点');
    for (const key of Object.keys(catalogs['zh-cn'])) {
        assert.ok(key in catalogs['zh-tw'], '繁中缺词：' + key);
        const tokens = text => text.match(/%[sd]|\{message\}/g) || [];
        assert.deepEqual(tokens(key), tokens(catalogs['zh-cn'][key]), '简中参数顺序：' + key);
        assert.deepEqual(tokens(key), tokens(catalogs['zh-tw'][key]), '繁中参数顺序：' + key);
        if (tokens(key).length) {
            const fill = text => {
                let index = 0;
                return text.replace(/%[sd]|\{message\}/g, token => token == '%d' ? String(++index)
                    : 'fixture_' + (++index) + '_中文');
            };
            assert.equal(messageApi.messageText(fill(catalogs['zh-cn'][key])), fill(key), '动态提示英文：' + key);
        }
    }
    locale = 'zh_TW';
    assert.equal(messageApi.messageText('面板繁忙，请约 12 秒后再试'), '面板忙碌，請約 12 秒後再試');
    assert.equal(messageApi.messageText('节点名重复：尚未登录'), '節點名稱重複：尚未登录');
    locale = 'zh_CN';
    assert.equal(messageApi.messageText('面板繁忙，请约 12 秒后再试'), '面板繁忙，请约 12 秒后再试');
    for (const [file, expected] of [[null, ['i18n.zh-cn.json']], ['i18n.zh-tw.json', ['i18n.zh-cn.json', 'i18n.zh-tw.json']]]) {
        const fetched = [];
        const loader = vm.runInNewContext('({' + source.slice(source.indexOf('\tapplyI18n: function('), source.indexOf('\n\tmessageText: function(')) + '})', {
            L: { resource: value => value },
            fetch: async url => {
                const name = path.basename(url);
                fetched.push(name);
                return { ok: true, json: async () => catalogs[name.includes('zh-tw') ? 'zh-tw' : 'zh-cn'] };
            }
        });
        loader.i18nFile = () => file;
        let installed;
        loader.installI18n = map => installed = map;
        await loader.applyI18n();
        assert.deepEqual(fetched, expected, '英文界面也加载本地提示源词典');
        assert.equal(loader._messageSource, catalogs['zh-cn']);
        assert.equal(Object.keys(installed).length, file ? Object.keys(catalogs['zh-tw']).length : 0);
    }
    let stored = 'en';
    let writeFails = false;
    const languageDocument = { documentElement: { lang: 'zh-CN' } };
    const languageNavigator = { language: 'zh-CN' };
    const languageApi = vm.runInNewContext('({' + source.slice(source.indexOf('\tuiLang: function()'), source.indexOf('\n\ti18nFile: function()')) + '})', {
        window: { localStorage: { getItem: () => stored, setItem: (key, value) => {
            assert.equal(key, 'ecycloud-lang');
            if (writeFails) throw new Error('fixture storage failure');
            stored = value;
        } } },
        document: languageDocument, navigator: languageNavigator
    });
    languageApi.luciGlobals = () => ({});
    assert.equal(languageApi.resolveLang(), 'en-US');
    assert.equal(stored, 'en-US');
    stored = 'en'; writeFails = true;
    assert.equal(languageApi.resolveLang(), 'en-US', '存储写入失败时仍保留旧英文选择');
    for (const device of ['ja-JP', 'fr-FR', 'ko-KR', 'ru-RU', '']) {
        languageNavigator.language = device;
        for (const page of [device, 'auto']) {
            languageDocument.documentElement.lang = page;
            stored = '';
            assert.equal(languageApi.resolveLang(), 'en-US', '没有已保存语言时，不支持的设备语言回退英文');
            for (const selected of ['zh_CN', 'zh_TW', 'en-US']) {
                stored = selected;
                assert.equal(languageApi.resolveLang(), selected, '已保存或手动选择优先于设备语言');
            }
        }
    }
    const start = source.indexOf('\tfetchAnnouncements: function(');
    const end = source.indexOf('\n\treclaimDeviceSlot:', start);
    assert.ok(start >= 0 && end > start);
    const api = vm.runInNewContext('({' + source.slice(start, end) + '})');
    let language = 'zh_CN';
    const requests = [];
    api.resolveLang = () => language;
    api.update = (...args) => new Promise(resolve => requests.push({ args, resolve }));

    const old = api.fetchAnnouncements();
    assert.deepEqual(requests[0].args, ['announcements', '', 'zh-CN']);
    language = 'en-US';
    requests[0].resolve({ items: [{ title: '旧语言' }] });
    await new Promise(resolve => setImmediate(resolve));
    assert.deepEqual(requests[1].args, ['announcements', 'refresh', 'en-US']);
    requests[1].resolve({ items: [{ title: 'fixture-en' }] });
    assert.equal((await old).items[0].title, 'fixture-en', '旧语言响应不得进入当前语言界面');

    for (const [invoke, action] of [[() => api.markAnnouncementsSeen(), 'seen'],
        [() => api.markAnnouncementSeen(2), 'seen:2'], [() => api.dismissAnnouncementPopup(), 'popup']]) {
        const pending = invoke();
        const request = requests.at(-1);
        assert.deepEqual(request.args, ['announcements', action, 'en-US']);
        request.resolve({ ok: true });
        await pending;
    }
    const statusStart = source.indexOf('\tstatus: function()');
    const statusEnd = source.indexOf('\n\tgroups:', statusStart);
    const updates = [];
    const statusContext = { statusRpc: async () => ({ session: { logged_in: true }, profile: { locale: 'zh-CN', fetched_at: 1 } }),
        languageRefresh: null, languageRetryAfter: 0, Date: { now: () => 1000 } };
    const statusApi = vm.runInNewContext('({' + source.slice(statusStart, statusEnd) + '})', statusContext);
    statusApi.resolveLang = () => 'en-US';
    statusApi.update = (...args) => new Promise(resolve => updates.push({ args, resolve }));
    await statusApi.status();
    await statusApi.status();
    assert.equal(updates.length, 1, '语言缓存不匹配时只发起一个刷新');
    assert.deepEqual(updates[0].args, ['language', '', 'en-US']);
    updates[0].resolve({ ok: true });
    await new Promise(resolve => setImmediate(resolve));
    await statusApi.status();
    assert.equal(updates.length, 1, '刷新失败或状态尚未同步时不连续请求配置');
    statusContext.statusRpc = async () => ({ session: { logged_in: false }, profile: { locale: 'zh-CN', fetched_at: 1 } });
    statusContext.languageRetryAfter = 0;
    await statusApi.status();
    assert.equal(updates.length, 1, '未登录时不尝试同步语言配置');
    const rpcSource = fs.readFileSync(path.join(__dirname, '../root/usr/share/rpcd/ucode/ecycloud.uc'), 'utf8');
    const logStart = rpcSource.indexOf('\tlogs: {');
    const logEnd = rpcSource.indexOf('\n\tlogin:', logStart);
    const runtimeStart = rpcSource.indexOf("\t\t\tif (what == 'runtime') {");
    const runtimeEnd = rpcSource.indexOf("\n\t\t\tif (what == 'rules')", runtimeStart);
    assert.ok(logStart >= 0 && logEnd > logStart && runtimeStart >= 0 && runtimeEnd > runtimeStart);
    for (const label of ['Main nodes', '主節點']) {
        const raw = 'Match using 主节点[node-9]';
        const labels = { 'node-9': 'Fixture node', '主节点': label };
        const context = {
            what: 'runtime', min: Math.min, max: Math.max, int: Number,
            popen: () => ({ read: () => raw, close() {} }),
            profile: { cached: () => ({ node_labels: { 'node-9': 'Fixture node' }, group_labels: { '主节点': label } }),
                runtimeConfig: () => ({ ok: true, text: raw }) },
            annotateLabels: (text, received) => {
                assert.deepEqual(JSON.parse(JSON.stringify(received)), labels, 'RPC 实际输出入口须合并节点及策略组译名');
                return text.replace(/主节点|node-9/g, key => received[key]);
            }
        };
        const logs = vm.runInNewContext('({' + rpcSource.slice(logStart, logEnd) + '})', context);
        assert.equal(logs.logs.call({ args: { lines: 10 } }).log, `Match using ${label}[Fixture node]`, '日志 RPC 使用策略组译名');
        const runtime = vm.runInNewContext('(function() {' + rpcSource.slice(runtimeStart, runtimeEnd) + '})()', context);
        assert.equal(runtime.text, `Match using ${label}[Fixture node]`, '运行配置 RPC 使用策略组译名');
        assert.equal(raw, 'Match using 主节点[node-9]', 'RPC 展示翻译不能改写运行配置');
    }
    console.log('OpenWrt 内容语言界面离线回归通过：首页、连接页、节点和策略组实际渲染、原始选择标识、请求语言与旧响应隔离。');
}

main().catch(error => { console.error(error); process.exitCode = 1; });
