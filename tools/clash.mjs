#!/usr/bin/env node
/**
 * clash.mjs — Clash Verge (mihomo) 控制工具
 *
 * Clash Verge 关闭了 TCP 版 external-controller（verge.yaml: enable_external_controller=false），
 * 内核 only 监听 Windows 命名管道（named pipe）。本工具用 Node 直连命名管道发 HTTP 请求，
 * 因此不依赖 9097 端口、也不需要 secret。
 *
 * 用法:
 *   node clash.mjs status                 当前模式/端口/系统代理/各组当前选择
 *   node clash.mjs groups                 列出所有 selector/urltest 组
 *   node clash.mjs nodes <group>          列出组内节点及延迟
 *   node clash.mjs use <group> <node|idx> 切换节点（idx 从 nodes 输出里取）
 *   node clash.mjs best <group>           延迟测速后切到最快节点
 *   node clash.mjs mode <rule|global|direct>
 *   node clash.mjs delay <group>          只测延迟，不切换
 *   node clash.mjs api <path>             裸调 API，例如 /configs
 *   node clash.mjs env                    输出可直接粘贴的环境变量
 */
import net from 'node:net';
import fs from 'node:fs';
import path from 'node:path';

const APP_DIR = path.join(process.env.APPDATA || '', 'io.github.clash-verge-rev.clash-verge-rev');
const CONFIG = path.join(APP_DIR, 'config.yaml');

/** 从 config.yaml 里取出 pipe 名的 hash 后缀，再拼上真实的 role 前缀 */
function resolvePipeName() {
  if (process.env.CLASH_PIPE) return process.env.CLASH_PIPE;
  let hash = '';
  try {
    const raw = fs.readFileSync(CONFIG, 'utf8');
    const m = raw.match(/external-controller-pipe:\s*.*?verge-mihomo-[\w-]*?-([0-9a-f]{16,})/);
    if (m) hash = m[1];
  } catch { /* ignore */ }
  if (!hash) throw new Error(`无法从 ${CONFIG} 解析 external-controller-pipe`);
  return `verge-mihomo-production-${hash}`;
}

function request(pipeName, method, apiPath, body) {
  return new Promise((resolve, reject) => {
    const sock = net.connect({ path: `\\\\.\\pipe\\${pipeName}` });
    let buf = Buffer.alloc(0);
    const timer = setTimeout(() => { sock.destroy(); reject(new Error('pipe 请求超时')); }, 15000);
    sock.on('connect', () => {
      const head = [`${method} ${apiPath} HTTP/1.1`, 'Host: localhost', 'Connection: close'];
      if (body) {
        head.push('Content-Type: application/json', `Content-Length: ${Buffer.byteLength(body)}`);
        sock.write(head.join('\r\n') + '\r\n\r\n' + body);
      } else {
        sock.write(head.join('\r\n') + '\r\n\r\n');
      }
    });
    sock.on('data', (d) => { buf = Buffer.concat([buf, d]); });
    sock.on('error', (e) => { clearTimeout(timer); reject(e); });
    sock.on('end', () => {
      clearTimeout(timer);
      try { resolve(parseResponse(buf)); } catch (e) { reject(e); }
    });
  });
}

function parseResponse(buf) {
  const sep = buf.indexOf('\r\n\r\n');
  if (sep < 0) throw new Error('响应格式异常');
  const head = buf.subarray(0, sep).toString('latin1').split('\r\n');
  const status = Number(head[0].split(' ')[1]);
  const headers = {};
  for (const line of head.slice(1)) {
    const i = line.indexOf(':');
    if (i > 0) headers[line.slice(0, i).trim().toLowerCase()] = line.slice(i + 1).trim();
  }
  let bodyBuf = buf.subarray(sep + 4);
  if ((headers['transfer-encoding'] || '').includes('chunked')) bodyBuf = dechunk(bodyBuf);
  const text = bodyBuf.toString('utf8');
  let json;
  try { json = text ? JSON.parse(text) : null; } catch { json = text; }
  return { status, json, text };
}

function dechunk(buf) {
  const parts = [];
  let off = 0;
  while (off < buf.length) {
    const nl = buf.indexOf('\r\n', off);
    if (nl < 0) break;
    const size = parseInt(buf.subarray(off, nl).toString('latin1').trim(), 16);
    if (!size || Number.isNaN(size)) break;
    const start = nl + 2;
    parts.push(buf.subarray(start, start + size));
    off = start + size + 2;
  }
  return Buffer.concat(parts);
}

const GROUPS = new Set(['Selector', 'URLTest', 'Fallback', 'LoadBalance', 'Relay']);

async function getProxies() {
  const r = await request(resolvePipeName(), 'GET', '/proxies');
  return r.json.proxies;
}

function groupNames(proxies) {
  return Object.entries(proxies)
    .filter(([, v]) => GROUPS.has(v.type))
    .map(([k, v]) => ({ name: k, type: v.type, now: v.now, count: (v.all || []).length }))
    .filter((g) => g.name !== 'GLOBAL');
}

function fmt(x) { return typeof x === 'string' ? x : JSON.stringify(x); }

async function fmtDelay(proxies, group, name) {
  const d = proxies[name]?.history?.slice(-1)[0];
  return d && d.delay > 0 ? `${d.delay}ms` : (d ? 'fail' : '—');
}

const [cmd, a1, a2] = process.argv.slice(2);

try {
  switch (cmd) {
    case 'status': {
      const pipe = resolvePipeName();
      const cfg = (await request(pipe, 'GET', '/configs')).json;
      const proxies = await getProxies();
      const sys = process.env.SYSTEM_PROXY_INFO || '';
      console.log('内核版本 :', (await request(pipe, 'GET', '/version')).json.version);
      console.log('命名管道 :', pipe);
      console.log('运行模式 :', cfg.mode, '| mixed-port:', cfg['mixed-port'], '| tun:', cfg.tun?.enable);
      console.log('系统代理 : 见 netcheck.ps1（HKCU\\...\\Internet Settings）');
      console.log('选择器组 :');
      for (const g of groupNames(proxies)) {
        console.log(`  ${g.name.padEnd(14)} [${g.type}] → ${g.now}   (${g.count} 个候选)`);
      }
      break;
    }
    case 'groups': {
      const proxies = await getProxies();
      for (const g of groupNames(proxies)) console.log(`${g.name}\t${g.type}\t${g.now}\t${g.count}`);
      break;
    }
    case 'nodes': {
      const proxies = await getProxies();
      const g = proxies[a1];
      if (!g) throw new Error(`没有名为 ${a1} 的组`);
      g.all.forEach((n, i) => {
        const d = proxies[n]?.history?.slice(-1)[0];
        console.log(`${String(i).padStart(3)}  ${n.padEnd(28)} ${d && d.delay > 0 ? d.delay + 'ms' : (d ? 'fail' : '未测试')}`);
      });
      console.log('---\n当前:', g.now ?? '(url-test 自动)');
      break;
    }
    case 'use': {
      const proxies = await getProxies();
      const g = proxies[a1];
      if (!g) throw new Error(`没有名为 ${a1} 的组`);
      let target = a2;
      if (/^\d+$/.test(target) && g.all[Number(target)] !== undefined) target = g.all[Number(target)];
      if (!g.all.includes(target)) throw new Error(`组 ${a1} 里没有 ${target}`);
      await request(resolvePipeName(), 'PUT', `/proxies/${encodeURIComponent(a1)}`, JSON.stringify({ name: target }));
      console.log(`已切换 ${a1} → ${target}`);
      break;
    }
    case 'best': {
      const proxies = await getProxies();
      const g = proxies[a1];
      if (!g) throw new Error(`没有名为 ${a1} 的组`);
      const targets = g.all.filter((n) => n !== 'DIRECT' && n !== 'REJECT' && proxies[n]?.type !== 'Selector');
      const results = await Promise.all(targets.map(async (n) => {
        const url = encodeURIComponent('https://www.gstatic.com/generate_204');
        const r = await request(resolvePipeName(), 'GET',
          `/proxies/${encodeURIComponent(n)}/delay?url=${url}&timeout=5000`);
        return { n, delay: typeof r.json.delay === 'number' ? r.json.delay : Infinity };
      }));
      results.sort((x, y) => x.delay - y.delay);
      if (!results.length || !isFinite(results[0].delay)) throw new Error('所有节点测速均失败');
      await request(resolvePipeName(), 'PUT', `/proxies/${encodeURIComponent(a1)}`,
        JSON.stringify({ name: results[0].n }));
      console.log(`最快节点 → ${results[0].n} (${results[0].delay}ms)`);
      console.log('其次:', results.slice(1, 5).map((r) => `${r.n}=${isFinite(r.delay) ? r.delay + 'ms' : 'fail'}`).join(', '));
      break;
    }
    case 'delay': {
      const proxies = await getProxies();
      const g = proxies[a1];
      if (!g) throw new Error(`没有名为 ${a1} 的组`);
      const url = encodeURIComponent('https://www.gstatic.com/generate_204');
      const rs = await Promise.all(g.all.map(async (n) => {
        const r = await request(resolvePipeName(), 'GET',
          `/proxies/${encodeURIComponent(n)}/delay?url=${url}&timeout=5000`).catch(() => ({ json: {} }));
        return { n, d: typeof r.json.delay === 'number' ? r.json.delay : Infinity };
      }));
      rs.sort((x, y) => x.d - y.d).forEach((r) => console.log(`${isFinite(r.d) ? String(r.d).padStart(5) + 'ms' : '  fail'}  ${r.n}`));
      break;
    }
    case 'mode': {
      if (!['rule', 'global', 'direct'].includes(a1)) throw new Error('mode 只能是 rule/global/direct');
      await request(resolvePipeName(), 'PATCH', '/configs', JSON.stringify({ mode: a1 }));
      console.log('模式已切换为', a1);
      break;
    }
    case 'api': {
      const r = await request(resolvePipeName(), 'GET', a1);
      console.log(r.text);
      break;
    }
    case 'env': {
      const port = 7897;
      console.log(`$env:HTTP_PROXY='http://127.0.0.1:${port}'`);
      console.log(`$env:HTTPS_PROXY='http://127.0.0.1:${port}'`);
      console.log(`$env:ALL_PROXY='http://127.0.0.1:${port}'`);
      console.log(`$env:NO_PROXY='localhost,127.0.0.1,::1'`);
      console.log(`# bash/mac: export HTTPS_PROXY=http://127.0.0.1:${port}`);
      console.log(`# socks5:  127.0.0.1:${port} (mixed 端口同时支持 socks5) 或 socks://127.0.0.1:7898`);
      break;
    }
    default:
      console.log(fs.readFileSync(new URL(import.meta.url), 'utf8').split('*/')[0].replace(/^\/\*\*?/, ''));
  }
} catch (e) {
  console.error('✗', e.message);
  process.exit(1);
}
