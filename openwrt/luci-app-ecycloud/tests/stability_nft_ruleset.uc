'use strict';

import { testState } from 'fs';
import { settings } from 'ecycloud.common';
import { apply } from 'ecycloud.network';

global.system = () => 0;
testState.config = {
	enabled: '1', device: 'br-lan', mode: 'tproxy',
	ipv6: ARGV[0] ?? '1', router_proxy: ARGV[1] ?? '1',
	bypass: [ '10.1.0.0/24', 'fd00:1::/64' ]
};
const result = apply(settings());
if (!result.ok)
	die(result.error);
print(testState.files['/usr/share/nftables.d/ruleset-post/ecycloud.nft']);
