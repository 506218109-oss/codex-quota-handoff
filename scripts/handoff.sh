#!/bin/bash
# ---------------------------------------------------------------------------
# codex-quota-handoff —— 额度窗口接力
#
# Codex 撞到用量上限被打断后，在窗口刷新的那一刻自动把续跑指令投喂回原线程。
# 无人值守。触发源可以是系统定时器，也可以是另一个 agent。
#
# 用法：
#   export CODEX_HANDOFF_THREAD="<线程UUID>"
#   export CODEX_HANDOFF_WORKDIR="/path/to/thread/cwd"
#   export CODEX_HANDOFF_RESET_EPOCH=1735689600    # 窗口刷新的 Unix 秒
#   export CODEX_HANDOFF_DRY_RUN=1                 # 先干跑验证
#   ./handoff.sh
#
# 完整说明见 README.md
# ---------------------------------------------------------------------------

set -uo pipefail

# =========================== 配置 ===========================

# Codex 的 CLI 二进制。默认取 Codex Desktop 内置那个。
# 注意：不要用 brew 装的那个（往往是坏的）。
CODEX="${CODEX_BIN:-/Applications/ChatGPT.app/Contents/Resources/codex}"

# 要接力的线程 UUID。必填。
THREAD="${CODEX_HANDOFF_THREAD:-}"

# 线程的工作目录（= threads 表里的 cwd）。也是 Codex 的受信任目录。
WORKDIR="${CODEX_HANDOFF_WORKDIR:-$HOME}"

# 可选：真实代码仓库路径。只用于日志里多看一眼，不影响投喂。
CODE_REPO="${CODEX_HANDOFF_CODE_REPO:-}"

# 模型与推理档位
MODEL="${CODEX_HANDOFF_MODEL:-gpt-5.6-sol}"
EFFORT="${CODEX_HANDOFF_EFFORT:-ultra}"

# 运行目录（日志、指令、标记都放这儿）
BASE="${CODEX_HANDOFF_BASE:-$HOME/.codex-handoff}"
PROMPTFILE="${CODEX_HANDOFF_PROMPT:-$BASE/prompt.txt}"

# 一次性守卫：默认只对「今天」生效
TARGET_DATE="${CODEX_HANDOFF_DATE:-$(date +%F)}"

# 额度窗口刷新的 Unix 秒。必填（留 0 会立刻执行）。
RESET_EPOCH="${CODEX_HANDOFF_RESET_EPOCH:-0}"

# 刷新点之后再多等几秒，避开边界抖动
GRACE="${CODEX_HANDOFF_GRACE:-25}"

# 1 = 只打印将要执行的命令，不真跑
DRY_RUN="${CODEX_HANDOFF_DRY_RUN:-0}"

# 重试间隔（秒）
RETRY_WAIT="${CODEX_HANDOFF_RETRY_WAIT:-60}"

DONE_MARKER="$BASE/.done-$TARGET_DATE"
ATTEMPT_MARKER="$BASE/.attempted-$TARGET_DATE"
LOCKDIR="$BASE/.lock"

export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

# =========================== 日志 ===========================
mkdir -p "$BASE/logs" || exit 1
STAMP=$(date +%Y%m%d-%H%M%S)
LOG="$BASE/logs/handoff-$STAMP.log"
LASTMSG="$BASE/logs/last-message-$STAMP.txt"
exec >>"$LOG" 2>&1

echo "=================================================="
echo "codex-quota-handoff"
echo "启动时间 : $(date '+%Y-%m-%d %H:%M:%S')"
echo "日志文件 : $LOG"

# =========================== 参数校验 ===========================
FAIL=0
[ -n "$THREAD" ]  || { echo "FAIL: 未设置 CODEX_HANDOFF_THREAD（线程 UUID）"; FAIL=1; }
[ "$RESET_EPOCH" -gt 0 ] 2>/dev/null || { echo "FAIL: 未设置 CODEX_HANDOFF_RESET_EPOCH（窗口刷新 Unix 秒）"; FAIL=1; }
[ -x "$CODEX" ]   || { echo "FAIL: Codex CLI 不可执行 -> $CODEX"; FAIL=1; }
[ -d "$WORKDIR" ] || { echo "FAIL: 工作目录不存在 -> $WORKDIR"; FAIL=1; }
[ -s "$PROMPTFILE" ] || { echo "FAIL: 接力指令为空 -> $PROMPTFILE"; FAIL=1; }
[ "$FAIL" -eq 0 ] || { echo "参数校验未通过，放弃。"; exit 1; }

echo "线程 UUID : $THREAD"
echo "工作目录  : $WORKDIR"
echo "模型      : $MODEL / $EFFORT"
[ -n "$CODE_REPO" ] && echo "代码仓库  : $CODE_REPO"
echo "刷新时间  : $(date -r "$RESET_EPOCH" '+%Y-%m-%d %H:%M:%S')"

# =========================== 一次性守卫 ===========================
# 注意：变量后面紧跟中文标点时一律写 ${VAR}，
# 否则 bash 在 UTF-8 locale 下会把中文字节吞进变量名，报 unbound variable。
TODAY=$(date +%F)
if [ "${TODAY}" != "${TARGET_DATE}" ]; then
  echo "跳过：今天 ${TODAY}，非目标日期 ${TARGET_DATE}"
  exit 0
fi
if [ -f "${DONE_MARKER}" ]; then
  echo "跳过：本日已成功执行过（${DONE_MARKER} 存在）"
  exit 0
fi
# 这里【故意不拦截】ATTEMPT_MARKER。
# 实战教训：.attempted 若在调用前落盘并参与拦截，一条路径失败（例如 launchd 缺权限）
# 会把另一条本来能成功的路径挡在门外 —— 一次失败导致当天彻底没机会重试。
# 职责划分：
#   · 防"同时开火"   -> 下面的 .lock 互斥
#   · 防"当天重复跑" -> 上面的 .done（只在成功时写）
#   · .attempted      -> 仅诊断面包屑，不参与拦截
if [ -f "${ATTEMPT_MARKER}" ]; then
  echo "提示：本日已有过一次尝试（${ATTEMPT_MARKER} 存在）但未成功，本次继续投喂。"
fi

# =========================== 互斥锁 ===========================
if ! mkdir "${LOCKDIR}" 2>/dev/null; then
  echo "已有实例在运行（${LOCKDIR} 存在），本实例退出，避免重复执行。"
  exit 0
fi
trap 'rmdir "${LOCKDIR}" 2>/dev/null' EXIT INT TERM

# =========================== 等额度窗口刷新 ===========================
WAIT_UNTIL=$((RESET_EPOCH + GRACE))
if [ "$(date +%s)" -lt "${WAIT_UNTIL}" ]; then
  echo "当前 $(date '+%H:%M:%S')，等待至 $(date -r "${WAIT_UNTIL}" '+%H:%M:%S') ..."
  while [ "$(date +%s)" -lt "${WAIT_UNTIL}" ]; do sleep 15; done
fi
echo "已过刷新点，开始执行：$(date '+%H:%M:%S')"

PROMPT=$(cat "$PROMPTFILE")

# =========================== 干跑 ===========================
if [ "${DRY_RUN}" = "1" ]; then
  echo "===== DRY RUN：只打印，不实际调用 Codex ====="
  echo "指令字节数 : $(wc -c < "$PROMPTFILE" | tr -d ' ')"
  echo "输出文件   : ${LASTMSG}"
  echo "----- 指令全文 -----"
  cat "$PROMPTFILE"
  echo "----- 指令结束 -----"
  exit 0
fi

cd "$WORKDIR" || { echo "FAIL: 无法进入工作目录"; exit 1; }

# =========================== 主执行 ===========================
# 重要一：--approve-for-me 和 -C 是 exec 级参数，必须写在 resume【之前】。
#         写在后面会被 clap 判为 unexpected argument。
# 重要二：线程如果正被 Codex Desktop 打开着，它持有该线程的写锁，外部 exec resume 必然失败：
#             thread-store conflict: thread <id> already has an active writer
#         这时必须改用 `codex queue` —— 它把消息交给持有线程的 app-server 执行，不抢锁。
#         代价：queue 拿不到执行输出（日志里只有"已入队"的确认，实际结果在 Codex 界面里）。

ACTIVE_WRITER=0

run_once () {
  echo "---------- 尝试 #$1 $(date '+%H:%M:%S') ----------"
  local out
  out=$(caffeinate -i -s "$CODEX" exec \
    --approve-for-me \
    -C "$WORKDIR" \
    resume "$THREAD" "$PROMPT" \
    -m "$MODEL" \
    -c "model_reasoning_effort=\"${EFFORT}\"" \
    -o "$LASTMSG" 2>&1)
  local rc=$?
  echo "$out"
  case "$out" in
    *"already has an active writer"*) ACTIVE_WRITER=1 ;;
  esac
  return $rc
}

# 记下"已尝试"，作为诊断面包屑（不参与拦截）
touch "${ATTEMPT_MARKER}"

run_once 1
RC=$?

# 命中写锁冲突时不重试 —— 重试一百次结果一样，直接走 queue
if [ "${RC}" -ne 0 ] && [ "${ACTIVE_WRITER}" -eq 0 ]; then
  echo "第 1 次失败（退出码 ${RC}），${RETRY_WAIT} 秒后重试..."
  sleep "${RETRY_WAIT}"
  run_once 2
  RC=$?
fi

# =========================== 兜底：queue ===========================
if [ "${RC}" -ne 0 ]; then
  if [ "${ACTIVE_WRITER}" -eq 1 ]; then
    echo "线程被 Codex Desktop 持有写锁，跳过重试，直接改用 queue（这是预期路径）。"
  else
    echo "exec resume 未成功，改用 queue 投喂。"
  fi
  echo "注意：queue 走 app-server，由持有线程的 Codex 界面执行，本脚本拿不到执行输出。"
  "$CODEX" queue --thread "$THREAD" --message "$PROMPT"
  RC=$?
  [ "${RC}" -eq 0 ] && echo "queue 投喂成功（已入队即视为接力完成）。请到 Codex 界面查看执行情况。"
fi

# =========================== 收尾 ===========================
echo "---------- 结束 $(date '+%H:%M:%S') 退出码 ${RC} ----------"
if [ -f "${LASTMSG}" ]; then
  echo "---------- 最终回复 ----------"
  cat "${LASTMSG}"
  echo "---------- 最终回复结束 ----------"
fi

if [ "${RC}" -eq 0 ]; then
  touch "${DONE_MARKER}"
  echo "已标记完成：${DONE_MARKER}"
fi

exit "${RC}"
