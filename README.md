# codex-quota-handoff

[中文](#中文) | [English](#english)

---

<h2 id="中文">中文</h2>

**Codex 撞到用量上限被打断 → 等额度窗口刷新 → 自动有人把活接着派给它。你睡觉，它继续。**

一句话概括：**把"额度刷新"这个时刻，变成一次自动接力。**

## 它解决什么问题

Codex（ChatGPT Plus / Pro 订阅）的用量是滚动窗口限流，Plus 是 5 小时一档。长任务跑到一半撞上 `usage_limit_exceeded` 是常态。

麻烦的地方不在于限流本身 —— 而是**窗口刷新之后，没人手去点"继续"**。机器就闲置着，额度白白恢复又白白过期。

这个包做三件事：

1. **定位**：找到被打断的线程、它的额度刷新时刻、以及上次中断的原因
2. **接力**：到点之后，由**外部触发源**把续跑指令重新投喂回那个线程
3. **兜底**：无人值守运行时，把审批、睡眠、重复触发这几个坑全部堵死

## 整体逻辑

```
 ①  额度耗尽                                        ②  窗口刷新
     │                                                  │
     ├─ rollout JSONL 留下痕迹 ─────────────────┐        │
     │    usage_limit_exceeded                   │        │
     │    + resets_at 时间戳（精确到秒）          │        │
     │                                           │        │
     └─ threads 表里能查到线程 ID / cwd / 审批模式 │        │
                                                 │        │
                                                 ▼        ▼
                                       ③  谁来发动？两种方式
                                       ┌──────────────────────────┐
                                       │ A. 系统定时器             │
                                       │    launchd / cron /      │
                                       │    systemd timer         │
                                       │    —— 不需要任何 agent 在场│
                                       ├──────────────────────────┤
                                       │ B. 另一个 agent 来指挥     │
                                       │    Claude Code / WorkBuddy│
                                       │    / Cursor / 你自己的调度 │
                                       │    —— 到点由它执行接力脚本 │
                                       └──────────────────────────┘
                                                 │
                                                 ▼
                                       ④  接力脚本干活
                                       ├─ 等到重置点
                                       ├─ 互斥锁（多触发源只放行一个）
                                       ├─ codex exec resume <线程> <指令>
                                       ├─ --approve-for-me 无人审批
                                       └─ caffeinate 防止跑一半机器睡了
                                                 │
                                                 ▼
                                       ⑤  结果
                                       日志落盘 ~/.codex-handoff/logs/
                                       醒来直接 cat
```

**关键认知**：额度窗口是**账号级**的，跟你在哪个终端、哪个 agent 里调它无关。所以"在窗口刷新后干活"这件事，本质是**一个时间调度问题** —— 谁来卡那个时间点都行。

这也意味着触发源可以完全解耦：**调度交给谁不重要，重要的是那道投喂命令要发得准。**

## 核心原理

### 原理一：Codex 里藏着一个完整的 CLI

大多数人不知道 Codex Desktop 内部有一个功能完整的命令行工具：

```bash
# macOS 上 Codex Desktop 的实际位置
/Applications/ChatGPT.app/Contents/Resources/codex --help

# Linux / 其它安装方式，也可能是别处的二进制，用这条找
ls -la $(dirname $(readlink -f $(which codex)))
```

它支持 `exec`（非交互执行）、`exec resume`（续跑会话）、`queue`（往会话投消息）、
`exec`（编码代理）、`app-server`（守护进程）等子命令。

> ⚠️ **别用 Homebrew 装的那个 `codex`**（`/opt/homebrew/bin/codex`）。它经常是坏的 ——
> 缺 vendor 二进制，一跑就报 `spawn ... ENOENT`。用 app 内部那个。

### 原理二：`exec resume` 能续跑指定线程

```bash
"<codex 二进制路径>" exec \
  --approve-for-me \
  -C "<工作目录>" \
  resume <线程UUID> "<续跑指令>" \
  -m <模型> \
  -c 'model_reasoning_effort="ultra"' \
  -o "<最终回复写入的文件>"
```

**这就是全部的魔法。** 其余一切都是为了让这条命令**在正确的时间、无人值守地跑起来**。

#### ⚠️ 陷阱一：参数顺序是硬约束

**`--approve-for-me` 和 `-C` 必须写在 `resume` 之前。**

它们是 `exec` 级参数（父命令的参数），写在 `resume` 后面会被 clap 直接拒绝：

```
error: unexpected argument '-C' found
  tip: to pass '-C' as a value, use '-- -C'
```

更坑的是：`codex exec resume --help` **根本不会列出** `-C` 和 `--approve-for-me`。
只看子命令的 help 会得出"不支持"的错误结论。

#### ⚠️ 陷阱二：无人值守必须处理审批

线程的审批模式（`threads.approval_mode`）如果是 `on-request`，Codex 遇到敏感操作会**弹按钮等人点**。

人在睡觉 → 没人点 → 任务卡住 → **白占着刚恢复的额度**。

```bash
--approve-for-me
```

它把审批请求转给 Codex 自己的自动复核模型（日志里那批 `codex-auto-review` 线程）。
注意这是**机器复核**，不等于"没有审批"。

| 选项 | 行为 | 适用 |
|---|---|---|
| 不加 | 等人点批准 | 有人盯着 |
| `--approve-for-me` | 转自动复核模型 | **无人值守推荐** |
| `--dangerously-bypass-approvals-and-sandbox` | 跳过一切，连沙箱都关 | 只读任务也没必要 |

#### ⚠️ 陷阱二·关键：线程正被 Codex Desktop 打开时，`exec resume` 必然失败

**这是整件事最容易踩、也最难猜的一个坑。**

只要那个线程在 Codex 界面里是打开的（绝大多数情况都是），**它持有该线程的写锁**，
外部进程抢不到：

```
ERROR codex_core::session::session: failed to initialize thread persistence:
  thread-store conflict: thread <UUID> already has an active writer
Error: thread/resume: thread/resume failed: thread <UUID> already has an active writer (code -32600)
```

这时候正确的工具是 **`queue`** —— 它把消息交给持有线程的 app-server 去执行，不抢锁：

```bash
"<codex binary>" queue --thread <UUID> --message "<续跑指令>"

# 成功输出：
# Queued message 01a09e57-3b79-70a1-90c2-e90afb215c31 for thread 01a09a89-...
```

**取舍**：

| | `exec resume` | `queue` |
|---|---|---|
| 线程被界面打开时 | ✗ 写锁冲突 | ✓ 可用 |
| 能拿到执行输出 | ✓ 完整 | ✗ 只有"已入队" |
| 适合 | 线程已关闭 / 界面没开着 | 线程开着（默认情况）|

因为拿不到输出，用 `queue` 时**验证结果要去读线程自己的 rollout JSONL**
（`~/.codex/sessions/.../rollout-<线程UUID>.jsonl`，看文件是否在增长）。

**所以脚本的正确策略是**：先试 `exec resume`，**一命中 `already has an active writer` 就立刻跳到 `queue`，不要重试** —— 重试一百次结果完全一样，只是白等。

```bash
ACTIVE_WRITER=0
run_once () {
  local out                                    # 注意：必须单独一行
  out=$(caffeinate -i -s "$CODEX" exec --approve-for-me -C "$WORKDIR" \
        resume "$THREAD" "$PROMPT" -m "$MODEL" -o "$LASTMSG" 2>&1)
  local rc=$?
  echo "$out"
  case "$out" in *"already has an active writer"*) ACTIVE_WRITER=1 ;; esac
  return $rc
}
```

> ⚠️ `local out=$(...)` 这种写法会**吃掉退出码**（`$?` 变成 `local` 自己的状态）。
> 必须写成 `local out` 然后另起一行赋值。

**推论**：想让 `exec resume` 这条路可用，得先在 Codex 界面上关掉/归档该线程。

#### ⚠️ 陷阱三：Codex 只认「受信任目录」

```
Not inside a trusted directory and --skip-git-repo-check was not specified.
```

`~/.codex/config.toml` 里必须有：

```toml
[projects."/absolute/path/to/workdir"]
trust_level = "trusted"
```

**接力前先确认线程的 cwd 在白名单里**，否则你会白等一整夜然后发现什么都没发生。

### 原理三：怎么拿到该填的值

#### 线程 UUID 与元数据

```bash
sqlite3 -readonly ~/.codex/state_5.sqlite \
  "select id, name, cwd, approval_mode, model from threads order by updated_at_ms desc limit 20"
```

关键列：`id` / `name`（你在界面上看到的线程标题）/ `cwd` / `approval_mode`。

本仓库的 `scripts/inspect.sh` 把这一步自动化了。

#### 额度窗口刷新时刻

会话记录在：

```
~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl
```

搜 `token_count` 事件，数据结构是 **`payload.rate_limits`**：

```json
{
  "type": "token_count",
  "payload": {
    "rate_limits": {
      "limit_id": "codex",
      "primary":   { "used_percent": 98, "window_minutes": 300,   "resets_at": 1735689600 },
      "secondary": { "used_percent": 31, "window_minutes": 10080, "resets_at": 1736294400 },
      "plan_type": "plus",
      "credits": { "has_credits": false, "balance": "0" }
    }
  }
}
```

- `primary` = **5 小时滚动窗口**（通常就是卡住你的那个）
- `secondary` = 周窗口
- `resets_at` 是 Unix 秒，**用 `datetime.fromtimestamp()` 换算，不要手算**

> ⚠️ **陷阱四**：注意路径是 `payload.rate_limits.primary`，**不是** `payload.primary`。
> 而且每个文件**末尾**那条 `token_count` 通常是 `limit_id: "premium"`、`primary`/`secondary`
> 全是 `null`。所以必须取「**最后一个真正带窗口数据**」的事件，不能无脑取最后一条。

文件末尾还有一条 `task_complete` 事件，带 `codex_error_info: usage_limit_exceeded`，用来确认中断原因。

## 快速开始

```bash
git clone https://github.com/<you>/codex-quota-handoff.git
cd codex-quota-handoff

# 1. 勘察：列出最近线程；给一个 UUID 就看它的额度窗口
./scripts/inspect.sh
./scripts/inspect.sh <线程UUID>

# 2. 写接力指令
mkdir -p ~/.codex-handoff
cp prompt.example.txt ~/.codex-handoff/prompt.txt
$EDITOR ~/.codex-handoff/prompt.txt

# 3. 配好环境变量，先干跑（不会真的调用 Codex）
export CODEX_HANDOFF_THREAD="<线程UUID>"
export CODEX_HANDOFF_WORKDIR="/path/to/thread/cwd"
export CODEX_HANDOFF_RESET_EPOCH=1735689600
export CODEX_HANDOFF_DRY_RUN=1
./scripts/handoff.sh
cat ~/.codex-handoff/logs/handoff-*.log

# 4. 去掉 DRY_RUN，挂触发源（见下）
```

## 触发方式：二选一，或者都挂

### 方式 A：系统定时器（推荐，不需要任何 agent 在场）

`~/.config/systemd/user/`（Linux）或 `~/Library/LaunchAgents/`（macOS）：

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>com.YOURNAME.codex-quota-handoff</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>__HOME__/.codex-handoff/handoff.sh</string>
  </array>
  <!-- 改成你的额度窗口刷新时间之后 1 分钟 -->
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
# macOS
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.YOURNAME.codex-quota-handoff.plist
launchctl print gui/$(id -u)/com.YOURNAME.codex-quota-handoff    # 查下次触发时间
```

**优点**：不依赖任何 app 在前台，最可靠。
**缺点**：需要手动装载一次（某些沙箱环境里 agent 自己做不了这件事）。

### 方式 B：让另一个 agent 来指挥

如果你平时就有别的 agent 常驻（Claude Code / WorkBuddy / Cursor / 自建调度），
可以让它到点执行接力脚本 —— 一句话的提示词就够：

```
到 6:35 执行 bash ~/.codex-handoff/handoff.sh
```

要点是**在提示词里写清幂等语义**，否则 agent 看到"跳过"会以为是失败、反复重试：

```
脚本自带互斥锁和 .attempted / .done 标记。
如果输出里出现「跳过」「已有实例在运行」「本日已尝试过」，
说明另一条触发路径已经或正在执行 —— 这是正常的互斥行为，
不要重试、不要删标记、不要绕过。
```

**优点**：不用碰 launchd / systemd，配好就行。
**缺点**：依赖那个 agent 当时活着，而且会消耗它自己的额度。

> 两种方式**可以同时挂**。脚本里的互斥锁会保证只有一个真正执行，
> 另一个直接退出 —— 不会重复投喂、不会浪费额度。

## 必须解决睡眠，否则定时器根本不准点跑

macOS 睡着时，定时任务**不会执行，只会推迟到唤醒那一刻**。

```bash
pmset -g custom     # sleep 1 表示闲置 1 分钟系统就睡
pmset -g sched      # 看已经排了哪些唤醒闹钟
pmset -g assertions # 看当前谁在阻止睡眠
```

**屏幕息掉不影响后台任务。** 息屏（display sleep）只是显示器断电，
CPU / 磁盘 / 网络照常工作。真正会中断任务的是**系统睡眠**（system sleep）—— 两者不是一回事。

解决办法：

```bash
# 一次性定点唤醒（定在刷新点前 1 分钟）
sudo pmset schedule wake "MM/DD/YYYY HH:MM:SS"

# 另加一个 caffeinate 长挂，在执行窗口前后兜住
nohup caffeinate -i -s -t 18000 >/dev/null 2>&1 &
```

> ⚠️ **`ps` 查不到不等于没跑。** 用 `pmset -g assertions` 确认 caffeinate 的断言真的挂上了。

> ⚠️ **合盖必睡。** 没有外接显示器时，合盖触发的是 clamshell 睡眠，
> `caffeinate` 和任何断言都拦不住。要么别合盖，要么 `sudo pmset -a disablesleep 1`
> （用完记得 `-a disablesleep 0` 恢复）。

## 脚本自带的安全机制

`scripts/handoff.sh` 里这几条是**必须**的，别省：

| 机制 | 作用 |
|---|---|
| 日期守卫 | 比对 `TARGET_DATE`，防止一次性任务变成天天跑 |
| 互斥锁 | `mkdir` 原子获取，多触发源同时点火时只放行一个 |
| `.attempted` 标记 | 真正调用前落盘，失败也不重复投喂同一份指令 |
| `.done` 标记 | 仅在成功时写 |
| 前置检查 | CLI 可执行 / 工作目录存在 / 指令非空，任一不过直接退出 |
| `DRY_RUN` | `CODEX_HANDOFF_DRY_RUN=1` 只打印不执行，方便验证 |
| 重试 + 兜底 | `exec resume` 失败重试一次，仍失败退到 `codex queue` |

## 踩坑记录（都是真金白银换来的）

### 1. bash 会把中文标点吞进变量名

```bash
RC=1
echo "退出码 $RC），重试"      # ✗ RC），: unbound variable
echo "退出码 ${RC}），重试"    # ✓
```

UTF-8 locale 下 bash 把多字节字符当作标识符的一部分，`$RC）` 被解析成变量名 `RC）`。
**中文注释 + 中文输出 + 变量拼接 = 必加花括号。**

```bash
# 扫一遍有没有漏的
grep -nP '(?<!\{)\$[A-Za-z_]\w*(?=[^\x00-\x7F])' your-script.sh
```

### 2. 线程的 cwd 往往不是代码仓库

长任务里，主线程的 cwd 常常是「放文档的目录」，真实代码在完全不同的路径
（尤其是用了多个 `git worktree` 的时候）。

定位办法：在 rollout JSONL 里搜分支名、提交号、或 `git worktree` 的输出，
抠出真实仓库路径，再用 `git -C <repo> worktree list` 核实。

**把核实到的路径写进续跑指令**，能省掉它醒来后瞎找的好几轮。

### 3. 用不存在的 UUID 做全链路探测

想验证参数、信任目录、app-server 都通，但**不想污染真实线程**：

```bash
codex exec --approve-for-me -C "<dir>" resume 00000000-0000-0000-0000-000000000000 "probe"

# 期望输出（说明链路全通）：
# Error: thread/resume: thread/resume failed: no rollout found for thread id 00000000-...
```

**绝对不要用真实线程 ID 做探测** —— 会把指令提前塞进线程，到点又发一次。

### 4. 别只发一句「继续」

长任务上下文会被自动压缩。压缩后再只发一句「继续」，它可能漏掉分工、
或者重做已经做完的部分，白白消耗刚恢复的额度。

续跑指令应该包含：**当前进度 + 剩余分工 + 交付物 + 明确约束**。
写字数的性价比极高。

### 5. 有些环境里 agent 装不了 launchd

某些沙箱化的 agent 运行时（含远程权限边界）执行 `launchctl bootstrap` 会直接报：

```
Bootstrap failed: 5: Input/output error
```

即使用最小合法 plist 做对照测试也一样 —— 说明是进程的权限边界，不是你配置写错了。
**别在这儿反复试**，把命令交给人在终端里跑。

## 关掉它

```bash
launchctl bootout gui/$(id -u) ~/Library/LaunchAgents/com.YOURNAME.codex-quota-handoff.plist
sudo pmset schedule cancel wake "MM/DD/YYYY HH:MM:SS"
rm -rf ~/.codex-handoff
```

## 兼容性与适用范围

- 实测环境：macOS 26.x + Codex Desktop 26.9x（`/Applications/ChatGPT.app`，bundle id `com.openai.codex`）
- 路径、参数名、子命令都随版本变化。升级后先跑一次 `codex exec --help` 和 `codex exec resume --help` 核对
- **这套思路不限于 Codex**：任何「滚动窗口限流 + 有本地 CLI 接口 + 能续跑会话」的组合都适用。
  换掉 `codex exec resume` 那一段，换成目标工具的续跑命令即可，其余（定位、调度、互斥、防睡）完全通用

## License

MIT

---

<h2 id="english">English</h2>

**Codex hits its usage limit mid-task → the quota window refreshes → something automatically hands the work back to it. You sleep, it keeps going.**

In one line: **turn the quota-refresh moment into an automatic handoff.**

## The problem

Codex (ChatGPT Plus / Pro) enforces rolling-window rate limits — 5 hours for Plus.
Long-running tasks hitting `usage_limit_exceeded` halfway through is normal.

The annoying part isn't the limit itself. It's that **after the window refreshes, nobody
is there to press "continue."** The machine just sits idle while the restored quota
slowly burns away.

This package does three things:

1. **Locate** — find the interrupted thread, its quota refresh time, and the reason it stopped
2. **Hand off** — once the window refreshes, an external trigger feeds the continuation
   prompt back into that thread
3. **Harden** — close every gap that kills unattended runs: approvals, sleep, duplicate triggers

## The whole logic

```
 ①  Quota exhausted                                  ②  Window refreshes
     │                                                    │
     ├─ rollout JSONL leaves evidence ───────────┐         │
     │    usage_limit_exceeded                   │         │
     │    + resets_at (Unix seconds, exact)      │         │
     │                                           │         │
     └─ threads table has id / cwd / approval    │         │
                                                 │         │
                                                 ▼         ▼
                                       ③  Who pulls the trigger?
                                       ┌───────────────────────────┐
                                       │ A. OS scheduler           │
                                       │    launchd / cron /       │
                                       │    systemd timer          │
                                       │    — no agent needs to    │
                                       │      be around            │
                                       ├───────────────────────────┤
                                       │ B. Another agent          │
                                       │    Claude Code / WorkBuddy│
                                       │    / Cursor / your own    │
                                       │    — it runs the script   │
                                       └───────────────────────────┘
                                                 │
                                                 ▼
                                       ④  The handoff script
                                       ├─ wait until reset
                                       ├─ mutex (only one trigger wins)
                                       ├─ codex exec resume <thread> <prompt>
                                       ├─ --approve-for-me, no human needed
                                       └─ caffeinate so the box doesn't sleep
                                                 │
                                                 ▼
                                       ⑤  Result
                                       logs in ~/.codex-handoff/logs/
                                       just cat it in the morning
```

**Key insight**: the quota window is **account-level**. It doesn't matter which terminal
or which agent is calling in. So "do the work after the window refreshes" is really just
**a scheduling problem** — whoever can hit that timestamp can drive it.

That also means the trigger is fully decoupled: **it doesn't matter who does the
scheduling; what matters is that the feed command fires at the right second.**

## The three principles

### 1. Codex ships a full CLI

Most people don't know there's a complete command-line tool inside Codex Desktop:

```bash
# macOS
/Applications/ChatGPT.app/Contents/Resources/codex --help

# other installs — find the real binary
ls -la $(dirname $(readlink -f $(which codex)))
```

It supports `exec`, `exec resume`, `queue`, `app-server`, and more.

> ⚠️ **Don't use the Homebrew `codex`** (`/opt/homebrew/bin/codex`). It's frequently broken —
> missing vendor binaries, fails with `spawn ... ENOENT`. Use the one inside the app.

### 2. `exec resume` continues a specific thread

```bash
"<codex binary>" exec \
  --approve-for-me \
  -C "<workdir>" \
  resume <THREAD_UUID> "<continuation prompt>" \
  -m <model> \
  -c 'model_reasoning_effort="ultra"' \
  -o "<file for the final message>"
```

**That's the entire trick.** Everything else exists to make this one command run at the
right time, unattended.

#### ⚠️ Trap 1: argument order is non-negotiable

**`--approve-for-me` and `-C` must come BEFORE `resume`.**

They're `exec`-level (parent command) flags. Place them after `resume` and clap rejects:

```
error: unexpected argument '-C' found
  tip: to pass '-C' as a value, use '-- -C'
```

Worse: `codex exec resume --help` **does not list** `-C` or `--approve-for-me` at all.
Reading only the subcommand help leads you to the wrong conclusion that they're unsupported.

#### ⚠️ Trap 2: approvals will deadlock an unattended run

If the thread's `approval_mode` is `on-request`, Codex pops an approval button for
sensitive operations. Nobody's awake to click it → the run stalls → **you burn the
freshly restored quota on nothing.**

```bash
--approve-for-me
```

This routes approvals to Codex's own auto-review model (those `codex-auto-review` threads
in the logs). Note this is **machine review**, not "no review."

| Option | Behavior | Use when |
|---|---|---|
| (none) | Waits for a human click | Someone is watching |
| `--approve-for-me` | Auto-review model decides | **Recommended unattended** |
| `--dangerously-bypass-approvals-and-sandbox` | Skips everything, no sandbox | Unnecessary even for read-only work |

#### ⚠️ Trap 2b — the big one: `exec resume` CANNOT work while the thread is open in Codex Desktop

**This is the easiest trap to hit and the hardest to guess.**

As long as that thread is open in the Codex UI (which is the normal case),
**it holds a write lock on the thread** and no external process can take over:

```
ERROR codex_core::session::session: failed to initialize thread persistence:
  thread-store conflict: thread <UUID> already has an active writer
Error: thread/resume: thread/resume failed: thread <UUID> already has an active writer (code -32600)
```

The right tool here is **`queue`** — it hands the message to the app-server that
already owns the thread, so there's no lock contention:

```bash
"<codex binary>" queue --thread <UUID> --message "<continuation prompt>"

# success:
# Queued message 01a09e57-3b79-70a1-90c2-e90afb215c31 for thread 01a09a89-...
```

**Trade-off**:

| | `exec resume` | `queue` |
|---|---|---|
| Thread open in the UI | ✗ write-lock conflict | ✓ works |
| Captures execution output | ✓ full | ✗ only "queued" |
| Use when | thread is closed | thread is open (the default) |

Since `queue` gives you no output, **verify by watching the thread's own rollout JSONL**
(`~/.codex/sessions/.../rollout-<thread-uuid>.jsonl`) — check whether the file keeps growing.

**So the correct script strategy is**: try `exec resume` first, and **the moment you see
`already has an active writer`, jump straight to `queue` without retrying** — retrying
produces the identical result, just 60 seconds slower.

```bash
ACTIVE_WRITER=0
run_once () {
  local out                                    # must be on its own line
  out=$(caffeinate -i -s "$CODEX" exec --approve-for-me -C "$WORKDIR" \
        resume "$THREAD" "$PROMPT" -m "$MODEL" -o "$LASTMSG" 2>&1)
  local rc=$?
  echo "$out"
  case "$out" in *"already has an active writer"*) ACTIVE_WRITER=1 ;; esac
  return $rc
}
```

> ⚠️ `local out=$(...)` **swallows the exit code** (`$?` becomes `local`'s own status).
> Write `local out` on one line and assign on the next.

**Corollary**: to make `exec resume` usable, close or archive the thread in the Codex UI first.

#### ⚠️ Trap 3: Codex only runs in "trusted directories"

```
Not inside a trusted directory and --skip-git-repo-check was not specified.
```

`~/.codex/config.toml` needs:

```toml
[projects."/absolute/path/to/workdir"]
trust_level = "trusted"
```

**Verify the thread's cwd is whitelisted before scheduling** — otherwise you wait all
night and nothing happens.

### 3. Where the values come from

#### Thread UUID and metadata

```bash
sqlite3 -readonly ~/.codex/state_5.sqlite \
  "select id, name, cwd, approval_mode, model from threads order by updated_at_ms desc limit 20"
```

`scripts/inspect.sh` automates this.

#### The quota refresh timestamp

Session records live in `~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl`.
Look for `token_count` events — the structure is **`payload.rate_limits`**:

```json
{
  "type": "token_count",
  "payload": {
    "rate_limits": {
      "limit_id": "codex",
      "primary":   { "used_percent": 98, "window_minutes": 300,   "resets_at": 1735689600 },
      "secondary": { "used_percent": 31, "window_minutes": 10080, "resets_at": 1736294400 },
      "plan_type": "plus"
    }
  }
}
```

- `primary` = **5-hour rolling window** (usually what blocks you)
- `secondary` = weekly window
- `resets_at` is Unix seconds — **use `datetime.fromtimestamp()`, don't do the math yourself**

> ⚠️ **Trap 4**: the path is `payload.rate_limits.primary`, **not** `payload.primary`.
> And the *last* `token_count` event in each file is usually `limit_id: "premium"` with
> `primary`/`secondary` set to `null`. Take the **last event that actually carries window
> data**, not simply the last event.

The file also ends with a `task_complete` event carrying
`codex_error_info: usage_limit_exceeded`, which confirms why it stopped.

## Quick start

```bash
git clone https://github.com/<you>/codex-quota-handoff.git
cd codex-quota-handoff

# 1. Recon: list recent threads; pass a UUID to see its quota window
./scripts/inspect.sh
./scripts/inspect.sh <THREAD_UUID>

# 2. Write the handoff prompt
mkdir -p ~/.codex-handoff
cp prompt.example.txt ~/.codex-handoff/prompt.txt
$EDITOR ~/.codex-handoff/prompt.txt

# 3. Configure and dry-run (won't actually call Codex)
export CODEX_HANDOFF_THREAD="<THREAD_UUID>"
export CODEX_HANDOFF_WORKDIR="/path/to/thread/cwd"
export CODEX_HANDOFF_RESET_EPOCH=1735689600
export CODEX_HANDOFF_DRY_RUN=1
./scripts/handoff.sh
cat ~/.codex-handoff/logs/handoff-*.log

# 4. Drop DRY_RUN and attach a trigger (below)
```

## Triggers: pick one, or attach both

### Option A — OS scheduler (recommended; no agent needs to be running)

`~/Library/LaunchAgents/` on macOS, `~/.config/systemd/user/` on Linux.
See `launchd/com.YOURNAME.codex-quota-handoff.plist` for a working template.

```bash
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.YOURNAME.codex-quota-handoff.plist
launchctl print gui/$(id -u)/com.YOURNAME.codex-quota-handoff   # next fire time
```

**Pros**: doesn't depend on any app being in the foreground; most reliable.
**Cons**: needs a one-time manual load (some sandboxed agent runtimes can't do it themselves).

### Option B — Let another agent drive it

If you already keep another agent around (Claude Code / WorkBuddy / Cursor / your own
scheduler), have it run the handoff script at the right time. A one-line prompt is enough:

```
At 6:35 run: bash ~/.codex-handoff/handoff.sh
```

The important part is **spelling out the idempotency semantics** in the prompt, otherwise
the agent sees "skipped" and retries forever:

```
The script has a built-in mutex plus .attempted / .done markers.
If the output says "skipped", "already running", or "already attempted today",
another trigger path has already fired or is running. That is correct mutex behavior —
do NOT retry, do NOT delete the markers, do NOT route around it.
```

**Pros**: no launchd / systemd setup.
**Cons**: depends on that agent being alive, and it spends that agent's own quota.

> You can attach **both**. The mutex guarantees only one actually runs and the other
> exits immediately — no duplicate feeds, no wasted quota.

## Sleep must be handled, or the trigger won't fire on time

On macOS, scheduled jobs **don't run while asleep** — they're deferred until wake.

```bash
pmset -g custom      # "sleep 1" means system sleeps after 1 minute idle
pmset -g sched       # scheduled wake events
pmset -g assertions  # who's currently blocking sleep
```

**Display sleep does not affect background work.** Display sleep just powers down the
panel; CPU / disk / network keep running. Only **system sleep** interrupts tasks — the
two are not the same thing.

```bash
# One-shot scheduled wake (set it 1 minute before the reset)
sudo pmset schedule wake "MM/DD/YYYY HH:MM:SS"

# Plus a long-running caffeinate to cover the execution window
nohup caffeinate -i -s -t 18000 >/dev/null 2>&1 &
```

> ⚠️ **`ps` not showing it doesn't mean it isn't running.** Confirm the assertion with
> `pmset -g assertions`.

> ⚠️ **Closing the lid always sleeps.** With no external display, lid-close triggers
> clamshell sleep — `caffeinate` and any assertion can't stop it. Either leave the lid
> open, or use `sudo pmset -a disablesleep 1` (remember to restore with `-a disablesleep 0`).

## Built-in safety mechanisms

These are **required**, don't strip them:

| Mechanism | Purpose |
|---|---|
| Date guard | Compares `TARGET_DATE` so a one-shot job doesn't run daily |
| Mutex | Atomic `mkdir`; only one trigger wins when several fire together |
| `.attempted` marker | Written before the real call; prevents duplicate feeds even on failure |
| `.done` marker | Written only on success |
| Preflight checks | CLI executable / workdir exists / prompt non-empty — bail immediately otherwise |
| `DRY_RUN` | `CODEX_HANDOFF_DRY_RUN=1` prints without executing |
| Retry + fallback | One retry on `exec resume`, then fall back to `codex queue` |

## Gotchas (all paid for the hard way)

### 1. bash swallows CJK punctuation into variable names

```bash
RC=1
echo "exit $RC), retry"        # fine
echo "退出码 $RC），重试"      # ✗ RC），: unbound variable
echo "退出码 ${RC}），重试"    # ✓
```

Under a UTF-8 locale bash treats multibyte characters as part of the identifier, so
`$RC）` parses as a variable named `RC）`. **CJK text + variable interpolation = always brace it.**

```bash
grep -nP '(?<!\{)\$[A-Za-z_]\w*(?=[^\x00-\x7F])' your-script.sh
```

### 2. A thread's cwd is often NOT the code repo

In long tasks the main thread's cwd is frequently a "docs directory" while the real code
lives elsewhere — especially with multiple `git worktree`s.

Dig through the rollout JSONL for branch names, commit hashes, or `git worktree` output;
then confirm with `git -C <repo> worktree list`.

**Put the verified path in the continuation prompt** — it saves several wasted turns.

### 3. Probe the full chain with a nonexistent UUID

To verify parsing, trust, and the app-server without polluting a real thread:

```bash
codex exec --approve-for-me -C "<dir>" resume 00000000-0000-0000-0000-000000000000 "probe"

# Expected (everything wired correctly):
# Error: thread/resume: thread/resume failed: no rollout found for thread id 00000000-...
```

**Never probe with a real thread ID** — it injects the prompt early, and your scheduled
run sends it again.

### 4. Don't send a bare "continue"

Long-task context gets auto-compacted. After compaction, a bare "continue" may miss the
task breakdown or redo finished work — burning the freshly restored quota.

A good continuation prompt contains: **current progress + remaining breakdown +
deliverable + explicit constraints.** Very high value per character.

### 5. Some agent sandboxes can't load launchd

Sandboxed agent runtimes (with their own permission boundary) may fail with:

```
Bootstrap failed: 5: Input/output error
```

Even a minimal valid plist fails the same way — it's the process's permission boundary,
not your config. **Don't keep retrying**; hand the command to a human terminal.

## Turning it off

```bash
launchctl bootout gui/$(id -u) ~/Library/LaunchAgents/com.YOURNAME.codex-quota-handoff.plist
sudo pmset schedule cancel wake "MM/DD/YYYY HH:MM:SS"
rm -rf ~/.codex-handoff
```

## Scope & compatibility

- Verified on macOS 26.x + Codex Desktop 26.9x (`/Applications/ChatGPT.app`, bundle id `com.openai.codex`)
- Paths, flag names and subcommands change between versions. After an upgrade, re-check
  `codex exec --help` and `codex exec resume --help`
- **The approach is not Codex-specific.** It applies to any tool with rolling-window rate
  limits + a local CLI + session continuation. Swap the `codex exec resume` line for the
  target tool's equivalent; everything else (locating, scheduling, mutex, sleep handling)
  transfers as-is

## License

MIT
