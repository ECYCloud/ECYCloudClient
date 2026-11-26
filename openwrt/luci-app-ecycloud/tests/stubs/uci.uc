import { testState } from 'fs';
export function cursor() {
	return {
		get_all: () => testState.config,
		get: (package, section, key) => key == null ? (testState.configMissing ? null : 'ecycloud') :
			testState.uci?.[package]?.[section] != null ? testState.uci[package][section][key] : testState.config[key],
		foreach: (package, section, callback) => {
			for (let item in (testState.uci?.[package]?.[section] ?? [ { '.name': 'test' } ]))
				callback(item);
		},
		set: (package, section, key, value) => { testState.config[key] = value; return true; },
		commit: () => true
	};
};
