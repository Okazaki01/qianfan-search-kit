# 百度千帆联网搜索 · DSH 安装包（qianfan-search kit）

把**百度千帆（qianfan）联网搜索**接进 DeepSeek Harness，提供**两种入口**：

| 入口 | 形态 | 公开名 | 用途 |
| --- | --- | --- | --- |
| **MCP 原生工具** | 内核 `dsh-mcp-client` 注册进 `ctx.tools` | `mcp__qianfan__baidu_search` | **主用**：模型一次调用，参数结构化 |
| **技能脚本** | `~/.dsh/skills/qianfan-search/`（SKILL.md + CLI） | 由 agent 读技能后执行 | **兜底**：MCP 不可用、或人工手动调参 |

两者**共用同一份配置与额度计数**（`config.json` / `.quota.json`）。

---

## ⭐ 推荐安装法：交给你的 AI agent（零折腾）

**你不需要手敲任何命令。**

1. 把这个压缩包（或本仓库地址）**丢给你的 AI agent** —— DSH、Claude Code、Cursor 等任何能读文件、能跑命令的 agent 都行。
2. 跟它说一句：

   > **把这个 qianfan-search kit 装上，需要 Key 就问我。**

3. agent 会自己完成整条链路：

   - ✅ 解包、探测 `DSH_HOME`、找出**所有** profile、自动挑一个可用的 Node
   - ✅ **主动问你要百度千帆的 API Key**（没申请过？它会把申请路径告诉你）
   - ✅ 把 Key 只写进本地 `config.json`（**不外显、不进仓库、不写日志**）
   - ✅ 给每个 profile 的 `cordis.patch.yml` 追加托管块（**改前自动备份**，幂等可重复）
   - ✅ 跑一遍 MCP 协议自检（**不消耗搜索额度**）
   - ✅ 告诉你：**重启 DeepSeek Harness → 开新对话** → 直接说"搜一下 xxx"验收

4. 你只需做两件事：**重启** + **开个新对话**。之后模型会自己用 `mcp__qianfan__baidu_search`。

> **为什么推荐这条路**：安装要处理「DSH_HOME 在哪 / 有几个 profile / 用哪个 Node / Windows 路径怎么转义 / YAML 别写坏」这些琐碎坑，agent 会自己探测并验证，你只要给它 Key。

### agent 的操作手册

本仓库的 **[`INSTALL-FOR-AGENT.md`](./INSTALL-FOR-AGENT.md)** 就是写给 agent 的完整手册（开头第一件事就是「向用户要 API Key」，含手动步骤、验证方法与排障表）。
如果你用的 agent 没主动读它，把这句话发给它：

> **读 INSTALL-FOR-AGENT.md，按里面的步骤把这个 kit 装上；需要 API Key 就问我。**

---

## 手动安装（不想用 agent 时）

```powershell
# 在本目录下执行（会自动探测 DSH_HOME、Node、所有 profile）
powershell -ExecutionPolicy Bypass -File .\install.ps1

# 顺便把 API Key 写进配置
powershell -ExecutionPolicy Bypass -File .\install.ps1 -Key "<你的千帆-API-Key>"

# 只装到指定 profile
powershell -ExecutionPolicy Bypass -File .\install.ps1 -Profiles web-desktop
```

安装器会做完这些事（**幂等，可重复运行**）：

1. 复制技能目录到 `<DSH_HOME>/skills/qianfan-search/`
2. 准备 `config.json`（**已存在则原样保留，密钥不会被动**）
3. 给每个 profile 的 `cordis.patch.yml` 追加一段**带标记的托管块**（改动前自动备份为 `*.bak-qianfan-<时间戳>`）
4. 跑一遍 MCP 协议自检（`verify.mjs`，不消耗搜索额度）

## 装完必做

> **重启 DeepSeek Harness**，然后**开一个新对话**。
> 接线在启动时读取；技能要新对话才会出现在 agent 的技能列表里。

## API Key

- **申请**：百度智能云千帆控制台 → 「API Key 管理」→ 新建（免费额度 **100 次/天**）
- **优先级**：`-Key` 参数 / 环境变量 `QIANFAN_API_KEY` / `config.json` 的 `api_key` 字段
- 本工具默认按 **95 次/天**自我限制（留 5 次余量），计数写在 `skills/qianfan-search/.quota.json`
- ⚠️ **本压缩包不含任何密钥**，可以放心分享。自己重装时用 `-Key` 传入，或把 key 填进
  `<DSH_HOME>/skills/qianfan-search/config.json`

## 卸载 / 回退

```powershell
powershell -ExecutionPolicy Bypass -File .\install.ps1 -Uninstall              # 只摘掉接线，保留技能
powershell -ExecutionPolicy Bypass -File .\install.ps1 -Uninstall -RemoveSkill  # 连技能目录一起删
```

## 目录结构

```
qianfan-search-kit/
├── README.md                ← 你正在看的（给人）
├── INSTALL-FOR-AGENT.md     ← 给 AI agent 的操作手册（含手动安装步骤与排障）
├── kit.json                 ← 版本、内容清单、SHA256、已验证环境
├── install.ps1              ← 一键安装/卸载（PowerShell 5.1+ 均可）
├── verify.mjs               ← 零依赖 MCP 协议自检
└── payload/skills/qianfan-search/
    ├── SKILL.md                    技能说明（agent 靠它判断何时用）
    ├── config.example.json         配置模板（不含密钥）
    ├── scripts/qianfan_search.py   命令行工具（纯标准库）
    └── mcp/server.mjs              零依赖 stdio MCP server
```

## 为什么这样设计（给维护者）

- **走 MCP 而不是写内核插件**：MCP 服务是**独立进程**，与内核版本**完全解耦**（没有任何
  `@deepseek-ai/*` peer 依赖），内核升级不用跟；而且内核的 `dsh-mcp-client` 配置里
  `failOnStartupError` 默认 `false` —— **服务起不来也不会拖累宿主启动**。
- **技能 + MCP 双入口**：原生工具高效，脚本入口永不失效（MCP 挂了还能手动跑）。
- **零依赖**：MCP server 只用 Node 标准库；Python 脚本只用标准库 → 不需要 pnpm/npm 安装任何东西。
- **优先让 agent 装**：这类"改别人机器上的配置文件"的活，人在键盘前试错的成本远高于 agent 探测 + 自检的成本。
