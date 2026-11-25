# AGENTS.md

本文件面向后续接手 `tools` 仓库的 AI Agents 与开发者，说明仓库架构、核心约定、常见改动路径与验证方法。

## 1. 项目概览与部署架构

`tools` 是一个托管在 **Cloudflare Workers（Static Assets + Scheduled Worker）** 上的个人基础设施工具与代理分流规则仓库：

- **自动构建与发布**：GitHub `main` 分支绑定了 Cloudflare Workers Builds。每次推送至 `main` 时，Cloudflare 会自动执行 `wrangler.jsonc` 中的 `build.command`（`python3 sr/build.py`），生成静态规则产物并发布到全球边缘节点。
- **每日定时闭环**：`wrangler.jsonc` 配置了 Cron Trigger（`0 0 * * *`，即每日北京时间 `08:00`）。`worker.js` 的 `scheduled()` 会向环境变量 `DEPLOY_HOOK_URL` 发送 `POST` 请求触发重构建，自动拉取最新上游 GFWList 与广告规则。
- **请求路由模型**：`run_worker_first` 保持默认关闭。已存在的静态文件（`index.html`、`/fq/*`、`/sr/*.conf`）由 Cloudflare 静态资源层直接响应（受 `_headers` 控制响应头，不消耗 Worker 调用额度）；未命中的路径落入 `worker.js` 的 `fetch()` 返回 `404 Not Found`。

---

## 2. 目录结构与职责

```text
tools/
├── index.html                  # 工具与规则导航页（自动适配当前访问域名，提供复制与 shadowrocket:// 一键导入）
├── _headers                    # 静态资源 HTTP 响应头配置（.sh / .pac / .conf 强制 UTF-8 text/plain inline）
├── .assetsignore               # 部署上传黑名单（防止内部脚本、规则源文件、AGENTS.md 等暴露到公网）
├── wrangler.jsonc              # Cloudflare Worker 配置（build.command + assets + cron trigger）
├── worker.js                   # 404 兜底与每日定时触发 Deploy Hook
├── rules/                      # 跨客户端（sing-box + fq.sh + Shadowrocket）共用的域名单一事实来源
│   ├── proxy_google_cn.txt     # Google CN 及关联静态域名（客户端走代理，服务端在 CN 阻断前放行）
│   ├── proxy_apple.txt         # Apple AI / Private Relay / Podcasts 域名（客户端走代理，无需写服务端）
│   ├── proxy_tiger_brokers.txt # 老虎证券域名（客户端走代理，服务端在 CN 阻断前放行）
│   └── direct_cn_extra.txt     # 国内补充直连域名（跨 sing-box 客户端与 Shadowrocket 共用）
├── fq/                         # VPS 自动化部署脚本与客户端配置模板
│   ├── fq.sh                   # Debian/Ubuntu 服务端一键部署与运维菜单（DNS/证书续期/WARP/Nginx/sing-box/Xray）
│   ├── setup-home.sh           # Debian/Ubuntu/macOS 常用终端环境（Vim/Tmux/Shell）初始化脚本
│   ├── sing-box-mac-client.json# macOS sing-box（1.14+ 规范）脱敏配置模板
│   ├── sing-box-server.json    # 服务端 sing-box（1.14+ 规范）脱敏配置模板
│   ├── mask_singbox.py         # 将真实 sing-box 配置脱敏为 TODO_REPLACE_THIS 的辅助脚本
│   └── tsproxy.pac             # PAC 代理分流文件
└── sr/                         # Shadowrocket 规则构建器（原 Shadowrocket-ADBlock-Rules-Forever 重构合并）
    ├── build.py                # 零第三方依赖（纯 Python 3 标准库）跨端同步与规则生成脚本
    ├── templates/              # Shadowrocket 公共头尾模板（head.conf / foot.conf）
    └── rules/                  # Shadowrocket 专属手工规则与白名单
        ├── direct.txt          # 手工直连域名/网段
        ├── proxy.txt           # 手工代理域名/关键词/网段
        ├── reject.txt          # 手工最高优先级拦截域名/网段
        ├── ad_ignore.txt       # 上游 AdBlock 误杀豁免白名单（精确域名及其子域名不拦截）
        ├── gfw_extra.txt       # GFWList 补充代理项（仅用于 sr_gfw* 黑名单变体）
        └── gfw_exclude.txt     # 从上游 GFWList 剔除的误判域名（如 apple.com）
```

---

## 3. 核心开发规范与不变量（必读）

### 3.1 跨客户端共享域名同步机制
- `rules/proxy_google_cn.txt`、`rules/proxy_apple.txt`、`rules/proxy_tiger_brokers.txt`、`rules/direct_cn_extra.txt` 是**唯一事实来源**。
- 修改 `rules/*.txt` 后，**必须运行 `python3 sr/build.py --sync-only`**，脚本会自动把列表同步写入以下三处：
  1. `fq/sing-box-mac-client.json` 的 `dns.rules`（`google-dns`）与 `route.rules`（`direct` / `ai` / `proxy`）域名后缀规则（2 空格缩进）
  2. `fq/sing-box-server.json` 的 `domain_suffix` 放行白名单（仅同步 `proxy_google_cn.txt` 与 `proxy_tiger_brokers.txt`，4 空格缩进）
  3. `fq/fq.sh` 内嵌服务端配置模板中的两段 `domain_suffix` 放行白名单
- **切勿**只手动编辑 `sing-box-*.json` 或 `fq.sh` 里的上述共享域名数组而不改 `rules/*.txt`，否则下次运行 `sr/build.py` 会被覆盖回退。

### 3.2 Shadowrocket 规则优先级与去重逻辑
- **生成的 `.conf` 文件绝不入库**：`sr/sr_{cnip_ad,cnip,cnip_ad_ts,cnip_ts,gfw_ad,gfw}.conf` 已配置在 `.gitignore` 中，仅在本地测试或云端部署阶段动态生成。其中 `*_ts.conf` 专为启用内置 Tailscale 模块场景定制（从 `bypass-tun` / `skip-proxy` 精确剥离 `100.64.0.0/10`、`fc00::/7` 与家庭子网 `10.0.0.0/24`，并在规则中指向 `TAILSCALE` 策略）。
- **手工规则零冲突检查**：`direct`、`proxy`、`reject` 合并共享列表后若存在完全相同的条目，`sr/build.py` 会直接抛错中止构建。
- **规则匹配顺序**：
  1. `reject.txt`（手工 `REJECT`）
  2. 上游 AdBlock 列表（仅 `*_ad*.conf` 含此段，受 `ad_ignore.txt` 保护并自动裁剪已被父后缀覆盖的冗余子域名）
  3. Tailscale 域名规则（仅 `*_ts.conf`：`ts.net` 走 `TAILSCALE`，`tailscale.com` / `tailscale.io` 走 `DIRECT`）
  4. 手工与共享路由规则（`DOMAIN-SUFFIX` 按**域名层级从多到少**排序，确保如 `cn.bing.com,DIRECT` 排在 `bing.com,PROXY` 之前、`guzzoni.apple.com,PROXY` 排在 `apple.com,DIRECT` 之前；随后输出 `DOMAIN-KEYWORD` 与规范化后的 `IP-CIDR`）
  5. Tailscale 网段规则（仅 `*_ts.conf`：`10.0.0.0/24`、`100.64.0.0/10`、`fd7a:115c:a1e0::/48` 走 `TAILSCALE`）
  6. `DOMAIN-SUFFIX,cn,DIRECT` + `GEOIP,CN,DIRECT`（仅 `sr_cnip*`）及局域网保留网段 `DIRECT`
  7. `FINAL,PROXY`（`sr_cnip*`）或 `FINAL,DIRECT`（`sr_gfw*`）
- **广告豁免**：若新增某个代理/直连域名同时存在于上游 EasyList 广告源中（例如 `googleadservices.com`、`googletagmanager.com`、`t.co`），需同步加入 `sr/rules/ad_ignore.txt`，否则在 `*_ad.conf` 中会被上游广告段优先 `REJECT`。

### 3.3 构建脚本零外部依赖约束
- `sr/build.py` 直接运行在 Cloudflare Workers 构建容器与本地 macOS（系统自带 Python 3.9+）中，**禁止引入 `requests` 等任何需要 `pip install` 的第三方包**，保持纯 Python 3 标准库实现。

### 3.4 敏感信息脱敏与公网暴露控制
- **脱敏红线**：仓库公开且直接托管静态文件，`fq/sing-box-*.json` 等配置中严禁出现真实服务器 IP、域名、UUID、Reality 公私钥、`short_id`、Clash API `secret`。从真实配置更新模板时，务必通过 `python3 fq/mask_singbox.py` 脱敏为 `TODO_REPLACE_THIS`。
- **`.assetsignore` 维护**：因为 `wrangler.jsonc` 的 `assets.directory` 指向根目录 `.`，任何仅供开发/构建使用的脚本、源文件目录或 Markdown 文档都必须列入 `.assetsignore`，避免被发布为公开 URL；如需公开新的文件卡片，同步更新 `index.html` 与 `_headers`。
- **`fq.sh` 执行方式**：`fq.sh` 内部通过 `BASH_SOURCE[0]` 获取脚本落盘路径并写入 `/etc/cron.d/fq-cert-renew` 定时续期任务，因此 `index.html` 中的安装命令需保持 `curl -fsSLO .../fq/fq.sh && bash fq.sh`（先落盘再执行），不要改成管道 `| bash`。

---

## 4. 常用命令与提交前自检清单

修改代码或规则后，按需执行以下检查：

```bash
# 1. 将 rules/*.txt 同步至 sing-box 配置与 fq.sh（离线秒级完成）
python3 sr/build.py --sync-only

# 2. 校验跨端共享域名是否完全同步
python3 sr/build.py --check-sync

# 3. 全量拉取上游源并构建 6 份 Shadowrocket .conf（需联网，耗时约 2~3 秒）
python3 sr/build.py

# 4. 校验 Shell、JSON 与 Worker JS 语法
bash -n fq/fq.sh && bash -n fq/setup-home.sh
python3 -m json.tool fq/sing-box-mac-client.json >/dev/null && python3 -m json.tool fq/sing-box-server.json >/dev/null
node --check worker.js
```
