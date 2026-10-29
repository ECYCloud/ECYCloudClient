import { testState } from 'fs';
export function cursor() {
	return {
		get_all: () => testState.config,
		get: (package, section, key) => testState.config[key],
		foreach: (package, section, callback) => callback({ '.name': 'test' }),
		set: (package, section, key, value) => { testState.config[key] = value; return true; },
		commit: () => true
	};
};
