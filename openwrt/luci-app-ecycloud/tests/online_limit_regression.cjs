'use strict';
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const root = path.join(__dirname, '..');
const source = fs.readFileSync(path.join(root, 'htdocs/luci-static/resources/ecycloud/api.js'), 'utf8');
const methods = source.slice(source.indexOf('\tonlineDeviceText: function('), source.indexOf('\n\twatchKick: function('));
const kick = source.slice(source.indexOf('\thandleDeviceKick: function('), source.indexOf('\n\tpage: function('));

async function main() {
    for (const limit of [0, 1]) {
        for (const reason of ['limit', 'limit_denied']) {
            const calls = [];
            const account = { node_connector: limit, online_client_count: 99,
                online_client_self: false, device_kick_notice: true, device_kick_reason: reason };
            const context = { connectGeneration: 0, connectPending: null, kickBusy: false, _: s => s };
            const api = vm.runInNewContext('({' + methods + kick + '})', context);
            api.refreshAccount = async () => ({ ok: true, account });
            api.onlineDevices = async () => ({ devices: [] });
            api.confirmDeviceLimitKick = async () => { calls.push('confirm'); return null; };
            api.start = async () => { calls.push('start'); return { ok: true }; };
            api.stop = async () => { calls.push('stop'); return { ok: true }; };
            api.phase = () => 'connected';
            api.ackDeviceKick = async () => { calls.push('ack'); return { ok: true }; };
            api.dialog = async () => { calls.push('dialog'); return true; };
            api.notify = () => { calls.push('notify'); };
            await api.connect();
            assert.deepEqual(calls, ['start'], '延迟在线计数和历史通知不能阻止正常连接');
            await api.handleDeviceKick({ enabled: true, running: true, account });
            assert.equal(calls.includes('stop'), false, '自动限制通知不能停止已有正常连接');
            assert.equal(calls.includes('confirm'), reason === 'limit_denied' && limit > 0);
            calls.length = 0;
            account.online_client_self = true;
            await api.handleDeviceKick({ enabled: true, running: true, account });
            assert.equal(calls.includes('confirm'), false, '已在线设备不因迟到拒绝通知重新腾位');
            calls.length = 0;
            account.online_client_self = false;
            account.device_kick_reason = 'limit_denied';
            api.confirmDeviceLimitKick = async () => { calls.push('confirm'); return 'other-device'; };
            api.reclaimDeviceSlot = async target => { calls.push('reclaim:' + target); return { ok: true }; };
            await api.handleDeviceKick({ enabled: true, running: true, account });
            assert.deepEqual(calls, limit > 0 ? ['confirm', 'reclaim:other-device', 'ack'] : ['ack'],
                '确认腾位不能停止或重新启动现有连接');
            account.device_kick_reason = 'remove';
            await api.handleDeviceKick({ enabled: true, running: true, account });
            assert.equal(calls.includes('stop'), true, '主动下线仍停止目标设备');
        }
    }
    const service = fs.readFileSync(path.join(root, 'root/usr/share/ucode/ecycloud/service.uc'), 'utf8');
    const start = service.indexOf('function kickedByNotice(account)');
    const end = service.indexOf('\n};', start) + 3;
    const shouldStop = vm.runInNewContext('(' + service.slice(start, end).replace(/;$/, '') + ')');
    for (const reason of ['limit', 'limit_denied', 'remove']) {
        assert.equal(shouldStop({ ok: true, data: { device_kick_notice: true, device_kick_reason: reason, node_connector: 0 } }), reason === 'remove');
    }
    console.log('OpenWrt 在线数量离线回归通过：旧计数、0上限、迟到通知、取消与接受腾位、正常连接及主动下线。');
}
main().catch(error => { console.error(error); process.exitCode = 1; });
