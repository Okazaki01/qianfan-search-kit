# 给 AI Agent 的安装手册：qianfan-search（百度千帆联网搜索）

> 你是被要求"把这个包装上"的 agent。按下面的步骤做即可；**每一步都可验证、可回退**。
> 目标：把百度千帆搜索接成 DSH 的原生 MCP 工具 `mcp__qianfan__baidu_search`，
> 并保留一个技能脚本入口作为兜底。

## ⚠️ 开始之前：向用户要 API Key（不要跳过）

**动手之前先问用户拿 Key**，并把下面这张小卡片一起发给他（省得他到处找）：

> 请把**百度千帆的 API Key** 发我（形如 `bce-v3/ALTAK-…` 或一串 32+ 位字符）。
> 还没申请？到**百度智能云千帆控制台 → 「API Key 管理」→ 新建**，免费额度 **100 次/天**。
> 或者你自己来：把 Key 填进 `<DSH_HOME>/skills/qianfan-search/config.json` 的 `api_key` 字段，
> 然后回我一句「填好了」——我就跳过 Key 参数继续装。

拿到 Key 后按下面做；**若用户说"填好了"**，下面的命令里去掉 `-Key` 即可（已存在的 `config.json` 密钥不会被覆盖）。

**纪律（必须遵守）**：

- Key **只允许**落到 `<DSH_HOME>/skills/qianfan-search/config.json`（或由用户设为环境变量 `QIANFAN_API_KEY`）。
- **不要**把 Key 回显在对话里、写进日志、写进 `kit.json` / `README.md` / 任何会被提交到仓库的文件。
- 装完后不要再复述 Key；用户问起就说是"已写入本地配置"。

## 0. 最快路径（先试这个）

```powershell
powershell -ExecutionPolicy Bypass -File <本目录>\install.ps1 -Key "<千帆 API Key>"
```

- 不传 `-Key` 也行：若目标机器已有 `config.json`，密钥会被保留；否则需要事后补填。
- 脚本**幂等**，可重复运行；会在改动前把每个 profile 补丁备份成 `*.bak-qianfan-<时间戳>`。
- 脚本结束时会自动跑一次协议自检。看到 `自检通过 ✅` 即为成功。
- 如果脚本报错或环境特殊（DSH_HOME 非默认、profile 名不同、多运行时），走下面的**手动步骤**。

关键参数：

| 参数 | 作用 |
| --- | --- |
| `-DshHome <路径>` | 指定 DSH_HOME（默认取 `$env:DSH_HOME`，否则 `~/.dsh`） |
| `-Key <KEY>` | 写入 / 更新 `config.json` 的 `api_key` |
| `-NodePath <node.exe>` | MCP 服务用哪个 Node（默认自动探测 DSH 托管运行时） |
| `-Profiles a,b` | 只接线到指定 profile（默认遍历 `<DSH_HOME>/profiles/*/cordis.patch.yml`） |
| `-SkipVerify` | 跳过自检 |
| `-Uninstall [-RemoveSkill]` | 卸载接线 / 连技能目录一起删 |

## 1. 手动安装（脚本不可用时）

### 1.1 放技能目录

把 `payload/skills/qianfan-search/` 整个复制到：

```
<DSH_HOME>/skills/qianfan-search/
```

最终应有 4 个文件：`SKILL.md`、`config.example.json`、`scripts/qianfan_search.py`、`mcp/server.mjs`。
（`SKILL.md` 必须是**大写**文件名、目录名与 frontmatter 的 `name` 一致。）

### 1.2 造 config.json

把 `config.example.json` 复制成 `config.json`，填入真实密钥（也可以改用环境变量
`QIANFAN_API_KEY`，那样就不必写文件）：

```json
{ "api_key": "<你的千帆 API Key>", "top_k": 6, "max_chars": 1200, "recency": "year", "daily_limit": 95 }
```

### 1.3 接线到 profile

给**每个** `<DSH_HOME>/profiles/<profile>/cordis.patch.yml` **追加**下面这段
（把三个路径换成真实绝对路径；文件里是顶层 YAML 数组，所以直接追加一个列表项即可）：

```yaml
# >>> qianfan-search MCP（本块由 install.ps1 管理，请勿手动编辑内部）>>>
- insert:
    - id: mcp-qianfan
      name: '@deepseek-ai/dsh-mcp-client'
      config:
        transport: stdio
        serverName: qianfan
        command: '<node.exe 的绝对路径>'
        args:
          - '<...>/skills/qianfan-search/mcp/server.mjs'
        cwd: '<...>/skills/qianfan-search'
        toolCallTimeoutMs: 60000
# <<< qianfan-search MCP <<<
```

**必须准确的点**（照抄，别改字段名）：

- `name` 固定为 `@deepseek-ai/dsh-mcp-client`（内核自带，无需安装）
- `transport: stdio`、`serverName: qianfan`
- **Windows 路径一律用单引号包住**（YAML 单引号里反斜杠是字面量，不会被转义）
- `serverName` 必须匹配内核的 `/^[A-Za-z0-9_-]{1,32}$/`
- **不要**为了"稳妥"去动 `failOnStartupError`：它默认 `false`，即服务启动失败不会拖累宿主

## 2. 验证（装完必做）

```powershell
# A) 协议自检：握手 + tools/list + 错误路径（不联网、不耗额度）
node <本目录>\verify.mjs --server "<DSH_HOME>\skills\qianfan-search\mcp\server.mjs"
node <本目录>\verify.mjs --server "<...>\server.mjs" --call "今天的新闻"   # 追加真实搜索，消耗 1 次额度
```

期望：`结果：通过 N 项，失败 0 项` / `自检通过 ✅`。退出码 0。

```powershell
# B) 接线是否写对（用真 YAML 解析器，别用肉眼看）
node -e "const Y=require('<某个可用的 yaml 包>'),fs=require('fs');for(const f of process.argv.slice(1)){const d=Y.parse(fs.readFileSync(f,'utf8'));const rows=[];for(const e of d){if(e&&Array.isArray(e.insert))rows.push(...e.insert);else if(e&&e.id)rows.push(e)};console.log(f,'顶层',d.length,'mcp行',rows.filter(r=>r.name==='@deepseek-ai/dsh-mcp-client').length)}" "<profile1>\cordis.patch.yml" "<profile2>\cordis.patch.yml"
```

期望：每个文件 `mcp行 1`。同时确认 `command` 与 `args[0]` 指向的文件**真实存在**。

**C) 最终验收（需要人配合或等下次启动）**

- 重启 DeepSeek Harness；在**设置 →「Skills 与 MCP」**里应能看到名为 `qianfan` 的服务
- 开**新对话**，让 agent 查一个中文近况 → 它应调用 `mcp__qianfan__baidu_search`

## 3. 排障（都是实测踩过的坑）

| 现象 | 原因 / 处理 |
| --- | --- |
| PowerShell 报**语法错误**、中文变乱码（如 `缂哄け`） | 脚本被当成 ANSI/GBK 读了。**`.ps1` 必须存成带 UTF-8 BOM**。修法：`[System.IO.File]::WriteAllText($p,[System.IO.File]::ReadAllText($p,[Text.Encoding]::UTF8),(New-Object Text.UTF8Encoding($true)))` |
| 报 `无法将"pwsh"项识别为...` | 目标机器只有 Windows PowerShell 5.1。用 `powershell -ExecutionPolicy Bypass -File ...`，或直接 `& .\install.ps1` |
| 装完重启后工具**没出现** | ① 该 app 启动时可能**重写了它的 profile 补丁**（官方桌面端会这么做，但实测会保留未知内容）→ 检查托管块还在不在，不在就用设置页「Skills 与 MCP」再加一条（字段同上）；② 没重启；③ profile 名不对 |
| 报 `MCP error -32602: 未知工具` | `tools/call` 的 `name` 写错了。工具名是 **`baidu_search`**（服务端原始名），模型看到的公开名才是 `mcp__qianfan__baidu_search` |
| 搜索报 `HTTP 401 / Fail to parse apikey` | 密钥无效 → 换 `config.json` 的 `api_key` 或环境变量 |
| 搜到一半说额度用完 | 免费额度 100/天，本工具默认自限 95。确认平台端仍有额度时可删 `.quota.json` 重置本地计数 |
| 想换 Node | 官方端自带 `resources/runtime/primary-runtime/dependencies/node/bin/node.exe`；EAC 桌面自带 `vendor/node/node.exe`；DSH 托管在 `<DSH_HOME>/dsh-runtimes/*/dependencies/node/bin/node.exe`。三者任一均可，写绝对路径即可 |
| 工具名太丑 / 想改名 | 改 `serverName`（如 `qianfan`→`qf`）即可，公开名随之变成 `mcp__qf__baidu_search`。注意它同时是同一个 Agent 内的命名空间，别和别的 MCP 服务重名 |
| 想确认没装坏别的东西 | `node <本目录>\verify.mjs` 只测这个服务；整体健康看 app 是否能正常开新会话 |

## 4. 回退

```powershell
powershell -ExecutionPolicy Bypass -File <本目录>\install.ps1 -Uninstall               # 摘接线，留技能
powershell -ExecutionPolicy Bypass -File <本目录>\install.ps1 -Uninstall -RemoveSkill  # 全删
```

手动回退等价于：删掉 `cordis.patch.yml` 里 `# >>> qianfan-search MCP` 到
`# <<< qianfan-search MCP <<<` 之间的整段；需要的话再删 `<DSH_HOME>/skills/qianfan-search/`。
（`*.bak-qianfan-*` 备份文件可以直接删，DSH 不会读它们。）

## 5. 事实清单（改代码前先读，别猜）

| 事实 | 值 | 出处 |
| --- | --- | --- |
| MCP 客户端插件 | `@deepseek-ai/dsh-mcp-client`（内核自带） | 实测：官方端 0.2.0-rc.2 与 EAC 桌面 0.1.2-alpha.1 **配置字段完全一致** |
| 描述 | "MCP client bridge: connects to MCP servers and registers their tools on `ctx.tools`" | 包内 package.json |
| 传输方式 | `stdio`（command/args/env/cwd）与 `streamable-http`（url/headers） | 插件源码 `createTransport()` |
| stdio 配置字段 | `transport` / `serverName`(必填,`/^[A-Za-z0-9_-]{1,32}$/`) / `command`(必填) / `args` / `env` / `cwd` / `toolCallTimeoutMs` / `failOnStartupError`(默认 **false**) / `reconnect` | 插件 Zod schema |
| 公开工具名规则 | `mcp__<serverName>__<rawName>`（必要时加哈希后缀） | 插件 `publicToolName()` |
| 服务端协议 | JSON-RPC 2.0 over stdio，**每行一条消息**；stdout 只能出 JSON，日志走 stderr | MCP 规范；本包 `server.mjs` 依此实现 |
| 已实测的协议版本 | 客户端请求 `2025-06-18` 可正常握手（服务端回显客户端请求的版本以最大化兼容） | 用真实 `@modelcontextprotocol/sdk` v1.30.0 客户端验证通过 |
| 千帆接口 | `POST https://qianfan.baidubce.com/v2/ai_search/web_search`，`Authorization: Bearer <KEY>` | 本包实现；免费额度 100 次/天 |
