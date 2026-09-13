#!/bin/bash
# ---------------------------------------------------------------------------
# inspect.sh —— 勘察工具
#
#   1. 列出最近的 Codex 线程（UUID / 标题 / cwd / 审批模式 / 模型）
#   2. 读取指定线程的额度窗口状态（已用百分比 + 重置时间，换算成本地时间）
#   3. 报出中断原因
#
# 用法：
#   ./inspect.sh                    # 列最近 20 个线程
#   ./inspect.sh <线程UUID>         # 看该线程的额度窗口
#   ./inspect.sh --grep 关键词      # 按标题关键词找线程
# ---------------------------------------------------------------------------

set -uo pipefail

PY="${PYTHON:-python3}"
CODEX_HOME_DIR="${CODEX_HOME:-$HOME/.codex}"
DB="$CODEX_HOME_DIR/state_5.sqlite"

if [ ! -f "$DB" ]; then
  echo "找不到 $DB —— 确认 Codex Desktop 装过并且至少跑过一次。" >&2
  exit 1
fi

MODE="${1:-list}"
ARG="${2:-}"

"$PY" - "$DB" "$CODEX_HOME_DIR" "$MODE" "$ARG" <<'PYEOF'
import datetime, json, pathlib, sqlite3, sys

db, codex_home, mode, arg = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]

def human(ts):
    try:
        return datetime.datetime.fromtimestamp(float(ts)).strftime('%Y-%m-%d %H:%M:%S')
    except Exception:
        return str(ts)

def connect():
    # 只读打开。Codex 可能在同时写，绝不能用可写模式。
    return sqlite3.connect(f'file:{db}?mode=ro', uri=True)

if mode in ('list', '--list') or (mode == '--grep' and not arg):
    c = connect()
    rows = list(c.execute("""
        select id, coalesce(name, ''), coalesce(title, ''), cwd,
               coalesce(approval_mode, ''), coalesce(model, ''),
               coalesce(reasoning_effort, ''), updated_at_ms, coalesce(archived, 0)
        from threads
        where coalesce(archived, 0) = 0
        order by updated_at_ms desc
        limit 20
    """))
    print(f"{'UUID':38} {'更新':20} {'模型':22} 标题 / cwd")
    print('-' * 130)
    for r in rows:
        tid, name, title, cwd, appr, model, eff, upd, _ = r
        label = name or (title[:40].replace('\n', ' ') if title else '(无标题)')
        print(f"{tid:38} {human(int(upd)/1000):20} {model+'/'+eff:22} {label[:44]}")
        print(f"{'':38} {'':20} {'':22} cwd={cwd}")
    print()
    print("取一个 UUID，然后跑：  ./inspect.sh <UUID>")
    sys.exit(0)

if mode == '--grep':
    c = connect()
    rows = list(c.execute("""
        select id, coalesce(name,''), coalesce(title,''), cwd, coalesce(approval_mode,''),
               coalesce(model,''), coalesce(reasoning_effort,''), updated_at_ms
        from threads
        where (name like ? or title like ?) and coalesce(archived,0)=0
        order by updated_at_ms desc limit 10
    """, (f'%{arg}%', f'%{arg}%')))
    if not rows:
        print(f"没找到标题包含「{arg}」的线程。")
        sys.exit(0)
    for tid, name, title, cwd, appr, model, eff, upd in rows:
        print(f"{tid}  {human(int(upd)/1000)}  {model}/{eff}  appr={appr}")
        print(f"  标题: {(name or title[:70]).replace(chr(10),' ')}")
        print(f"  cwd : {cwd}")
    sys.exit(0)

# 单线程详情
tid = mode
c = connect()
row = list(c.execute("""
    select id, coalesce(name,''), coalesce(title,''), cwd, coalesce(approval_mode,''),
           coalesce(model,''), coalesce(reasoning_effort,''), rollout_path,
           coalesce(tokens_used,0), updated_at_ms, git_branch
    from threads where id = ?
""", (tid,)))
if not row:
    print(f"线程 {tid} 不在 threads 表里。先跑 ./inspect.sh 看列表。")
    sys.exit(1)

r = row[0]
print("=" * 70)
print(f"UUID       : {r[0]}")
print(f"标题       : {(r[1] or r[2][:60]).replace(chr(10),' ')}")
print(f"cwd        : {r[3]}")
print(f"审批模式   : {r[4]}   <-- on-request 的话，无人值守必须加 --approve-for-me")
print(f"模型       : {r[5]} / {r[6]}")
print(f"tokens     : {r[8]}")
print(f"git 分支   : {r[10]}")
print(f"最后更新   : {human(int(r[9])/1000)}")
print("=" * 70)

# 从 rollout 里读额度窗口
rp = r[7]
if not rp or not pathlib.Path(rp).exists():
    print("rollout 文件找不到，无法读取额度窗口。")
    sys.exit(1)

last_tc = None
last_err = None
for line in pathlib.Path(rp).read_text(encoding='utf-8', errors='replace').splitlines():
    if 'token_count' not in line and 'task_complete' not in line and 'codex_error_info' not in line:
        continue
    try:
        d = json.loads(line)
    except Exception:
        continue
    pl = d.get('payload') or {}
    if isinstance(pl, dict) and pl.get('type') == 'token_count':
        rl = pl.get('rate_limits') or {}
        # 注意：文件末尾常有一条 primary/secondary 全为 null 的 premium 事件，
        # 所以只保留「最后一个真正带窗口数据」的那条。
        if rl.get('primary') or rl.get('secondary'):
            last_tc = pl
        elif last_tc is None:
            last_tc = pl
    if isinstance(pl, dict) and pl.get('codex_error_info'):
        last_err = pl

if last_tc:
    # 真实结构：payload.rate_limits.{primary,secondary,credits,plan_type}
    rl = last_tc.get('rate_limits') or {}
    if not rl:
        print("token_count 事件里没有 rate_limits，可能是旧版本格式。")
    for label, key in (('5小时窗口 (primary)', 'primary'), ('周窗口 (secondary)', 'secondary')):
        w = rl.get(key)
        if not w:
            print(f"{label:22} 无数据（该套餐可能不含这一档）")
            continue
        pct = w.get('used_percent')
        mins = w.get('window_minutes')
        ra = w.get('resets_at')
        print(f"{label:22} 已用 {pct}%   窗口 {mins} 分钟   重置 {human(ra)}  ({ra})")
    print(f"{'套餐 plan_type':22} {rl.get('plan_type')}")
    print(f"{'credits':22} {rl.get('credits')}")
    print(f"{'触发的限流类型':22} {rl.get('rate_limit_reached_type')}")
    info = last_tc.get('info') or {}
    tot = (info.get('total_token_usage') or {}).get('total_tokens')
    if tot:
        print(f"{'本线程累计 tokens':22} {tot}")

if last_err:
    print()
    print(f"最后一次中断原因: {last_err.get('codex_error_info')}")
    msg = last_err.get('message')
    if msg:
        print(f"原始信息        : {msg}")

print()
print("把 primary 的 resets_at 填进：")
print(f'  export CODEX_RESUME_RESET_EPOCH=<上面的数字>')
PYEOF
