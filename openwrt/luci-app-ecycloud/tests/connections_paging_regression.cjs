'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

const resources = path.join(__dirname, '../htdocs/luci-static/resources');
const source = fs.readFileSync(path.join(resources, 'ecycloud/api.js'), 'utf8');

const node = (tag, attrs = {}, children) => ({ tag, attrs, children: children || [], style: {},
    remove() {}, appendChild() {}, isConnected: true });
const textOf = value => typeof value == 'string' ? value : Array.isArray(value)
    ? value.map(textOf).join(' ') : value && value.children ? textOf(value.children) : '';
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

async function pages() {
    const calls = [];
    const waiting = [];
    let filter;
    const total = { active: 4000, closed: 1000 };
    const reply = (scope, keyword, page) => {
        const matched = keyword ? { active: 100, closed: 25 } : total;
        const count = (scope == 'closed' ? 0 : matched.active) + (scope == 'active' ? 0 : matched.closed);
        const last = Math.max(1, Math.ceil(count / 100));
        const current = Math.min(last, Math.max(1, page));
        return { session: { logged_in: true }, at: 100 + calls.length, total, matched, page: current, pages: last,
            connections: [{ id: scope + '-' + keyword + '-' + current, host: 'row-' + current + '.test', active: scope != 'closed', chains: [] }], detail: null };
    };
    const api = new Proxy({
        signedIn: () => true, status: async () => ({ running: true, session: { logged_in: true } }),
        connections: (scope, keyword, page, limit, id) => {
            calls.push([scope, keyword, page, limit, id]);
            return new Promise(resolve => waiting.push(() => resolve(reply(scope, keyword, page))));
        },
        segments: (items, current, change) => { filter = { items, current, change }; return node('div', {}, items.map(item => item.label)); },
        pressable: (cls, attrs, children) => node('button', Object.assign({ class: cls }, attrs), children),
        messageText: String, bytes: String, duration: String, processName: () => '', flagText: text => [text]
    }, { get: (target, key) => key in target ? target[key] : () => '' });
    const view = vm.runInNewContext('String.prototype.format = function() { var args = arguments, i = 0; return this.replace(/%[sd]/g, () => String(args[i++])); }; (function(){' +
        fs.readFileSync(path.join(resources, 'view/ecycloud/connections.js'), 'utf8') + '})()', {
        view: { extend: value => value }, api, E: node, _: String, poll: {}, window: { getSelection: () => '' },
        dom: { content: (target, content) => target.children = [content] }, document: {},
        L: { bind: (fn, context, ...args) => fn.bind(context, ...args) }
    });
    Object.assign(view, { body: node('div'), filterBar: node('div'), scope: 'all', keyword: '' });
    const settle = async action => {
        const done = action();
        await new Promise(resolve => setImmediate(resolve));
        waiting.splice(0).forEach(resolve => resolve());
        await done;
        await new Promise(resolve => setImmediate(resolve));
    };
    const pager = () => find(view.body, item => item.attrs.class == 'ecycloud-jump');
    const shown = () => textOf(view.body);

    await settle(() => view.refresh());
    assert.deepEqual(calls.pop(), ['all', '', 1, 100, ''], '首次按第 1 页、每页 100 条请求');
    assert.deepEqual(Array.from(filter.items, item => item.label), ['All 5000', 'Active 4000', 'Closed 1000'], '计数用服务端给的真实总数，不是本页条数');
    assert.ok(shown().includes('1 / 50 · 5000 items') && shown().includes('row-1.test'));
    assert.equal(pager()[0].attrs.disabled, true, '第一页不能再往前翻');

    await settle(() => pager()[1].attrs.click());
    assert.deepEqual(calls.pop(), ['all', '', 2, 100, ''], '下一页带上页码重新请求');
    assert.ok(shown().includes('2 / 50 · 5000 items') && shown().includes('row-2.test'));

    await settle(() => view.refresh());
    assert.deepEqual(calls.pop(), ['all', '', 2, 100, ''], '轮询刷新停留在当前页');

    await settle(() => filter.change('closed'));
    assert.deepEqual(calls.pop(), ['closed', '', 1, 100, ''], '切换筛选后页码复位');
    assert.ok(shown().includes('1 / 10 · 1000 items'));

    await settle(() => view.turn(7));
    view.keyword = 'wanted';
    await settle(() => view.turn(1));
    assert.deepEqual(calls.pop(), ['closed', 'wanted', 1, 100, ''], '搜索词交给服务端先过滤再分页，页码复位');
    assert.deepEqual(Array.from(filter.items, item => item.label), ['All 125', 'Active 100', 'Closed 25'], '搜索时显示匹配数');
    assert.equal(pager().length, 0, '只有一页时不显示翻页');

    view.scope = 'all';
    const slow = view.turn(2);
    await new Promise(resolve => setImmediate(resolve));
    const late = waiting.splice(0);
    await settle(() => view.turn(1));
    late.forEach(resolve => resolve());
    await slow;
    assert.equal(view.page, 1, '先发后到的旧应答不能覆盖最新一次请求的结果');

    view.detail = { node: { isConnected: true }, item: { id: 'c9', upload: 1, download: 1 }, active: true, at: 1, speed: {},
        fields: node('div'), closeBtn: node('button') };
    await settle(() => view.refresh());
    assert.equal(calls.pop()[4], 'c9', '详情打开时把连接标识带给服务端，不依赖它在不在当前页');
    assert.equal(view.detail.active, false, '服务端查不到该连接时详情转为已关闭');
}

async function chunks() {
    const method = source.slice(source.indexOf('\ttextFile: function('), source.indexOf('\n\truntimeConfig: function('));
    const text = 'α'.repeat(40) + 'tail';
    const run = async serve => {
        const calls = [];
        const api = vm.runInNewContext('({' + method.replace(/,\s*$/, '') + '})', {
            updateRpc: async (what, file, locale, offset, version) => { calls.push([what, file, offset, version]); return serve(offset, version, calls.length); }
        });
        return { result: await api.textFile('rule', './list.txt'), calls };
    };
    const piece = (offset, version) => ({ ok: true, text: text.slice(offset, offset + 16), next: offset + 16, done: offset + 16 >= text.length, version });
    const whole = await run((offset, version) => offset > 0 && version != 'v1' ? { ok: false, stale: true } : piece(offset, 'v1'));
    assert.equal(whole.result.text, text, '分块取回后拼接必须与原文一致');
    assert.deepEqual(whole.calls.slice(0, 2), [['rule', './list.txt', 0, ''], ['rule', './list.txt', 16, 'v1']], '后续分块带回偏移与同一版本标识');
    const changed = await run((offset, version, count) => count == 2 ? { ok: false, stale: true, msg: '内容已变化，请重新打开' }
        : piece(offset, count < 2 ? 'v1' : 'v2'));
    assert.equal(changed.result.text, text, '中途内容变化时从头重取，不能拼出新旧混杂的文本');
    assert.deepEqual(changed.calls[2], ['rule', './list.txt', 0, ''], '版本变化后回到开头');
    const stuck = await run(offset => offset > 0 ? { ok: false, stale: true, msg: '内容已变化，请重新打开' } : piece(0, 'v'));
    assert.ok(stuck.result.ok === false && stuck.calls.length == 8, '内容一直在变时重试有上限，并把提示交给页面');
    const failed = await run(() => ({ ok: false, msg: '无效路径' }));
    assert.equal(failed.result.msg, '无效路径', '读取失败原样交给页面');
}

Promise.all([pages(), chunks()]).then(() => console.log('OpenWrt 连接分页与文本分块回归通过。'), error => {
    console.error(error);
    process.exit(1);
});
