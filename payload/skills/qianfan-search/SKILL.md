---
name: qianfan-search
description: 百度千帆联网搜索（CN 网络友好、结果偏中文源）。需要联网查资料、核实最新事实、找中文网页/新闻/文档时用它——尤其当内置 web_search 不可用、无结果，或用户明确想要百度/中文来源时。触发词：联网搜索、搜索一下、查一下最新、百度一下、搜一下、web search、百度千帆、qianfan。
---

# 百度千帆联网搜索

把千帆联网搜索封装成**可直接执行的 CLI**，让 Agent 能独立联网取回带来源链接的摘要。
**纯标准库**（urllib），不需要 httpx 或任何第三方包。

## 什么时候用

- 需要**联网**获取当前信息：新闻、版本发布、价格、文档、报错解法、最新事实。
- 内置 `web_search` 不可用 / 返回空 / 结果不理想，而用户要的是**中文来源**。
- 需要**可核验的来源 URL**，好让结论能引用。

**不要**用它：
- 纯本地推理、算术、写代码这类不依赖外部事实的任务；
- 已知 URL 要读全文 —— 那用内置 `web_fetch`（本工具只给摘要，不抓正文）。

## 怎么调

```powershell
# 用任意 Python 3：Windows 上通常是 py 或 python；
# 若都不在 PATH，用你（agent）自己探测到的解释器绝对路径 —— DSH 托管运行时里也有一个，例如
#   <DSH_HOME>\dsh-runtimes\*\dependencies\python\python.exe
python "$env:USERPROFILE\.dsh\skills\qianfan-search\scripts\qianfan_search.py" "关键词" [选项]
```

常用选项：

| 选项 | 说明 |
| --- | --- |
| `--top-k N` | 返回条数，默认 6 |
| `--max-chars N` | 正文总长度上限，默认 1200；要更多细节就调大（如 4000） |
| `--recency {day,week,month,year}` | 时效过滤，默认 `year`；查最新动态用 `month` 或 `week` |
| `--json` | 结构化输出（`results[]` 带 title/url/content + `sources[]`），便于程序解析 |
| `--quota` | 只看今日剩余额度，**不消耗**额度 |

示例：

```powershell
$Q = "$env:USERPROFILE\.dsh\skills\qianfan-search\scripts\qianfan_search.py"

# 常规检索
python $Q "DeepSeek Harness 桌面版 发布"

# 要最新 + 更多细节
python $Q "某库 v3 破坏性变更" --recency month --max-chars 4000

# 结构化，交给后续脚本处理
python $Q "关键词" --top-k 10 --json
```

## 输出与引用纪律

文本模式输出形如：

```
[1] 标题
正文摘要……

--- 来源 ---
[1] https://...
（今日剩余额度 93 次）
```

- 引用时**照抄真实 URL**；不要把摘要里的说法当成未验证的事实，也不要在没有来源时编造链接。
- 摘要可能被 `--max-chars` 截断（末尾不完整属正常），需要全文就顺着 URL 用 `web_fetch` 取。
- 若结果为空（退出码 4），可以换个更具体的关键词、放宽 `--recency`，或 `--top-k` 调大后重试一次。

## 与 MCP 原生工具的关系

同一套千帆搜索还有一个 **MCP 服务**版本，注册后模型看到的原生工具名是
**`mcp__qianfan__baidu_search`**（`serverName` = `qianfan`）：

- 服务实现：`skills/qianfan-search/mcp/server.mjs`（零依赖 stdio MCP server）
- 由内核内置的 `dsh-mcp-client` 注册进 `ctx.tools`，**共用同一份 `config.json` 与
  `.quota.json`** —— 两个入口共享同一天额度。
- 若该原生工具可用，**优先用它**（一次调用、参数结构化）；本技能脚本作为**兜底**：
  原生工具不可用、服务没起来、或需要人工手动调参时使用。

## 配置

- API Key 查找顺序：`--key` 参数 → 环境变量 `QIANFAN_API_KEY` → 同目录 `config.json` 的
  `api_key` 字段。
- `config.json` 还支持 `top_k` / `max_chars` / `recency` / `daily_limit` 作为默认值。
- **免费额度 100 次/天**，本工具默认按 95 次自我限制（留 5 次余量），计数持久化在
  `skills/qianfan-search/.quota.json`（跨进程有效，跨天自动归零）。

## 排障

| 现象 | 原因 / 处理 |
| --- | --- |
| `HTTP 401 ... Fail to parse apikey` | Key 无效或已失效 → 换 `config.json` 里的 `api_key` |
| `HTTP 429` 或 `code=...` 额度类报错 | 当天免费额度用尽 → 告知用户明天再试，别反复重试 |
| 退出码 3「今日额度已用完」 | 本地计数到达上限；确认平台端仍有额度时可删 `.quota.json` 重置 |
| `网络不可达` / `请求超时` | 走 CN 网络访问 `qianfan.baidubce.com`；偶发超时可重试一次 |

注意：Key 属敏感信息，只放在 `config.json`（或环境变量），**不要**写进对话、日志或提交到仓库。
