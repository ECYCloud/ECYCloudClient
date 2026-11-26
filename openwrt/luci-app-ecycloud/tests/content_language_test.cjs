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
    const node = (tag, attrs = {}, children) => ({ tag, attrs, children: children || [], style: {}, listeners: {},
        get firstElementChild() { return this.children[0]; },
        setAttribute(name, value) { this.attrs[name] = value; },
        addEventListener(event, handler) { this.listeners[event] = handler; }, classList: { add() {}, remove() {}, toggle() {} } });
    const textOf = value => typeof value == 'string' ? value : Array.isArray(value)
        ? value.map(textOf).join(' ') : value && value.children ? textOf(value.children) : '';
    for (const language of ['en-US', 'zh_TW']) {
        locale = language;
        const apiView = {
            messageText: messageApi.messageText.bind(messageApi), bytesCompact: String,
            pressable: (cls, attrs) => node('button', attrs), section: (icon, title, content, actions) => node('section', {}, [title, content, actions]),
            isSelector: type => type == 'Selector', sortGroupMembers: members => members, nodeLabel: String,
            groupMark: () => '', delayBadge: () => '', speedBadge: () => '', flagCode: () => '', flagImg: () => ''
        };
        let selected;
        const loadView = file => vm.runInNewContext('String.prototype.format = function() { var args = arguments, i = 0; return this.replace(/%[sd]/g, () => String(args[i++])); }; (function(){' + fs.readFileSync(path.join(__dirname,
            '../htdocs/luci-static/resources/view/ecycloud/' + file + '.js'), 'utf8') + '})()', {
            view: { extend: value => value }, api: apiView, E: node, _: key => language == 'zh_TW' ? catalogs['zh-tw'][key] || key : key,
            dom: { content: (target, content) => target.children = [content] }, poll: {}, document: { addEventListener() {} },
            ui: { createHandlerFn: (context, method, ...args) => () => selected = args },
            L: { bind: (fn, context, ...args) => fn.bind(context, ...args) }
        });
        const overview = loadView('overview');
        const account = { traffic_reset: '不重置', last_ss_time: '从未使用喵' };
        const usage = overview.renderUsage({ account });
        const output = textOf(usage);
        const [usageHelp, usageTip] = usage.firstElementChild.children[1].children;
        assert.equal(textOf(usageTip), language == 'en-US' ? 'Shows traffic usage across all devices.' : '統計所有裝置的流量使用情況');
        assert.equal(usageHelp.attrs['aria-describedby'], usageTip.attrs.id);
        assert.ok(output.includes(language == 'en-US' ? 'No reset' : '不重設'), '首页实际渲染翻译流量重置说明');
        assert.ok(output.includes(language == 'en-US' ? 'Never used' : '從未使用'), '首页实际渲染翻译上次使用说明');
        assert.equal(account.last_ss_time, '从未使用喵', '原始账户字段不改写');
        Object.assign(apiView, { phase: () => 'disconnected', card: children => node('div', {}, children), segments: () => node('div'),
            timestamp: seconds => 'at-' + Math.round(seconds) });
        const expiryNotice = language == 'en-US'
            ? 'Your sign-in expires on %s. To stay connected, sign out and sign back in before then.'
            : catalogs['zh-tw']['Your sign-in expires on %s. To stay connected, sign out and sign back in before then.'];
        const soon = Date.now() + 3 * 86400000;
        assert.ok(textOf(overview.renderConnection({ session: { expires_at: new Date(soon).toISOString() } }))
            .includes(expiryNotice.replace('%s', 'at-' + Math.round(soon / 1000))), '登录 7 天内到期时首页必须提示到期时间');
        for (const later of [new Date(Date.now() + 8 * 86400000).toISOString(), '10000-01-01T00:00:00+08:00', ''])
            assert.ok(!textOf(overview.renderConnection({ session: { expires_at: later } })).includes(expiryNotice.split('%s')[0]),
                '登录剩余超过 7 天或面板不限时长时首页不提示');
        const connections = loadView('connections');
        const body = node('div');
        connections.paint.call({ signedIn: true, running: true, error: '内核未运行', rows: () => [], body, paintFilter() {} });
        assert.equal(textOf(body), language == 'en-US' ? 'The kernel is not running' : catalogs['zh-tw']['The kernel is not running'], '连接页实际渲染翻译接口错误');
        const nodes = loadView('nodes');
        Object.assign(nodes, { open: { '主节点': true }, sort: {}, searchOpen: {}, query: {}, listed: {}, listing: {} });
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

    const tick = () => new Promise(resolve => setImmediate(resolve));
    const old = api.fetchAnnouncements();
    assert.deepEqual(requests[0].args, ['announcements', '', 'zh-CN']);
    language = 'en-US';
    requests[0].resolve({ ok: true, loaded: true, items: [{ title: '旧语言' }] });
    await tick();
    assert.deepEqual(requests[1].args, ['announcements', 'refresh', 'en-US']);
    requests[1].resolve({ id: 'task', kind: 'announcements', state: 'done', ok: true, msg: '' });
    await tick();
    assert.deepEqual(requests[2].args, ['announcements', '', 'en-US'], '后台任务完成后必须重新读取路由器上的公告缓存');
    requests[2].resolve({ ok: true, loaded: true, items: [{ title: 'fixture-en' }] });
    assert.equal((await old).items[0].title, 'fixture-en', '旧语言响应不得进入当前语言界面');

    requests.length = 0;
    const cachedRead = api.fetchAnnouncements();
    requests[0].resolve({ ok: true, loaded: true, items: [{ title: 'cached' }] });
    assert.equal((await cachedRead).items[0].title, 'cached');
    assert.equal(requests.length, 1, '路由器已有公告缓存时打开首页或点铃铛只读缓存，不排拉取任务');

    requests.length = 0;
    const firstRead = api.fetchAnnouncements();
    requests[0].resolve({ ok: true, loaded: false, items: [] });
    await tick();
    assert.deepEqual(requests[1].args, ['announcements', 'refresh', 'en-US'], '没有缓存时必须交给后台任务拉取');
    requests[1].resolve({ id: 'task', kind: 'announcements', state: 'done', ok: true, msg: '' });
    await tick();
    requests[2].resolve({ ok: true, loaded: false, items: [] });
    assert.equal((await firstRead).loaded, false);
    assert.equal(requests.length, 3, '任务完成后仍没有缓存（如面板限流）时不能接着排任务，避免反复请求');

    requests.length = 0;
    const failed = api.fetchAnnouncements(true);
    requests[0].resolve({ id: 'task', kind: 'announcements', state: 'done', ok: false, msg: 'fixture-timeout' });
    await tick();
    requests[1].resolve({ ok: true, loaded: true, items: [{ title: 'kept' }] });
    const failedView = await failed;
    assert.ok(failedView.ok === false && failedView.error == 'fixture-timeout' && failedView.items[0].title == 'kept',
        '后台拉取失败时保留已缓存的公告并带回失败原因');
    requests.length = 0;

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
    statusApi.ensureStyle = () => {};
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
        const annotate = (text, received) => {
            assert.deepEqual(JSON.parse(JSON.stringify(received)), labels, 'RPC 实际输出入口须合并节点及策略组译名');
            return text.replace(/主节点|node-9/g, key => received[key]);
        };
        const context = {
            what: 'runtime', min: Math.min, max: Math.max, int: Number, length: value => value.length, LOG_LIMIT: 600000,
            request: { args: {} }, STATE_DIR: '', RUNTIME_VIEW: '', ensurePrivateDir() {}, writeAtomic: (file, text) => { context.saved = text; return true; },
            readfile: () => context.saved, stat: () => ({}), textChunk: text => ({ text }), inboundTypes: () => ({}),
            popen: () => ({ read: () => raw, close() {} }),
            profile: { cached: () => ({ node_labels: { 'node-9': 'Fixture node' }, group_labels: { '主节点': label } }),
                runtimeConfig: () => ({ ok: true, text: raw }) },
            annotateLabels: annotate,
            annotateRuntime: annotate
        };
        const logs = vm.runInNewContext('({' + rpcSource.slice(logStart, logEnd) + '})', context);
        assert.equal(logs.logs.call({ args: { lines: 10 } }).log, `Match using ${label}[Fixture node]`, '日志 RPC 使用策略组译名');
        const runtime = vm.runInNewContext('(function() {' + rpcSource.slice(runtimeStart, runtimeEnd) + '})()', context);
        assert.equal(runtime.text, `Match using ${label}[Fixture node]`, '运行配置 RPC 使用策略组译名');
        assert.equal(raw, 'Match using 主节点[node-9]', 'RPC 展示翻译不能改写运行配置');
    }
    const updateStart = source.indexOf('\tupdate: function(what, path, locale) {');
    const updateEnd = source.indexOf('\n\tselectRpc:', updateStart);
    assert.ok(updateStart >= 0 && updateEnd > updateStart);
    const polls = [];
    const updateContext = {
        _: text => text,
        setTimeout: (run, delay) => { polls.push(delay); setImmediate(run); },
        updateRpc: async () => ({ ok: true, msg: '', pending: true, id: 'task-1' }),
        statusRpc: async () => statuses.shift()
    };
    const statuses = [
        { update_tasks: [{ id: 'task-1', state: 'queued' }] },
        { update_tasks: [{ id: 'task-0', state: 'done', ok: false }, { id: 'task-1', state: 'running' }] },
        { update_tasks: [{ id: 'task-1', state: 'done', ok: true, msg: '', changed: true, reloaded: true }] }
    ];
    const updateApi = vm.runInNewContext('({' + source.slice(updateStart, updateEnd) + '})', updateContext);
    updateApi.resolveLang = () => 'en-US';
    const finished = await updateApi.update();
    assert.ok(finished.ok && finished.changed && finished.reloaded && statuses.length == 0 && polls.length == 3 && polls.every(ms => ms == 2000),
        '后台刷新必须轮询到本任务完成后才返回 changed / reloaded 结果');
    statuses.push({ update_tasks: [] });
    assert.deepEqual(JSON.parse(JSON.stringify(await updateApi.update())), { ok: false, msg: 'The background update was interrupted. Try again.' },
        'status 里找不到任务时必须提示后台更新已中断');
    updateContext.updateRpc = async () => ({ ok: true, items: [] });
    assert.deepEqual(JSON.parse(JSON.stringify(await updateApi.update('rules'))), { ok: true, items: [] }, '不排后台任务的 update 调用必须照常立即返回');
    const connectStart = source.indexOf('\tconnect: function(opts) {');
    const connectEnd = source.indexOf('\n\twatchKick: function()', connectStart);
    assert.ok(connectStart >= 0 && connectEnd > connectStart);
    const connectContext = { _: text => text, connectGeneration: 0, connectPending: null };
    const connectApi = vm.runInNewContext('({' + source.slice(connectStart, connectEnd) + '})', connectContext);
    const starts = [];
    let startResult = { ok: true, msg: '', pending: true, id: 'task-start' };
    let waited = null;
    connectApi.refreshAccount = async () => ({ ok: true, account: {} });
    connectApi.start = async refreshed => { starts.push(refreshed); return refreshed ? { ok: true, msg: '' } : startResult; };
    connectApi.waitUpdate = id => new Promise(resolve => waited = { id, resolve });
    const settle = () => new Promise(resolve => setImmediate(resolve));
    let connecting = connectApi.connect();
    await settle();
    assert.equal(waited.id, 'task-start');
    waited.resolve({ id: 'task-start', state: 'done', ok: true, msg: '' });
    assert.deepEqual(JSON.parse(JSON.stringify(await connecting)), { ok: true, msg: '' });
    assert.deepEqual(starts, [undefined, true], '后台刷新完成后才带 refreshed 再次启动');
    starts.length = 0;
    connecting = connectApi.connect();
    await settle();
    waited.resolve({ id: 'task-start', state: 'done', ok: false, msg: '拉取配置失败：fixture' });
    assert.deepEqual(JSON.parse(JSON.stringify(await connecting)), { ok: false, msg: '拉取配置失败：fixture' }, '后台刷新失败时给出原来的错误提示');
    assert.deepEqual(starts, [undefined], '后台刷新失败时不能再次启动');
    starts.length = 0;
    connecting = connectApi.connect();
    await settle();
    connectContext.connectGeneration++;
    waited.resolve({ id: 'task-start', state: 'done', ok: true, msg: '' });
    assert.deepEqual(JSON.parse(JSON.stringify(await connecting)), { ok: false, cancelled: true }, '等待期间已断开时不能再开启服务');
    assert.deepEqual(starts, [undefined]);
    starts.length = 0;
    startResult = { ok: false, msg: '面板配置不规范：fixture' };
    assert.deepEqual(JSON.parse(JSON.stringify(await connectApi.connect())), startResult, '不排后台任务的启动结果照常返回');
    assert.ok(starts.length == 1 && connectContext.connectPending == null);
    console.log('OpenWrt 内容语言界面离线回归通过：首页、连接页、节点和策略组实际渲染、原始选择标识、请求语言与旧响应隔离。');
}

main().catch(error => { console.error(error); process.exitCode = 1; });
