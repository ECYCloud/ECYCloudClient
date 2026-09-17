'use strict';

import { popen, readfile } from 'fs';

import { build, coreRunning, httpRequest, mihomoBin, settings, shellquote,
         userAgent } from 'ecycloud.common';

const APP_REPO = 'ECYCloud/ECYCloudClient';
const NIKKI_FEED = 'https://nikkinikki.pages.dev';
const PRE_PREFIX = 'Pre ';
const RELEASES_URL = `https://github.com/${APP_REPO}/releases`;

function isPre(version) {
	return index(`${version ?? ''}`, PRE_PREFIX) == 0;
};

function parseSemver(version) {
	const raw = isPre(version) ? substr(version, length(PRE_PREFIX)) : `${version ?? ''}`;
	const m = match(raw, /^([0-9]+)\.([0-9]+)\.([0-9]+)$/);
	return m ? [ +m[1], +m[2], +m[3] ] : null;
};

function newer(latest, current) {
	const a = parseSemver(latest);
	const b = parseSemver(current);
	if (!a || !b)
		return false;

	for (let i = 0; i < 3; i++)
		if (a[i] != b[i])
			return a[i] > b[i];

	return false;
};

function outdatedApp(current, latest) {
	if (latest == current)
		return false;
	if (isPre(current) && !isPre(latest))
		return true;
	return newer(latest, current);
};

export function kernelVersion(raw) {
	const m = match(`${raw ?? ''}`, /[0-9]+(\.[0-9]+)+/);
	if (!m)
		return '';
	const n = match(m[0], /^([0-9]+\.[0-9]+\.[0-9]+)/);
	return n ? n[1] : m[0];
};

export function probeKernel() {
	const proc = popen(`${shellquote(mihomoBin())} -v 2>/dev/null`);
	if (!proc)
		return '';

	const text = proc.read('all') ?? '';
	proc.close();
	return kernelVersion(text);
};

function remoteGet(url, headers) {
	const opts = {
		url,
		headers: headers ?? [ `User-Agent: ${userAgent()}` ],
		timeout: 15,
		connectTimeout: 10
	};

	if (coreRunning())
		opts.proxy = `http://127.0.0.1:${settings().mixedPort}`;

	return httpRequest(opts);
};

function githubGet(url) {
	return remoteGet(url, [
		'Accept: application/vnd.github+json',
		`User-Agent: ${userAgent()}`
	]);
};

function parseRelease(entry) {
	if (type(entry) != 'object' || entry.draft == true)
		return null;

	const m = match(`${entry.tag_name ?? ''}`, /^v?([0-9]+\.[0-9]+\.[0-9]+)/);
	if (!m || !length(entry.published_at))
		return null;

	return {
		version: m[1],
		prerelease: entry.prerelease == true,
		published: entry.published_at,
		display: entry.prerelease == true ? `${PRE_PREFIX}${m[1]}` : m[1]
	};
};

function listReleases(repo) {
	const res = githubGet(`https://api.github.com/repos/${repo}/releases?per_page=30`);
	if (res.status != 200)
		return { ok: false, error: `GitHub 返回 HTTP ${res.status || 0}` };
	if (type(res.data) != 'array')
		return { ok: false, error: 'GitHub 返回内容无法解析' };

	const out = [];

	for (let entry in res.data) {
		const rel = parseRelease(entry);
		if (rel)
			push(out, rel);
	}

	if (!length(out))
		return { ok: false, error: 'GitHub 未给出版本号' };

	sort(out, function(a, b) {
		if (a.published == b.published)
			return 0;
		return a.published > b.published ? -1 : 1;
	});

	return { ok: true, releases: out };
};

function newestStable(releases) {
	for (let rel in releases)
		if (!rel.prerelease)
			return rel;
	return null;
};

export function checkApp() {
	const current = build().version ?? '';
	const listed = listReleases(APP_REPO);
	if (!listed.ok)
		return { ok: false, msg: listed.error };

	const target = isPre(current) ? listed.releases[0] : newestStable(listed.releases);
	if (!target)
		return {
			ok: true,
			current,
			latest: current,
			outdated: false,
			releases_url: RELEASES_URL
		};

	return {
		ok: true,
		current,
		latest: target.display,
		outdated: outdatedApp(current, target.display),
		releases_url: RELEASES_URL
	};
};

function releaseField(raw, key) {
	for (let line in split(raw ?? '', '\n')) {
		const item = trim(line);
		if (index(item, `${key}=`) != 0)
			continue;
		const rest = substr(item, length(key) + 1);
		const quoted = match(rest, /^'([^']*)'$/) ?? match(rest, /^"([^"]*)"$/);
		return quoted ? quoted[1] : rest;
	}
	return '';
};

function nikkiFeed() {
	let raw = readfile('/etc/openwrt_release') ?? '';
	let arch = releaseField(raw, 'DISTRIB_ARCH');
	let release = releaseField(raw, 'DISTRIB_RELEASE');

	if (!length(arch) || !length(release)) {
		raw = readfile('/etc/os-release') ?? '';
		if (!length(arch))
			arch = releaseField(raw, 'OPENWRT_ARCH');
		if (!length(release))
			release = releaseField(raw, 'VERSION_ID');
	}

	if (!match(arch, /^[A-Za-z0-9._-]+$/))
		return { ok: false, error: '无法识别本机架构' };

	let branch = '';
	if (match(release, /24\.10/))
		branch = 'openwrt-24.10';
	else if (match(release, /25\.12/))
		branch = 'openwrt-25.12';
	else if (release == 'SNAPSHOT' || match(release, /SNAPSHOT/))
		branch = 'SNAPSHOT';
	else
		return { ok: false, error: `Nikki 源不支持本机 OpenWrt ${release || '?'}` };

	return { ok: true, branch, arch };
};

export function checkKernel(current) {
	const local = kernelVersion(current) || probeKernel();
	const feed = nikkiFeed();
	if (!feed.ok)
		return { ok: false, msg: feed.error, current: local };

	const res = remoteGet(`${NIKKI_FEED}/${feed.branch}/${feed.arch}/nikki/index.json`);
	if (res.status != 200)
		return { ok: false, msg: `Nikki 源返回 HTTP ${res.status || 0}`, current: local };
	if (type(res.data) != 'object' || type(res.data.packages) != 'object')
		return { ok: false, msg: 'Nikki 源返回内容无法解析', current: local };

	const latest = kernelVersion(res.data.packages['mihomo-meta']);
	if (!length(latest))
		return { ok: false, msg: 'Nikki 源未给出 mihomo-meta 版本', current: local };

	return {
		ok: true,
		current: local,
		latest,
		outdated: length(local) > 0 && newer(latest, local)
	};
};
