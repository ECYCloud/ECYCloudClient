export const testState = global.ecycloudTestState ?? {
	files: {}, writes: {}, commands: [], paths: {}, info: {},
	random: '0123456789abcdef0123456789abcdef',
	config: { run_dir: '/etc/ecycloud/run' },
	onRequest: null, response: null, log: '',
	authBusy: false, workBusy: false, failedUnlink: '', commandStatus: 0, commandText: '', responses: {}
};
global.ecycloudTestState = testState;
export function access(path) {
	return path == '/etc/ecycloud' || path == '/var/run/ecycloud' ||
		exists(testState.files, path) || exists(testState.paths, path);
};
export function chmod() { return true; };
export function lsdir(path) {
	const names = {};
	for (let key in keys(testState.files))
		if (index(key, path + '/') == 0)
			names[split(substr(key, length(path) + 1), '/')[0]] = true;
	return keys(names);
};
export function open(path) {
	return { read: size => substr(testState.random, 0, size), close: () => true,
		lock: () => {
			if (testState.onLock)
				testState.onLock(path);
			return path == '/var/run/ecycloud/account-switch.lock' ? !testState.authBusy :
				path == '/var/run/ecycloud/session.lock' ? !testState.workBusy : true;
		} };
};
export function popen(command) {
	push(testState.commands, command);
	if (testState.onCommand)
		testState.onCommand(command);
	if (exists(testState.responses, command)) {
		const response = testState.responses[command];
		if (response.read)
			return response;
		let offset = 0;
		return { read: size => {
			const chunk = substr(response.text, offset, type(size) == 'int' ? size : length(response.text));
			offset += length(chunk);
			if (response.onRead)
				response.onRead(chunk);
			return chunk;
		}, close: () => response.status };
	}
	if (index(command, 'sha256sum ') == 0) {
		let hash = 5381;
		const text = testState.files['/etc/ecycloud/credentials.json'] ?? '';
		for (let i = 0; i < length(text); i++)
			hash = ((hash * 33) + ord(substr(text, i, 1))) & 0xffffffff;
		return { read: () => join('', map([1,2,3,4,5,6,7,8], () => sprintf('%08x', hash))) + '  fixture', close: () => 0 };
	}
	if (index(command, 'curl ') == 0 && testState.onRequest)
		testState.onRequest();
	return { read: () => index(command, 'logread ') == 0 ? testState.log :
		index(command, 'curl ') == 0 ? `${testState.httpStatus ?? 200}` : testState.commandText, close: () => testState.commandStatus };
};
export function readfile(path, limit) {
	if (testState.responseHeaders != null && match(path, /\/resp-[a-f0-9]+\.headers$/))
		return limit == null ? testState.responseHeaders : substr(testState.responseHeaders, 0, limit);
	if (testState.response != null && match(path, /\/resp-[a-f0-9]+\.json$/))
		return sprintf('%J', testState.response);
	const value = testState.files[path];
	return limit == null || value == null ? value : substr(value, 0, limit);
};
export function realpath(path) { return testState.paths[path]; };
export function stat(path) { return testState.info[path]; };
export function lstat(path) {
	return testState.info[path] ?? (exists(testState.files, path) ? { type: 'file', nlink: 1 } :
		path == testState.config.run_dir ? { type: 'directory' } : null);
};
export function mkdir() { return true; };
export function rmdir() { return true; };
export function rename(from, to) {
	if (testState.failedRename)
		return false;
	testState.files[to] = testState.files[from]; delete testState.files[from]; return true;
};
export function unlink(path) {
	if (path == testState.failedUnlink)
		return false;
	delete testState.files[path];
	return true;
};
export function writefile(path, value) {
	if (path == testState.failedWrite)
		return null;
	if (testState.onWrite)
		testState.onWrite(path, value);
	testState.files[path] = value;
	testState.writes[path] = value;
	return length(value);
};
