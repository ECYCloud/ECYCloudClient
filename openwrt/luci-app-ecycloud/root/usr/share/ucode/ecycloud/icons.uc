'use strict';

import { access, chmod, lsdir, popen, readfile, unlink, writefile } from 'fs';

import { cached } from 'ecycloud.profile';

import { CONF_DIR, STATE_DIR, creds, ensureDir, ensurePrivateDir, origins, randomHex, readJson,
         sha256File, shellquote, writeJson, writePrivateJson } from 'ecycloud.common';

const ICON_DIR = '/www/luci-static/resources/ecycloud/icons';
const MANIFEST = `${CONF_DIR}/icons.json`;
const PID_FILE = `${STATE_DIR}/icons.pid`;
const FAIL_FILE = `${STATE_DIR}/icons-fail.json`;
const MAX_BYTES = 1048576;

/* 与 app/lib/ui/widgets/group_icon.dart 的 defaultUrl、面板 ConfGenerate 同一地址 */
const DEFAULT_ICON = 'https://rules.ecydy.com/images/Custom.png';

function curlquote(value) {
	return '"' + replace(replace(replace(replace(replace(`${value}`, '\\', '\\\\'), '"', '\\"'), '\n', '\\n'), '\r', '\\r'), '\t', '\\t') + '"';
};

function accountName() {
	return lc(trim(creds().email ?? ''));
};

function iconFileName(name) {
	const text = `${name ?? ''}`;
	if (index(text, '.') != 64 || !match(substr(text, 0, 64), /^[0-9a-f]+$/))
		return false;
	const ext = substr(text, 65);
	return ext == 'png' || ext == 'jpg' || ext == 'gif' || ext == 'webp' || ext == 'svg';
};

export function acceptIconUrl(raw, site) {
	let text = trim(`${raw ?? ''}`);
	if (!length(text) || index(text, '\\') >= 0 || match(text, /[[:cntrl:][:space:]]/))
		return '';
	if (match(text, /^\/\//))
		return '';
	if (substr(text, 0, 1) == '/') {
		if (!match(`${site ?? ''}`, /^https:\/\/[^\/]+$/))
			return '';
		text = `${site}${text}`;
	}
	if (match(text, /^https:\/\/[^\/]*@/))
		return '';
	/* ucode 的正则是 POSIX ERE，不支持 (?: )，写进去 match() 会直接抛错，把分组接口整段打掉 */
	return match(text, /^https:\/\/[A-Za-z0-9._~-]+(:[0-9]{1,5})?(\/.*)?$/) ? text : '';
};

export function imageExt(bytes) {
	if (length(bytes) < 12)
		return '';
	if (substr(bytes, 0, 8) == "\x89PNG\r\n\x1a\n")
		return 'png';
	if (substr(bytes, 0, 3) == "\xff\xd8\xff")
		return 'jpg';
	if (substr(bytes, 0, 4) == 'GIF8')
		return 'gif';
	if (substr(bytes, 0, 4) == 'RIFF' && substr(bytes, 8, 4) == 'WEBP')
		return 'webp';
	const head = lc(substr(bytes, 0, 64));
	if (index(head, '<svg') == 0 || index(head, '<?xml') == 0)
		return 'svg';
	return '';
};

function explicitIcon(saved, name) {
	const icons = saved?.group_icons;
	if (type(icons) == 'object') {
		const mapped = trim(`${icons[name] ?? ''}`);
		return length(mapped) ? mapped : '';
	}

	for (let group in (saved?.config?.['proxy-groups'] ?? []))
		if (group?.name == name)
			return trim(`${group.icon ?? ''}`);

	return '';
};

function resolveIcon(saved, name, site) {
	const explicit = explicitIcon(saved, name);
	if (length(explicit))
		return acceptIconUrl(explicit, site);
	return acceptIconUrl(DEFAULT_ICON, site);
};

function groupNames(saved) {
	const names = [];
	const seen = {};

	for (let group in (saved?.config?.['proxy-groups'] ?? [])) {
		if (!length(group?.name) || seen[group.name])
			continue;
		seen[group.name] = true;
		push(names, group.name);
	}

	if (type(saved?.group_icons) == 'object') {
		for (let name in saved.group_icons) {
			if (!length(name) || seen[name])
				continue;
			seen[name] = true;
			push(names, name);
		}
	}

	return names;
};

function wanted(saved, site) {
	const urls = [];
	const seen = {};

	for (let name in groupNames(saved)) {
		const url = resolveIcon(saved, name, site);
		if (!length(url) || seen[url])
			continue;
		seen[url] = true;
		push(urls, url);
	}

	return urls;
};

function failUntil(url) {
	const saved = readJson(FAIL_FILE);
	return type(saved) == 'object' ? +(saved[url] ?? 0) : 0;
};

function noteFail(url) {
	const saved = type(readJson(FAIL_FILE)) == 'object' ? readJson(FAIL_FILE) : {};
	saved[url] = time() + 60;
	ensurePrivateDir(STATE_DIR);
	writeJson(FAIL_FILE, saved);
};

function manifestFiles() {
	const saved = readJson(MANIFEST);
	if (saved?.account != accountName() || type(saved.files) != 'object')
		return {};
	return saved.files;
};

function selfPid() {
	const stat = readfile('/proc/self/stat') ?? '';
	const matched = match(stat, /^([0-9]+) /);
	return matched ? matched[1] : '';
};

function active() {
	const pid = trim(readfile(PID_FILE) ?? '');
	return match(pid, /^[0-9]+$/) != null && access(`/proc/${pid}`);
};

function fetchIcon(url) {
	ensurePrivateDir(STATE_DIR);
	const tag = randomHex(6);
	const confFile = `${STATE_DIR}/icon-${tag}.conf`;
	const bodyFile = `${STATE_DIR}/icon-${tag}.bin`;
	const errFile = `${STATE_DIR}/icon-${tag}.err`;
	const conf = [
		'silent',
		'show-error',
		'fail',
		'globoff',
		'proto = "=https"',
		'proto-redir = "=https"',
		'max-redirs = 5',
		`max-filesize = ${MAX_BYTES}`,
		`url = ${curlquote(url)}`,
		'max-time = 20',
		'connect-timeout = 10',
		`output = "${bodyFile}"`
	];

	writefile(confFile, `${join('\n', conf)}\n`);
	const proc = popen(`curl -q -K ${shellquote(confFile)} 2>${shellquote(errFile)}`);
	if (proc) {
		proc.read('all');
		proc.close();
	}

	const bytes = readfile(bodyFile) ?? '';
	for (let path in [ confFile, bodyFile, errFile ])
		unlink(path);

	if (!length(bytes) || length(bytes) > MAX_BYTES)
		return '';

	const ext = imageExt(bytes);
	if (!length(ext))
		return '';

	const hashFile = `${STATE_DIR}/icon-${tag}.url`;
	writefile(hashFile, url);
	const hash = sha256File(hashFile);
	unlink(hashFile);
	if (!length(hash))
		return '';

	ensureDir(ICON_DIR);
	chmod(ICON_DIR, int('755', 8));
	const name = `${hash}.${ext}`;
	const dest = `${ICON_DIR}/${name}`;
	if (writefile(dest, bytes) == null)
		return '';
	chmod(dest, int('644', 8));
	return name;
};

export function paths(saved) {
	const files = manifestFiles();
	const site = origins().site;
	const out = {};

	for (let name in groupNames(saved)) {
		const url = resolveIcon(saved, name, site);
		const file = files[url];
		if (!iconFileName(file))
			continue;
		if (access(`${ICON_DIR}/${file}`))
			out[name] = `/luci-static/resources/ecycloud/icons/${file}`;
	}

	return out;
};

export function stale() {
	const saved = cached();
	if (type(saved?.config) != 'object')
		return false;

	const files = manifestFiles();
	for (let url in wanted(saved, origins().site)) {
		const file = files[url];
		if (iconFileName(file) && access(`${ICON_DIR}/${file}`))
			continue;
		if (failUntil(url) > time())
			continue;
		return true;
	}

	return false;
};

export function ensure() {
	if (!length(creds().token) || !stale() || active())
		return;
	system('trap "" HUP; /usr/libexec/ecycloud-ctl icons >/dev/null 2>&1 &');
};

export function sync() {
	if (active())
		return;

	const pid = selfPid();
	if (!length(pid))
		return;
	ensurePrivateDir(STATE_DIR);
	writefile(PID_FILE, pid);

	const saved = cached();
	const site = origins().site;
	const files = {};
	const keep = {};

	for (let url in wanted(saved, site)) {
		let file = manifestFiles()[url];
		if (!iconFileName(file) || !access(`${ICON_DIR}/${file}`))
			file = fetchIcon(url);
		if (!length(file)) {
			noteFail(url);
			continue;
		}
		files[url] = file;
		keep[file] = true;
	}

	writePrivateJson(MANIFEST, { account: accountName(), files });

	for (let name in (lsdir(ICON_DIR) ?? [])) {
		if (!iconFileName(name) || keep[name])
			continue;
		unlink(`${ICON_DIR}/${name}`);
	}

	unlink(PID_FILE);
};
