'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { chromium } = require('playwright-core');

const source = fs.readFileSync(process.argv[2] || path.join(__dirname,
    '../htdocs/luci-static/resources/ecycloud/api.js'), 'utf8');
const start = source.indexOf('\tannounceHtml: function(');
const end = source.indexOf('\n\tannouncePopup:', start);
assert.ok(start >= 0 && end > start);
const implementation = source.slice(start, end);
const overview = fs.readFileSync(process.argv[3] || path.join(__dirname,
    '../htdocs/luci-static/resources/view/ecycloud/overview.js'), 'utf8');
const attacks = [
    '<a href="jav&#x09;ascript:window.compromised=1">tab</a>',
    '<a href="java&#x0a;script:window.compromised=1">newline</a>',
    '<a href="&#x01;javascript:window.compromised=1">control</a>',
    '<a href="data:text/html,<script>alert(1)</script>">data</a>',
    '<a href="file:///etc/passwd">file</a>',
    '<a href="intent://test/#Intent;end">intent</a>',
    '<img src="missing" onerror="window.compromised=1">',
    '<svg><a href="javascript:window.compromised=1">svg</a></svg>',
    '<math><mtext><img src=x onerror="window.compromised=1"></mtext></math>',
    '<template><img src=x onerror="window.compromised=1"></template>',
    '<noscript><p title="</noscript><img src=x onerror=window.compromised=1>">x',
    '<iframe srcdoc="<script>parent.compromised=1</script>"></iframe>',
    '<img srcset="https://leak.test/collect 1x" id="maincontent" name="document">',
    '<div style="position:fixed;inset:0;z-index:99999;background-image:url(https://leak.test/)">overlay</div>',
    '<form action="/cgi-bin/luci/admin/system/flash"><input name="token"></form>',
];

(async () => {
    const browser = await chromium.launch({
        channel: process.env.SECURITY_BROWSER_CHANNEL || 'msedge',
        headless: true,
    });
    try {
        const context = await browser.newContext();
        const page = await context.newPage();
        await page.route('**/*', route => route.abort());
        const result = await page.evaluate(({ implementation, attacks }) => {
            window.compromised = 0;
            window.E = (tag, attrs) => {
                const node = document.createElement(tag);
                Object.keys(attrs).forEach(key => node.setAttribute(key, attrs[key]));
                return node;
            };
            const render = Function('return ({' + implementation + '}).announceHtml')();
            const failures = [];
            for (const html of attacks) {
                const box = render(html, 'https://panel.test');
                document.body.appendChild(box);
                for (const node of box.querySelectorAll('*')) {
                    if (/^(script|svg|math|iframe|template|form|input|object|embed|noscript)$/.test(node.localName))
                        failures.push('危险标签: ' + node.localName);
                    for (const attr of node.attributes) {
                        if (/^on|^(srcdoc|srcset|ping|id|name)$/.test(attr.name))
                            failures.push('危险属性: ' + attr.name);
                        if (['href', 'src', 'poster'].includes(attr.name)) {
                            const protocol = new URL(attr.value, 'https://router.test').protocol;
                            if (!['http:', 'https:'].includes(protocol) &&
                                !(node.localName === 'a' && protocol === 'mailto:'))
                                failures.push('危险协议: ' + protocol);
                        }
                    }
                    if (node.style.position || node.style.zIndex || node.style.backgroundImage)
                        failures.push('危险样式');
                }
                box.remove();
            }
            const normal = render('<p style="color:red;font-weight:bold">正文</p>' +
                '<a href="/user/shop">商店</a><img src="/images/a.png">' +
                '<video controls src="https://media.test/a.mp4"></video>' +
                '<table><tr><td>表格</td></tr></table>', 'https://panel.test');
            return {
                failures,
                compromised: window.compromised,
                color: normal.querySelector('p').style.color,
                weight: normal.querySelector('p').style.fontWeight,
                href: normal.querySelector('a').href,
                image: normal.querySelector('img').src,
                video: normal.querySelector('video').controls,
                cell: normal.querySelector('td').textContent,
            };
        }, { implementation, attacks });
        assert.deepEqual(result.failures, []);
        assert.equal(result.compromised, 0);
        assert.equal(result.color, 'red');
        assert.equal(result.weight, 'bold');
        assert.equal(result.href, 'https://panel.test/user/shop');
        assert.equal(result.image, 'https://panel.test/images/a.png');
        assert.equal(result.video, true);
        assert.equal(result.cell, '表格');
        console.log('OpenWrt 公告安全回归通过：15 组恶意输入及正常富文本。');
        await page.unroute('**/*');
        await page.route('**/*', route => route.fulfill({
            contentType: 'text/html', body: '<html><body></body></html>',
        }));
        await page.goto('https://router.test');
        const isolation = await page.evaluate(async source => {
            window._ = value => value;
            window.baseclass = { extend: value => value };
            const pending = [];
            window.rpc = { declare: options => () => new Promise(resolve => {
                pending.push({ method: options.method, resolve });
            }) };
            const api = Function(source)();
            const session = id => ({ id, logged_in: !!id, email: id + '@test' });
            const status = async (id, stats) => {
                const request = api.status();
                pending.shift().resolve({ session: session(id), statistics: stats || {} });
                await request;
            };
            const statsA = { today: '2026-10-04', rank: { '2026-10-04': { hosts: { 'private-a.test': 123 } } } };
            const statsB = { today: '2026-10-04', rank: { '2026-10-04': { hosts: { 'private-b.test': 321 } } } };
            await status('a', statsA);
            const connections = api.connections();
            pending.shift().resolve({ session: session('a'), connections: [], closed: [{ id: 'old', host: 'private-a.test' }] });
            await connections;
            const same = api.trafficRank('today', {}).hosts;
            const late = api.groups().then(() => false, () => true);
            const old = pending.shift();
            await status('b');
            const cleared = {
                closed: api.ingestConnections([]).closed,
                hosts: api.trafficRank('today', {}).hosts,
            };
            old.resolve({ session: session('a'), groups: [{ name: 'private-a' }] });
            const rejected = await late;
            await status('b', statsB);
            const retained = api.trafficRank('today', {}).hosts;
            await status('');
            return { same, cleared, rejected, retained,
                guest: api.trafficRank('today', {}).hosts };
        }, source);
        assert.equal(isolation.same[0].name, 'private-a.test');
        assert.deepEqual(isolation.cleared, { closed: [], hosts: [] });
        assert.equal(isolation.rejected, true);
        assert.equal(isolation.retained[0].name, 'private-b.test');
        assert.deepEqual(isolation.guest, []);
        console.log('OpenWrt 浏览器账户隔离回归通过：历史清理、迟到响应拒绝、同会话保留及登出清理。');
        const kickFlow = await page.evaluate(async source => {
            const cases = [];
            for (const scenario of ['background-cancel', 'background-confirm', 'standby', 'connect-pending']) {
                window.rpc = { declare: () => async () => ({ ok: true }) };
                const api = Function(source)();
                const calls = [];
                let resolveRefresh;
                const account = { node_connector: 1, online_client_count: 1, online_client_self: false };
                api.refreshAccount = async () => scenario === 'connect-pending'
                    ? new Promise(resolve => { resolveRefresh = () => resolve({ ok: true, account }); })
                    : { ok: true, account };
                api.stop = async () => { calls.push('stop'); return { ok: true }; };
                api.ackDeviceKick = async () => { calls.push('ack'); return { ok: true }; };
                api.onlineDevices = async () => ({ devices: [{ device_id: 'other' }] });
                api.confirmDeviceLimitKick = () => {
                    calls.push('confirm');
                    return Promise.resolve(scenario === 'background-confirm' ? 'other' : null);
                };
                api.reclaimDeviceSlot = async id => { calls.push('reclaim:' + id); return { ok: true }; };
                api.start = async () => { calls.push('start'); return { ok: true }; };
                api.notify = () => { calls.push('notify'); };
                const status = { enabled: false, running: true, stage: 'stopped',
                    device_kicked: scenario !== 'standby', device_kick_reason: 'limit_denied',
                    account: { device_kick_notice: true, device_kick_reason: 'limit_denied' } };
                if (scenario === 'connect-pending') {
                    const pending = api.connect();
                    while (!resolveRefresh) await Promise.resolve();
                    await api.handleDeviceKick(status);
                    resolveRefresh();
                    await pending;
                } else await api.handleDeviceKick(status);
                cases.push({ scenario, calls });
            }
            return cases;
        }, source);
        assert.deepEqual(kickFlow, [
            { scenario: 'background-cancel', calls: ['confirm', 'ack'] },
            { scenario: 'background-confirm', calls: ['confirm', 'reclaim:other', 'ack'] },
            { scenario: 'standby', calls: ['ack'] },
            { scenario: 'connect-pending', calls: ['start'] },
        ]);
        console.log('OpenWrt 名额拒绝回归通过：已有连接保持、确认、取消及并发连接去重。');
        const cachedConnect = await page.evaluate(async source => {
            const cases = [];
            for (const scenario of ['available', 'refused', 'cancelled']) {
                const calls = [];
                let finishRefresh;
                const reply = { ok: scenario !== 'refused', account: {}, session: { id: 'cached-session', logged_in: true } };
                window.rpc = { declare: options => (...args) => {
                    calls.push([options.method, ...args]);
                    if (options.method === 'refresh_account' && scenario === 'cancelled')
                        return new Promise(resolve => { finishRefresh = () => resolve(reply); });
                    return Promise.resolve(reply);
                } };
                const api = Function(source)();
                await api.status();
                calls.length = 0;
                const pending = api.connect();
                if (scenario === 'cancelled') {
                    await api.stop();
                    finishRefresh();
                }
                const result = await pending;
                cases.push({ scenario, calls, ok: result.ok === true, cancelled: result.cancelled === true });
            }
            return cases;
        }, source);
        assert.deepEqual(cachedConnect, [
            { scenario: 'available', calls: [['refresh_account', true], ['start']], ok: true, cancelled: false },
            { scenario: 'refused', calls: [['refresh_account', true]], ok: false, cancelled: false },
            { scenario: 'cancelled', calls: [['refresh_account', true], ['stop']], ok: false, cancelled: true },
        ]);
        console.log('OpenWrt 缓存连接回归通过：有效缓存连接、资料拒绝及在途连接取消。');
        await page.goto('https://router.test');
        const peer = await page.context().newPage();
        await peer.route('**/*', route => route.fulfill({
            contentType: 'text/html', body: '<html><body></body></html>',
        }));
        await peer.goto('https://router.test');
        const initialize = async target => target.evaluate(source => {
            window._ = value => value;
            window.baseclass = { extend: value => value };
            window.E = (tag, attrs = {}, children = []) => {
                const element = document.createElement(tag);
                Object.entries(attrs).forEach(([key, value]) => element.setAttribute(key, value));
                children.forEach(child => element.append(child));
                return element;
            };
            window.auditSession = 'a';
            window.rpc = { declare: () => async () => ({
                session: { id: window.auditSession, logged_in: !!window.auditSession },
                connected_at: 1000,
            }) };
            window.auditApi = Function(source)();
            auditApi.detectTheme = () => 'light';
            auditApi._shadowCss = ' ';
            return auditApi.status();
        }, source);
        await initialize(page);
        await initialize(peer);
        await page.evaluate(() => auditApi.showText('配置', 'private-account-a'));
        assert.equal(await page.locator('.ecycloud-textview').textContent(), 'private-account-a');
        await page.evaluate(() => {
            Object.defineProperty(navigator, 'clipboard', { configurable: true, value: null });
            document.execCommand = () => {
                window.copiedText = document.querySelector('.ecycloud-copy-buffer').value;
                return true;
            };
        });
        await page.locator('.ecycloud-modal-copy').click();
        assert.equal(await page.evaluate(() => window.copiedText), 'private-account-a');
        assert.equal(await page.locator('.ecycloud-modal-copy').textContent(), 'Copied');
        const clock = await page.evaluate(() => ({ age: auditApi.connectedSince(true), now: Date.now(), stopped: auditApi.connectedSince(false) }));
        assert.ok(Math.abs(clock.age - (clock.now - 1000000)) < 50);
        assert.equal(clock.stopped, 0);
        await page.evaluate(() => auditApi.alert('fixture notice'));
        assert.equal(await page.locator('.ecycloud-modal.is-alert .ecycloud-modal-copy').count(), 0);
        await page.locator('.ecycloud-modal.is-alert .ecycloud-modal-ok').click();
        console.log('OpenWrt 文本复制与计时回归通过：全文复制、按钮反馈、真实接管时间及普通提示范围。');
        const lateResult = new Promise((resolve, reject) => {
            const timeout = setTimeout(() => reject(new Error('未收到跨标签页清理结果')), 8000);
            page.on('console', message => {
                if (message.text().startsWith('AUDIT_SESSION:')) {
                    clearTimeout(timeout);
                    resolve(JSON.parse(message.text().slice('AUDIT_SESSION:'.length)));
                }
            });
        });
        await page.evaluate(() => window.addEventListener('storage', async event => {
            if (event.key !== 'ecycloud.session' || event.newValue !== 'b')
                return;
            const cleared = !document.querySelector('.ecycloud-modal');
            auditApi.showText('迟到配置', 'private-account-a');
            const rejected = await auditApi.status().then(() => false, () => true);
            console.log('AUDIT_SESSION:' + JSON.stringify({
                cleared, rejected, stayedClear: !document.querySelector('.ecycloud-modal'),
            }));
        }));
        await peer.evaluate(async () => {
            window.auditSession = 'b';
            await auditApi.status();
        });
        assert.deepEqual(await lateResult, { cleared: true, rejected: true, stayedClear: true });
        await page.waitForTimeout(100);
        assert.equal(await page.locator('.ecycloud-textview').count(), 0,
            '另一个标签页切换账户后，旧配置弹窗必须关闭');
        await peer.close();
        await page.goto('https://router.test');
        console.log('OpenWrt 跨标签页回归通过：旧账户配置弹窗被清除。');
        const credentials = await page.evaluate(async overview => {
            window._ = value => value;
            String.prototype.format = function(value) { return this.replace('%s', value); };
            window.L = { resource: value => value, bind: (fn, self) => fn.bind(self) };
            window.E = (tag, attrs = {}, children = []) => {
                const element = document.createElement(tag);
                Object.entries(attrs).forEach(([key, value]) => element.setAttribute(key, value));
                children.forEach(child => element.append(child));
                return element;
            };
            window.view = { extend: value => value };
            window.ui = { createHandlerFn: (self, fn) => fn.bind(self) };
            let submitted;
            window.api = {
                input: attrs => E('input', attrs),
                pressable: (className, attrs, children) => E('button', { class: className, ...attrs }, children),
                notify: () => {},
                login: async (email, password) => {
                    submitted = { email, password };
                    return { ok: true };
                },
            };
            localStorage.setItem('ecycloud-remember', JSON.stringify({
                email: 'audit@example.test', password: 'legacy-test-password',
            }));
            const screen = Function(overview)();
            screen.showLogin = () => {};
            screen.refresh = async () => {};
            const login = screen.renderLogin({ site: 'https://panel.test' });
            document.body.appendChild(login);
            const password = login.querySelector('input[type=password]');
            const previous = password.value;
            const migrated = JSON.parse(localStorage.getItem('ecycloud-remember'));
            password.value = 'new-test-password';
            login.querySelector('.ecycloud-login-submit').click();
            await new Promise(resolve => setTimeout(resolve, 0));
            const saved = JSON.parse(localStorage.getItem('ecycloud-remember'));
            login.querySelector('.ecycloud-login-remember').click();
            return { previous, migrated, saved, submitted,
                cleared: localStorage.getItem('ecycloud-remember') };
        }, overview);
        assert.equal(credentials.previous, '');
        assert.deepEqual(credentials.migrated, { email: 'audit@example.test' });
        assert.deepEqual(credentials.saved, { email: 'audit@example.test' });
        assert.deepEqual(credentials.submitted, {
            email: 'audit@example.test', password: 'new-test-password',
        });
        assert.equal(credentials.cleared, null);
        console.log('OpenWrt 登录安全回归通过：旧密码清理、登录传参、仅保存邮箱及取消记住。');
        const resourceDir = path.join(__dirname, '../htdocs/luci-static/resources/view/ecycloud');
        const style = fs.readFileSync(path.join(resourceDir, 'style.css'), 'utf8');
        const translations = JSON.parse(fs.readFileSync(path.join(resourceDir, 'i18n.zh-cn.json'), 'utf8'));
        const nodes = fs.readFileSync(path.join(resourceDir, 'nodes.js'), 'utf8');
        const prepareRank = async (target, theme) => {
            await target.route('**/*', route => route.fulfill({
                contentType: 'text/html', body: '<html><head><meta name="viewport" content="width=device-width, initial-scale=1"></head><body></body></html>',
            }));
            await target.goto('https://router.test');
            await target.addStyleTag({ content: style });
            await target.evaluate(({ source, overview, nodes, translations, theme }) => {
                window._ = text => translations[text] || text;
                window.baseclass = { extend: value => value };
                window.view = { extend: value => value };
                window.rpc = { declare: () => () => Promise.resolve({}) };
                window.L = { resource: value => value, bind: (fn, self) => fn.bind(self) };
                window.ui = { createHandlerFn: () => () => {} };
                window.E = (tag, attrs = {}, children = []) => {
                    const element = document.createElement(tag);
                    Object.entries(attrs).forEach(([key, value]) => {
                        if (value != null) element.setAttribute(key, value);
                    });
                    children.forEach(child => element.append(child));
                    return element;
                };
                window.api = Function(source)();
                api.trafficRank = () => ({ groups: [], hosts: [] });
                const screen = Function(overview)();
                const nodeScreen = Function(nodes)();
                screen.cache = {};
                document.body.append(E('div', { class: 'ecycloud-ui', 'data-theme': theme }, [
                    screen.renderTrafficRank(),
                    api.pressable('ecycloud-btn', {}, [ E('span', { class: 'ecycloud-ico', 'data-ico': 'start' }), '连接' ]),
                    api.pressable('ecycloud-modal-ok', {}, [ '确定' ]),
                    api.pressable('ecycloud-modal-cancel', {}, [ '关闭' ]),
                    E('div', { class: 'cbi-value-field' }, [ api.pressable('ecycloud-btn', {}, [ '检查更新' ]) ]),
                    api.pressable('ecycloud-jump', {}, [ '确定' ]),
                    E('div', { class: 'ecycloud-ann-nav' }, [ api.pressable('ecycloud-modal-cancel', {}, [ '确定' ]) ]),
                    E('div', { class: 'ecycloud-modal-choice is-action' }, [ api.pressable('ecycloud-modal-ok', {}, [ '确定' ]) ]),
                    E('div', { class: 'cbi-page-actions' }, [ api.pressable('cbi-button cbi-button-reset', {}, [ '复位' ]) ]),
                    api.pressable('ecycloud-dyn-add', { 'aria-label': '添加' }),
                    nodeScreen.renderMember({ type: 'Selector', now: 'flag' }, { name: 'flag', label: '🇩🇪 德国测试节点', protocol: 'VLESS', network: 'ws' }),
                    nodeScreen.renderMember({ type: 'Selector' }, { name: 'plain', label: '无地区节点', protocol: 'VLESS' }),
                    E('div', { style: 'height: 1200px' }),
                ]));
            }, { source, overview, nodes, translations, theme });
        };
        await page.setViewportSize({ width: 1000, height: 500 });
        await prepareRank(page, 'light');
        const info = page.locator('.ecycloud-rank-info [role="button"]');
        const tooltip = page.locator('[role="tooltip"]');
        assert.equal(await tooltip.isVisible(), false);
        await info.hover();
        assert.equal(await tooltip.isVisible(), true);
        assert.equal(await tooltip.textContent(), '统计数据仅储存于本地，只保留最近两天的数据，只统计当前设备的流量使用，不同设备之间的流量数据不同步。');
        const buttonBox = await info.boundingBox();
        const tipBox = await tooltip.boundingBox();
        assert.ok(tipBox.x >= buttonBox.x + buttonBox.width && tipBox.x + tipBox.width <= 1000,
            '桌面提示文字必须位于标题旁图标右侧，且不能超出视口');
        const light = await tooltip.evaluate(node => getComputedStyle(node).backgroundColor);
        const actionButtons = '.ecycloud-btn, .ecycloud-modal-ok, .ecycloud-modal-cancel, .ecycloud-jump, .cbi-page-actions .cbi-button, .ecycloud-dyn-add';
        const sizes = await page.locator(actionButtons).evaluateAll(buttons => buttons.map(button => ({ label: button.textContent || button.getAttribute('aria-label'), height: button.getBoundingClientRect().height })));
        assert.ok(sizes.every(button => button.height === 32), '常规操作按钮必须等高，包括设置行、弹窗、翻页、添加与底部动作：' + JSON.stringify(sizes));
        const sameCaption = await page.locator(actionButtons).evaluateAll(buttons => buttons.filter(button => button.textContent === '确定').map(button => button.getBoundingClientRect().width));
        assert.ok(sameCaption.every(width => width === sameCaption[0]), '填充和描边按钮使用相同文案时必须等宽');
        assert.equal((await page.locator('.ecycloud-seg').boundingBox()).height, 32, '分段按钮连同外框必须与操作按钮等高');
        const aligned = await page.locator('.ecycloud-node').evaluateAll(cards => cards.map(card => Math.abs(card.querySelector('.ecycloud-node-name').getBoundingClientRect().left - card.querySelector('.ecycloud-tag').getBoundingClientRect().left)));
        assert.ok(aligned.every(delta => delta < 0.1), '协议标签必须与包含国旗的名称行左边缘对齐');
        const placement = await info.evaluate(button => {
            const title = button.closest('.ecycloud-card-title').firstElementChild;
            const text = document.createRange();
            text.selectNodeContents(title.firstChild);
            const label = text.getBoundingClientRect();
            const bounds = button.getBoundingClientRect();
            const icon = getComputedStyle(button, '::before');
            return { gap: bounds.left + parseFloat(icon.marginLeft) - label.right,
                topDelta: bounds.y + parseFloat(icon.marginTop) - label.y,
                centerDx: parseFloat(icon.marginLeft) + parseFloat(icon.width) / 2 - bounds.width / 2,
                centerDy: parseFloat(icon.marginTop) + parseFloat(icon.height) / 2 - bounds.height / 2,
                width: icon.width, height: icon.height };
        });
        assert.ok(placement.gap > 0 && placement.gap <= 12 && Math.abs(placement.topDelta) <= 3,
            '感叹号顶边必须对齐流量排行文字顶边');
        assert.ok(Math.abs(placement.centerDx) < 0.1 && Math.abs(placement.centerDy) < 0.1,
            '感叹号必须位于悬停背景正中心');
        assert.equal(placement.width, '14px');
        assert.equal(placement.height, '14px');
        await info.click();
        assert.equal(await tooltip.isVisible(), false, '桌面再次点击感叹号必须收起');
        await info.click();
        assert.equal(await tooltip.isVisible(), true);
        await page.mouse.wheel(0, 1);
        await page.waitForFunction(() => window.scrollY > 0);
        const scrolledButton = await info.boundingBox();
        assert.ok(buttonBox.y + buttonBox.height / 2 > scrolledButton.y && buttonBox.y + buttonBox.height / 2 < scrolledButton.y + scrolledButton.height,
            '滚动一像素后鼠标位置仍在感叹号范围内');
        assert.equal(await tooltip.isVisible(), false, '鼠标仍停在感叹号上时滚动也必须收起');
        assert.equal(await info.getAttribute('aria-expanded'), 'false');
        await page.mouse.move(0, 0);
        await page.evaluate(() => window.scrollTo(0, 0));
        await page.evaluate(() => {
            const root = document.querySelector('.ecycloud-ui');
            root.style.marginLeft = '400px';
            root.style.width = '600px';
        });
        await page.mouse.move(0, 0);
        await info.hover();
        const compactBox = await tooltip.boundingBox();
        const compactButton = await info.boundingBox();
        assert.ok(compactBox.x >= compactButton.x + compactButton.width && compactBox.x + compactBox.width <= 1000,
            '侧栏压缩内容宽度时，右侧提示也不能超出视口');
        const touchContext = await browser.newContext({ viewport: { width: 390, height: 600 }, isMobile: true, hasTouch: true });
        const touchPage = await touchContext.newPage();
        await prepareRank(touchPage, 'dark');
        const touchSizes = await touchPage.locator(actionButtons).evaluateAll(buttons => buttons.map(button => button.getBoundingClientRect().height));
        assert.ok(touchSizes.every(height => height === 32), '窄屏、深色主题的操作按钮也必须等高');
        assert.equal((await touchPage.locator('.ecycloud-seg').boundingBox()).height, 32);
        const touchAligned = await touchPage.locator('.ecycloud-node').evaluateAll(cards => cards.map(card => card.querySelector('.ecycloud-node-name').getBoundingClientRect().left - card.querySelector('.ecycloud-tag').getBoundingClientRect().left));
        assert.ok(touchAligned.every(delta => delta === 0), '窄屏下协议标签不能向右缩进');
        const touchInfo = touchPage.locator('.ecycloud-rank-info [role="button"]');
        const touchTip = touchPage.locator('[role="tooltip"]');
        await touchInfo.tap();
        assert.equal(await touchTip.isVisible(), true);
        const touchBox = await touchTip.boundingBox();
        assert.ok(touchBox.x >= 0 && touchBox.x + touchBox.width <= 390, '移动端提示不能超出视口');
        assert.notEqual(await touchTip.evaluate(node => getComputedStyle(node).backgroundColor), light,
            '深色模式提示必须使用深色背景');
        await touchTip.tap({ position: { x: 20, y: 10 } });
        const selected = await touchTip.evaluate(node => {
            document.activeElement.blur();
            const range = document.createRange();
            range.selectNodeContents(node);
            const selection = window.getSelection();
            selection.removeAllRanges();
            selection.addRange(range);
            node.parentElement.dispatchEvent(new MouseEvent('mouseleave'));
            return selection.toString();
        });
        await touchPage.waitForTimeout(150);
        assert.ok(selected.length > 0, '移动端说明内容必须能够选中');
        assert.equal(await touchTip.isVisible(), true, '移动端选中文字导致失焦或移出时不得收起说明');
        assert.equal(await touchPage.locator('.ecycloud-node').first().evaluate(node => getComputedStyle(node).paddingTop), '4.5px');
        await touchInfo.tap();
        assert.equal(await touchTip.isVisible(), false);
        await touchInfo.tap();
        await touchPage.locator('.ecycloud-ui').tap({ position: { x: 1, y: 1 } });
        assert.equal(await touchTip.isVisible(), false, '移动端点击空白处必须收起说明');
        for (const offset of [20, 0]) {
            await touchInfo.tap();
            assert.equal(await touchTip.isVisible(), true);
            await touchPage.evaluate(offset => window.scrollTo(0, offset), offset);
            await touchPage.waitForFunction(offset => window.scrollY === offset, offset);
            await touchPage.waitForTimeout(50);
            assert.equal(await touchTip.isVisible(), false, '移动端上下滚动都必须收起说明');
        }
        await touchContext.close();
        console.log('OpenWrt 界面回归通过：按钮尺寸、节点标签、排行标题右上角图标、文字选中、悬停与点击、上下滚动收起、窄屏边界及深色主题。');
    } finally {
        await browser.close();
    }
})().catch(error => { console.error(error); process.exitCode = 1; });
