#!/bin/bash
# ---------------------------------------------------------------------------
# codex-quota-window-resume
#
# 在 Codex 额度窗口重置后，自动把续跑指令投喂给被中断的线程。
#
# 用法：
#   export CODEX_THREAD="<线程UUID>"
#   export CODEX_WORKDIR="/path/to/thread/cwd"
#   export CODEX_RESUME_RESET_EPOCH=1735689600     # 窗口重置的 Unix 秒
#   export CODEX_RESUME_TARGET_DATE=2026-09-14     # 可选，默认今天
#   export CODEX_RESUME_DRY_RUN=1                  # 先干跑验证
#   ./run-resume.sh
#
# 依赖：jq 不需要；sqlite3 / git 可选。
# ---------------------------------------------------------------------------

set -uo pipefail

# =========================== 配置 ===========================

# Codex Desktop 内置 CLI。注意：不是 brew 装的那个（那个往往是坏的）。
CODEX="${CODEX_BIN:-/Applications/ChatGPT.app/Contents/Resources/codex}"

# 要续跑的线程 UUID。必填。
THREAD="${CODEX_THREAD:-}"

# 线程原始工作目录（= threads 表里的 cwd）。也是 Codex 的受信任目录。
WORKDIR="${CODEX_WORKDIR:-$HOME}"

# 可选：实际代码仓库路径。仅用于前置检查时多看一眼，不影响投喂。
CODE_REPO="${CODEX_CODE_REPO:-}"

# 模型与推理档位
MODEL="${CODEX_MODEL:-gpt-5.6-sol}"
EFFORT="${CODEX_EFFORT:-ultra}"

# 运行目录（日志、指令、标记都放这儿）
BASE="${CODEX_RESUME_BASE:-$HOME/.codex-resume}"
MSGFILE="${CODEX_RESUME_MSG:-$BASE/message.txt}"

# 一次性守卫：默认只对「今天」生效
TARGET_DATE="${CODEX_RESUME_TARGET_DATE:-$(date +%F)}"

# 额度窗口重置的 Unix 秒。必填（留 0 会立刻执行）。
RESET_EPOCH="${CODEX_RESUME_RESET_EPOCH:-0}"

# 重置点之后再多等几秒，避开边界抖动
GRACE="${CODEX_RESUME_GRACE:-25}"

# 1 = 只打印将要执行的命令，不真跑
DRY_RUN="${CODEX_RESUME_DRY_RUN:-0}"

# 重试间隔（秒）
RETRY_WAIT="${CODEX_RESUME_RETRY_WAIT:-60}"

DONE_MARKER="$BASE/.done-$TARGET_DATE"
ATTEMPT_MARKER="$BASE/.attempted-$TARGET_DATE"
LOCKDIR="$BASE/.lock"

export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

# =========================== 日志 ===========================
mkdir -p "$BASE/logs" || exit 1
STAMP=$(date +%Y%m%d-%H%M%S)
LOG="$BASE/logs/run-$STAMP.log"
LASTMSG="$BASE/logs/last-message-$STAMP.txt"
exec >>"$LOG" 2>&1

echo "=================================================="
echo "codex-quota-window-resume"
echo "启动时间 : $(date '+%Y-%m-%d %H:%M:%S')"
echo "日志文件 : $LOG"

# =========================== 参数校验 ===========================
FAIL=0
[ -n "$THREAD" ]  || { echo "FAIL: 未设置 CODEX_THREAD（线程 UUID）"; FAIL=1; }
[ "$RESET_EPOCH" -gt 0 ] 2>/dev/null || { echo "FAIL: 未设置 CODEX_RESUME_RESET_EPOCH（额度重置 Unix 秒）"; FAIL=1; }
[ -x "$CODEX" ]   || { echo "FAIL: Codex CLI 不可执行 -> $CODEX"; FAIL=1; }
[ -d "$WORKDIR" ] || { echo "FAIL: 工作目录不存在 -> $WORKDIR"; FAIL=1; }
[ -s "$MSGFILE" ] || { echo "FAIL: 续跑指令为空 -> $MSGFILE"; FAIL=1; }
[ "$FAIL" -eq 0 ] || { echo "参数校验未通过，放弃。"; exit 1; }

echo "线程 UUID : $THREAD"
echo "工作目录  : $WORKDIR"
echo "模型      : $MODEL / $EFFORT"
[ -n "$CODE_REPO" ] && echo "代码仓库  : $CODE_REPO"
echo "重置时间  : $(date -r "$RESET_EPOCH" '+%Y-%m-%d %H:%M:%S')"

# =========================== 一次性守卫 ===========================
# 注意：变量后面紧跟中文标点时一律写 ${VAR}，否则 bash 会把中文吞进变量名。
TODAY=$(date +%F)
if [ "${TODAY}" != "${TARGET_DATE}" ]; then
  echo "跳过：今天 ${TODAY}，非目标日期 ${TARGET_DATE}"
  exit 0
fi
if [ -f "${DONE_MARKER}" ]; then
  echo "跳过：本日已成功执行过（${DONE_MARKER} 存在）"
  exit 0
fi
if [ -f "${ATTEMPT_MARKER}" ]; then
  echo "跳过：本日已尝试过（${ATTEMPT_MARKER} 存在），不重复投喂"
  exit 0
fi

# =========================== 互斥锁 ===========================
if ! mkdir "${LOCKDIR}" 2>/dev/null; then
  echo "已有实例在运行（${LOCKDIR} 存在），本实例退出，避免重复执行。"
  exit 0
fi
trap 'rmdir "${LOCKDIR}" 2>/dev/null' EXIT INT TERM

# =========================== 等额度窗口重置 ===========================
WAIT_UNTIL=$((RESET_EPOCH + GRACE))
if [ "$(date +%s)" -lt "${WAIT_UNTIL}" ]; then
  echo "当前 $(date '+%H:%M:%S')，等待至 $(date -r "${WAIT_UNTIL}" '+%H:%M:%S') ..."
  while [ "$(date +%s)" -lt "${WAIT_UNTIL}" ]; do sleep 15; done
fi
echo "已过重置点，开始执行：$(date '+%H:%M:%S')"

PROMPT=$(cat "$MSGFILE")

# =========================== 干跑 ===========================
if [ "${DRY_RUN}" = "1" ]; then
  echo "===== DRY RUN：只打印，不实际调用 Codex ====="
  echo "指令字节数 : $(wc -c < "$MSGFILE" | tr -d ' ')"
  echo "输出文件   : ${LASTMSG}"
  echo "----- 指令全文 -----"
  cat "$MSGFILE"
  echo "----- 指令结束 -----"
  exit 0
fi

cd "$WORKDIR" || { echo "FAIL: 无法进入工作目录"; exit 1; }

# =========================== 主执行 ===========================
# 重要：--approve-for-me 和 -C 是 exec 级参数，必须写在 resume【之前】。
run_once () {
  echo "---------- 尝试 #$1 $(date '+%H:%M:%S') ----------"
  caffeinate -i -s "$CODEX" exec \
    --approve-for-me \
    -C "$WORKDIR" \
    resume "$THREAD" "$PROMPT" \
    -m "$MODEL" \
    -c "model_reasoning_effort=\"${EFFORT}\"" \
    -o "$LASTMSG"
  return $?
}

touch "${ATTEMPT_MARKER}"

run_once 1
RC=$?

if [ "${RC}" -ne 0 ]; then
  echo "第 1 次失败（退出码 ${RC}），${RETRY_WAIT} 秒后重试..."
  sleep "${RETRY_WAIT}"
  run_once 2
  RC=$?
fi

# =========================== 兜底 ===========================
if [ "${RC}" -ne 0 ]; then
  echo "exec resume 两次都失败，改用 queue 投喂（此方式拿不到执行输出）"
  "$CODEX" queue --thread "$THREAD" --message "$PROMPT"
  RC=$?
  [ "${RC}" -eq 0 ] && echo "queue 投喂成功，请到 Codex 界面查看该线程执行情况。"
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
