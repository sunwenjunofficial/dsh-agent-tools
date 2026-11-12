#!/usr/bin/env node
/**
 * clash.mjs — Clash Verge (mihomo) 控制工具
 *
 * 设计要点（都是踩坑换来的）：
 *  1. Clash Verge 关闭了 TCP 版 external-controller（verge.yaml enable_external_controller=false），
 *     内核只监听 Windows 命名管道，所以这里用 Node 直连 \\.\pipe\ 发 HTTP 请求，不需要端口和 secret。
 *  2. 管道名不要写死：每次运行扫描 \\.\pipe\ 里所有 verge-mihomo-* 并挑 production 那个，
 *     Verge 升级/重装/改路径后 hash 变了也能自动找到。
 *  3. 端口也不要写死：优先问内核 /configs 的 mixed-port，其次读 verge.yaml，最后才用 7897。
 *  4. 内核没起来就自动拉起 clash-verge.exe 并轮询等待（--no-start 可关闭）。
 *
 * 用法:
 *   node clash.mjs status                 当前模式/端口/各组当前选择
 *   node clash.mjs port                   只输出端口号（脚本调用用）
 *   node clash.mjs start                  确保 Clash 在跑，输出结果
 *   node clash.mjs groups                 列出所有 selector/urltest 组
 *   node clash.mjs nodes <group>          列出组内节点及延迟
 *   node clash.mjs use <group> <node|idx> 切换节点
 *   node clash.mjs best <group>           测速后切到最快节点
 *   node clash.mjs delay <group>          只测延迟
 *   node clash.mjs mode <rule|global|direct>
 *   node clash.mjs api <path>             裸调 API，例如 /configs
 *   node clash.mjs env                    输出可直接粘贴的环境变量
 *
 * 全局开关: --no-start   任何命令都不自动启动 Clash
 */
import net from 'node:net';
import fs from 'node:fs';
import path from 'node:path';
import { spawn } from 'node:child_process';

const APP_DIR = path.join(process.env.APPDATA || '', 'io.github.clash-verge-rev.clash-verge-rev');
const VERGE_YAML = path.join(APP_DIR, 'verge.yaml');
const VERGE_EXE = 'C:\\Program Files\\Clash Verge\\clash-verge.exe';
const DEFAULT_PORT = 7897;
const NO_START = process.argv.includes('--no-start');

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

// ---------------------------------------------------------------- pipe 发现

function listPipes() {
  try {
    return fs.readdirSync('\\\\.\\pipe\\').filter((n) => /^verge-mihomo-/.test(n));
  } catch {
    return [];
  }
}

function findPipe() {
  const all = listPipes();
  if (!all.length) return null;
  return all.find((n) => n.includes('production')) || all[0];
}

// ------------------------------------------------------------ HTTP over pipe

function request(pipeName, method, apiPath, body, timeoutMs = 8000) {
  return new Promise((resolve, reject) => {
    const sock = net.connect({ path: `\\\\.\\pipe\\${pipeName}` });
    let buf = Buffer.alloc(0);
    const timer = setTimeout(() => { sock.destroy(); reject(new Error('pipe 请求超时')); }, timeoutMs);
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
  if (status >= 400) throw new Error(`API ${status}: ${text.slice(0, 200)}`);
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

// ---------------------------------------------------------------- 自动拉起

function startVerge() {
  if (process.platform !== 'win32') throw new Error('只支持 Windows');
  if (!fs.existsSync(VERGE_EXE)) throw new Error(`找不到 ${VERGE_EXE}`);
  const child = spawn(VERGE_EXE, [], { detached: true, stdio: 'ignore', windowsHide: false });
  child.unref();
}

async function pipeAlive(pipe) {
  try { await request(pipe, 'GET', '/version', null, 3000); return true; } catch { return false; }
}

async function ensureCore({ quiet = false } = {}) {
  let pipe = findPipe();
  if (pipe && await pipeAlive(pipe)) return pipe;

  if (NO_START) throw new Error('内核没在跑，且指定了 --no-start');

  if (!quiet) console.error('[..] 内核未响应，正在启动 Clash Verge ...');
  startVerge();
  for (let i = 0; i < 60; i++) {
    await sleep(500);
    pipe = findPipe();
    if (pipe && await pipeAlive(pipe)) {
      if (!quiet) console.error(`[ok] 内核就绪（${(i + 1) * 0.5}s）`);
      return pipe;
    }
  }
  throw new Error(
    '启动后 30 秒内核仍未响应。若是 Clash Verge 界面已经开着、只是内核被手动「停止」了，' +
    '我无法远程点界面按钮——请在界面里点「启动内核」后重跑；否则检查订阅是否过期。'
  );
}

async function getPort(pipe) {
  if (pipe) {
    try {
      const cfg = (await request(pipe, 'GET', '/configs')).json;
      if (cfg['mixed-port'] > 0) return cfg['mixed-port'];
    } catch { /* fall through */ }
  }
  try {
    const m = fs.readFileSync(VERGE_YAML, 'utf8').match(/^verge_mixed_port:\s*(\d+)/m);
    if (m) return Number(m[1]);
  } catch { /* ignore */ }
  return DEFAULT_PORT;
}

// ------------------------------------------------------------------ 业务

const GROUPS = new Set(['Selector', 'URLTest', 'Fallback', 'LoadBalance', 'Relay']);

async function getProxies(pipe) {
  return (await request(pipe, 'GET', '/proxies')).json.proxies;
}

function groupNames(proxies) {
  return Object.entries(proxies)
    .filter(([, v]) => GROUPS.has(v.type))
    .map(([k, v]) => ({ name: k, type: v.type, now: v.now, count: (v.all || []).length }))
    .filter((g) => g.name !== 'GLOBAL');
}

const [cmd, a1, a2] = process.argv.slice(2).filter((a) => a !== '--no-start');

try {
  switch (cmd) {
    case 'port': {
      const pipe = findPipe();
      console.log(await getPort(pipe));
      break;
    }
    case 'start': {
      const pipe = await ensureCore();
      console.log(`[ok] 内核在跑：${pipe}`);
      console.log(`[ok] 端口：${await getPort(pipe)}`);
      break;
    }
    case 'status': {
      const pipe = await ensureCore({ quiet: true });
      const cfg = (await request(pipe, 'GET', '/configs')).json;
      const proxies = await getProxies(pipe);
      console.log('内核版本 :', (await request(pipe, 'GET', '/version')).json.version);
      console.log('命名管道 :', pipe);
      console.log('运行模式 :', cfg.mode, '| mixed-port:', cfg['mixed-port'], '| tun:', cfg.tun?.enable);
      console.log('选择器组 :');
      for (const g of groupNames(proxies)) {
        console.log(`  ${g.name.padEnd(14)} [${g.type}] → ${g.now}   (${g.count} 个候选)`);
      }
      break;
    }
    case 'groups': {
      const pipe = await ensureCore({ quiet: true });
      const proxies = await getProxies(pipe);
      for (const g of groupNames(proxies)) console.log(`${g.name}\t${g.type}\t${g.now}\t${g.count}`);
      break;
    }
    case 'nodes': {
      const pipe = await ensureCore({ quiet: true });
      const proxies = await getProxies(pipe);
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
      const pipe = await ensureCore({ quiet: true });
      const proxies = await getProxies(pipe);
      const g = proxies[a1];
      if (!g) throw new Error(`没有名为 ${a1} 的组`);
      let target = a2;
      if (/^\d+$/.test(target) && g.all[Number(target)] !== undefined) target = g.all[Number(target)];
      if (!g.all.includes(target)) throw new Error(`组 ${a1} 里没有 ${target}`);
      await request(pipe, 'PUT', `/proxies/${encodeURIComponent(a1)}`, JSON.stringify({ name: target }));
      console.log(`已切换 ${a1} → ${target}`);
      break;
    }
    case 'best': {
      const pipe = await ensureCore({ quiet: true });
      const proxies = await getProxies(pipe);
      const g = proxies[a1];
      if (!g) throw new Error(`没有名为 ${a1} 的组`);
      const targets = g.all.filter((n) => n !== 'DIRECT' && n !== 'REJECT' && proxies[n]?.type !== 'Selector');
      const url = encodeURIComponent('https://www.gstatic.com/generate_204');
      const results = await Promise.all(targets.map(async (n) => {
        try {
          const r = await request(pipe, 'GET', `/proxies/${encodeURIComponent(n)}/delay?url=${url}&timeout=5000`);
          return { n, delay: typeof r.json.delay === 'number' ? r.json.delay : Infinity };
        } catch { return { n, delay: Infinity }; }
      }));
      results.sort((x, y) => x.delay - y.delay);
      if (!results.length || !isFinite(results[0].delay)) throw new Error('所有节点测速均失败（订阅可能过期/流量用尽）');
      await request(pipe, 'PUT', `/proxies/${encodeURIComponent(a1)}`, JSON.stringify({ name: results[0].n }));
      console.log(`最快节点 → ${results[0].n} (${results[0].delay}ms)`);
      console.log('其次:', results.slice(1, 5).map((r) => `${r.n}=${isFinite(r.delay) ? r.delay + 'ms' : 'fail'}`).join(', '));
      break;
    }
    case 'delay': {
      const pipe = await ensureCore({ quiet: true });
      const proxies = await getProxies(pipe);
      const g = proxies[a1];
      if (!g) throw new Error(`没有名为 ${a1} 的组`);
      const url = encodeURIComponent('https://www.gstatic.com/generate_204');
      const rs = await Promise.all(g.all.map(async (n) => {
        try {
          const r = await request(pipe, 'GET', `/proxies/${encodeURIComponent(n)}/delay?url=${url}&timeout=5000`);
          return { n, d: typeof r.json.delay === 'number' ? r.json.delay : Infinity };
        } catch { return { n, d: Infinity }; }
      }));
      rs.sort((x, y) => x.d - y.d).forEach((r) => console.log(`${isFinite(r.d) ? String(r.d).padStart(5) + 'ms' : '  fail'}  ${r.n}`));
      break;
    }
    case 'mode': {
      if (!['rule', 'global', 'direct'].includes(a1)) throw new Error('mode 只能是 rule/global/direct');
      const pipe = await ensureCore({ quiet: true });
      await request(pipe, 'PATCH', '/configs', JSON.stringify({ mode: a1 }));
      console.log('模式已切换为', a1);
      break;
    }
    case 'api': {
      const pipe = await ensureCore({ quiet: true });
      console.log((await request(pipe, 'GET', a1)).text);
      break;
    }
    case 'env': {
      const port = await getPort(findPipe());
      console.log(`$env:HTTP_PROXY='http://127.0.0.1:${port}'`);
      console.log(`$env:HTTPS_PROXY='http://127.0.0.1:${port}'`);
      console.log(`$env:ALL_PROXY='http://127.0.0.1:${port}'`);
      console.log(`$env:NO_PROXY='localhost,127.0.0.1,::1'`);
      console.log(`$env:NODE_USE_ENV_PROXY='1'   # Node fetch 必须`);
      break;
    }
    default:
      console.log('用法: node clash.mjs <status|port|start|groups|nodes|use|best|delay|mode|api|env> [参数] [--no-start]');
  }
} catch (e) {
  console.error('✗', e.message);
  process.exit(1);
}
