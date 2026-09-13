# codex-quota-window-resume

**让 Codex 在额度窗口重置后自己接着干活 —— 你睡觉，它继续。**

Codex（ChatGPT Plus/Pro 订阅）的用量是滚动窗口限流，Plus 是 5 小时窗口。长任务跑到一半撞上 `usage_limit_exceeded` 是常事。这个包解决的问题是：**不等你手动回来点"继续"，窗口一重置就自动把任务续上。**

已实测可用（macOS，Codex Desktop 26.9x）。

---

## 它到底怎么工作

```
 额度耗尽                          窗口重置                    自动续跑
    │                                 │                          │
    ├── rollout JSONL 里留下 ──────────┤                          │
    │   usage_limit_exceeded           │                          │
    │   + resets_at 时间戳             │                          │
    │                                  │                          │
    │                        launchd 定时在重置点后 1 分钟 ────────┤
    │                        （或任何你习惯的定时器）              │
    │                                  │                          │
    │                                  │        codex exec resume ┤──► 往原线程
    │                                  │          --approve-for-me│    投喂续跑指令
    │                                  │                          │
    │                        pmset 定点唤醒解决"机器睡着了" ───────┘
    │
    └── 日志写到 ~/.codex-resume/logs/run-*.log
```

核心只有一条命令，其余都是为了让这条命令**在凌晨 6 点准点、"无人值守"地跑起来**。

---

## 核心机密：Codex 自带续跑接口

大多数人不知道 Codex Desktop 里藏着一个完整的 CLI。

```bash
# 注意：不是 brew 装的那个（那个往往是坏的），是 app 内部的
/Applications/ChatGPT.app/Contents/Resources/codex --help
```

它有一个 `exec resume` 子命令，可以直接续跑**指定线程**：

```bash
"/Applications/ChatGPT.app/Contents/Resources/codex" exec \
  --approve-for-me \
  -C "<工作目录>" \
  resume <线程UUID> "继续执行未完成的任务" \
  -m gpt-5.6-sol \
  -o "<最终回复写入的文件>"
```

### ⚠️ 参数顺序是硬约束

**`--approve-for-me` 和 `-C` 必须写在 `resume` 之前。**

它们是 `exec` 级参数，写在 `resume` 后面会直接报错：

```
error: unexpected argument '-C' found
```

而 `codex exec resume --help` 里**根本不会列出** `-C` 和 `--approve-for-me` —— 很容易误判成"不支持"。实际上它们能用，只是必须前置。

### ⚠️ 无人值守必须加 `--approve-for-me`

线程的审批模式如果是 `on-request`，Codex 遇到敏感操作会弹按钮等人点。凌晨没人点，任务就卡在那儿**白占着新窗口的额度**。

`--approve-for-me` 把审批请求转给 Codex 自己的自动复核模型（就是日志里那批 `codex-auto-review` 线程）。注意这是**机器复核**，不等于"没有审批"。

> 更彻底的是 `--dangerously-bypass-approvals-and-sandbox`，但它连沙箱一起关掉，Codex 可以随便改你的文件系统。只读任务没必要。

---

## 怎么找到该填的值

### 线程 UUID

线程元数据在 `~/.codex/state_5.sqlite` 的 `threads` 表：

```bash
sqlite3 -readonly ~/.codex/state_5.sqlite \
  "select id, name, cwd, approval_mode from threads order by updated_at_ms desc limit 20"
```

关键列：`id` / `name`（你看到的线程标题）/ `cwd` / `approval_mode`。

本仓库的 `scripts/inspect.sh` 把这步自动化了。

### 额度窗口重置时间

在会话记录里找：

```bash
~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl
```

搜 `token_count` 事件，结构长这样：

```json
{
  "limit_id": "codex",
  "primary":   { "used_percent": 98, "window_minutes": 300,   "resets_at": 1735689600 },
  "secondary": { "used_percent": 31, "window_minutes": 10080, "resets_at": 1736294400 },
  "plan_type": "plus"
}
```

- `primary` = 5 小时滚动窗口（就是卡住你的那个）
- `secondary` = 周窗口
- `resets_at` 是 Unix 秒，**换算成本地时间再填进配置**

文件末尾通常还有一条 `task_complete` 事件，带 `codex_error_info: usage_limit_exceeded`，能确认中断原因。

---

## 快速开始

```bash
git clone https://github.com/<you>/codex-quota-window-resume.git
cd codex-quota-window-resume

# 1. 勘察：列出最近线程 + 各自的额度窗口
./scripts/inspect.sh

# 2. 写续跑指令
mkdir -p ~/.codex-resume
cp message.example.txt ~/.codex-resume/message.txt
$EDITOR ~/.codex-resume/message.txt

# 3. 配置并干跑（不会真的调用 Codex）
export CODEX_THREAD="<线程UUID>"
export CODEX_WORKDIR="/path/to/your/project"
export CODEX_RESUME_RESET_EPOCH=1735689600
export CODEX_RESUME_DRY_RUN=1
./scripts/run-resume.sh
cat ~/.codex-resume/logs/run-*.log

# 4. 去掉 DRY_RUN，挂定时任务（见下）
```

---

## 挂定时任务

### 主路径：launchd

`~/Library/LaunchAgents/com.<you>.codex-resume.plist`：

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>com.YOURNAME.codex-resume</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>__HOME__/.codex-resume/run-resume.sh</string>
  </array>
  <key>StartCalendarInterval</key>
  <dict><key>Hour</key><integer>6</integer><key>Minute</key><integer>35</integer></dict>
  <key>RunAtLoad</key><false/>
  <key>EnvironmentVariables</key>
  <dict>
    <key>HOME</key><string>__HOME__</string>
    <key>PATH</key><string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin</string>
  </dict>
</dict>
</plist>
```

```bash
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.YOURNAME.codex-resume.plist
launchctl print gui/$(id -u)/com.YOURNAME.codex-resume   # 查下次触发时间
```

### 必须解决睡眠：否则定时任务根本不会准点跑

macOS 睡着时定时任务**不会执行，只会推迟到唤醒那一刻**。查一下：

```bash
pmset -g custom          # sleep 1 就表示闲置 1 分钟系统就睡
pmset -g sched           # 看已经排了哪些唤醒闹钟
```

两条一起上：

```bash
# 一次性定点唤醒（定在重置点前 1 分钟）
sudo pmset schedule wake "MM/DD/YYYY HH:MM:SS"

# 另加一个 caffeinate 长挂，在任务执行窗口前后兜住
caffeinate -i -s -t 18000 &
```

**注意 `ps` 查不到不等于没跑** —— 用 `pmset -g assertions` 确认 caffeinate 的断言是否真的挂上了。

> 💡 **屏幕息掉不影响后台任务。** 息屏（display sleep）只是显示器断电，CPU / 磁盘 / 网络照常工作。真正会中断任务的是**系统睡眠**（system sleep），两者不是一回事。

> 💡 **合盖必睡。** 没有外接显示器时，合盖触发的是 clamshell 睡眠，`caffeinate` 和任何断言都拦不住。要么别合盖，要么用 `sudo pmset -a disablesleep 1`（用完记得 `-a disablesleep 0` 恢复）。

---

## 脚本自带的安全机制

`scripts/run-resume.sh` 里这几条是**必须**的，别省：

| 机制 | 作用 |
|---|---|
| 日期守卫 | 比对 `TARGET_DATE`，防止一次性任务变成天天跑 |
| 互斥锁 | `mkdir` 原子获取，多触发源同时点火时只放行一个 |
| `.attempted` 标记 | 真正调用前落盘，失败也不重复投喂同一份指令 |
| `.done` 标记 | 仅在成功时写，配 `--one-shot` 语义 |
| 前置检查 | CLI 可执行 / 工作目录存在 / 指令非空，任一不过直接退出 |
| DRY_RUN | `CODEX_RESUME_DRY_RUN=1` 只打印不执行，方便验证 |
| 重试 + 兜底 | `exec resume` 失败重试一次，仍失败退到 `codex queue` |

---

## 踩坑记录（都是真金白银换来的）

### 1. bash 会把中文标点吞进变量名

```bash
RC=1
echo "退出码 $RC），重试"      # ✗ RC），: unbound variable
echo "退出码 ${RC}），重试"    # ✓
```

UTF-8 locale 下 bash 把多字节字符当作标识符的一部分，`$RC）` 被解析成变量名 `RC）`。
**中文注释 + 中文输出 + 变量拼接 = 必加花括号。**

扫一遍有没有漏的：

```bash
grep -nP '(?<!\{)\$[A-Za-z_]\w*(?=[^\x00-\x7F])' your-script.sh
```

### 2. Codex 只认「受信任目录」

```
Not inside a trusted directory and --skip-git-repo-check was not specified.
```

`~/.codex/config.toml` 里必须有：

```toml
[projects."/absolute/path/to/workdir"]
trust_level = "trusted"
```

**续跑前先确认线程 cwd 在白名单里**，否则白等一整夜。

### 3. 线程的 cwd 往往不是代码仓库

长任务里，主线程的 cwd 常常是「放文档的目录」，真实代码在完全不同的路径（尤其是用了多个 `git worktree` 的时候）。

定位办法：在 rollout JSONL 里搜分支名、提交号、或 `git worktree` 的输出，抠出真实仓库路径，再用 `git -C <repo> worktree list` 核实。

**把核实到的路径写进续跑指令**，能省掉它醒来后瞎找的好几轮。

### 4. 用不存在的 UUID 做全链路探测

想验证参数、信任目录、app-server 都通，但**不想污染真实线程**：

```bash
codex exec --approve-for-me -C "<dir>" resume 00000000-0000-0000-0000-000000000000 "probe"

# 期望输出（说明链路全通）：
# Error: thread/resume: thread/resume failed: no rollout found for thread id 00000000-...
```

**绝对不要用真实线程 ID 做探测** —— 会把指令提前塞进线程，到点又发一次。

### 5. 只发「继续」很容易跑偏

长任务上下文会被自动压缩。压缩之后再只发一句「继续」，它可能漏掉分工、或者重做已经做完的部分。

续跑指令应该包含：**当前进度 + 剩余分工 + 交付物 + 明确约束**。写字数的性价比极高。

---

## 关掉它

```bash
launchctl bootout gui/$(id -u) ~/Library/LaunchAgents/com.YOURNAME.codex-resume.plist
sudo pmset schedule cancel wake "MM/DD/YYYY HH:MM:SS"
rm -rf ~/.codex-resume
```

---

## 兼容性备注

- 实测于 macOS 26.x + Codex Desktop 26.9x（`/Applications/ChatGPT.app`，bundle id `com.openai.codex`）
- **Homebrew 的 `codex` 常常是坏的**（缺 vendor 二进制，报 `spawn ... ENOENT`），别用它
- 路径、参数名、子命令都随版本变化，升级后先跑 `codex exec --help` 和 `codex exec resume --help` 核对一遍
- 这套思路对任何"滚动窗口限流 + 有本地 CLI 接口"的组合都适用，不限于 Codex

## License

MIT
