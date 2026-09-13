#!/bin/bash
# ---------------------------------------------------------------------------
# inspect.sh —— 接力前勘察
#
#   1. 列出最近的 Codex 线程（UUID / 标题 / cwd / 审批模式 / 模型）
#   2. 读取指定线程的额度窗口（已用百分比 + 刷新时刻，换算成本地时间）
#   3. 报出中断原因
#
# 用法：
#   ./inspect.sh                    # 列最近 20 个线程
#   ./inspect.sh --grep 关键词      # 按标题关键词找线程
#   ./inspect.sh <线程UUID>         # 看该线程的额度窗口详情
# ---------------------------------------------------------------------------

set -uo pipefail

PY="${PYTHON:-python3}"
CODEX_DIR="${CODEX_HOME:-$HOME/.codex}"
DB="$CODEX_DIR/state_5.sqlite"

if [ ! -f "$DB" ]; then
  echo "找不到 $DB —— 确认 Codex 装过并且至少跑过一次。" >&2
  exit 1
fi

MODE="${1:-list}"
ARG="${2:-}"

"$PY" - "$DB" "$CODEX_DIR" "$MODE" "$ARG" <<'PYEOF'
import datetime, json, pathlib, sqlite3, sys

db, codex_dir, mode, arg = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]

def human(ts):
    try:
        return datetime.datetime.fromtimestamp(float(ts)).strftime('%Y-%m-%d %H:%M:%S')
    except Exception:
        return str(ts)

def connect():
    # 只读打开。Codex 可能正在同时写，绝不能用可写模式。
    return sqlite3.connect(f'file:{db}?mode=ro', uri=True)

def list_threads():
    c = connect()
    rows = list(c.execute("""
        select id, coalesce(name, ''), coalesce(title, ''), cwd,
               coalesce(approval_mode, ''), coalesce(model, ''),
               coalesce(reasoning_effort, ''), updated_at_ms
        from threads
        where coalesce(archived, 0) = 0
        order by updated_at_ms desc
        limit 20
    """))
    print(f"{'UUID':38} {'更新':20} {'模型':22} 标题 / cwd")
    print('-' * 132)
    for r in rows:
        tid, name, title, cwd, appr, model, eff, upd = r
        label = name or (title[:44].replace('\n', ' ') if title else '(无标题)')
        print(f"{tid:38} {human(int(upd)/1000):20} {model+'/'+eff:22} {label[:46]}")
        print(f"{'':38} {'':20} {'':22} cwd={cwd}")
    print()
    print("取一个 UUID，然后跑：  ./inspect.sh <UUID>")

if mode in ('list', '--list'):
    list_threads()
    sys.exit(0)

if mode == '--grep':
    if not arg:
        print("用法: ./inspect.sh --grep <关键词>")
        sys.exit(1)
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
        print(f"{tid}  {human(int(upd)/1000)}  {model}/{eff}  approval={appr}")
        print(f"  标题: {(name or title[:70]).replace(chr(10),' ')}")
        print(f"  cwd : {cwd}")
    sys.exit(0)

# ---------------- 单线程详情 ----------------
tid = mode
c = connect()
row = list(c.execute("""
    select id, coalesce(name,''), coalesce(title,''), cwd, coalesce(approval_mode,''),
           coalesce(model,''), coalesce(reasoning_effort,''), rollout_path,
           coalesce(tokens_used,0), updated_at_ms, coalesce(git_branch,'')
    from threads where id = ?
""", (tid,)))
if not row:
    print(f"线程 {tid} 不在 threads 表里。先跑 ./inspect.sh 看列表。")
    sys.exit(1)

r = row[0]
print("=" * 72)
print(f"UUID         : {r[0]}")
print(f"标题         : {(r[1] or r[2][:60]).replace(chr(10),' ')}")
print(f"cwd          : {r[3]}")
print(f"审批模式     : {r[4]}   <-- on-request 时，无人值守必须加 --approve-for-me")
print(f"模型         : {r[5]} / {r[6]}")
print(f"累计 tokens  : {r[8]}")
print(f"git 分支     : {r[10]}")
print(f"最后更新     : {human(int(r[9])/1000)}")
print("=" * 72)

rp = r[7]
if not rp or not pathlib.Path(rp).exists():
    print("rollout 文件找不到，无法读取额度窗口。")
    sys.exit(1)

last_tc = None
last_err = None
for line in pathlib.Path(rp).read_text(encoding='utf-8', errors='replace').splitlines():
    if 'token_count' not in line and 'codex_error_info' not in line:
        continue
    try:
        d = json.loads(line)
    except Exception:
        continue
    pl = d.get('payload') or {}
    if not isinstance(pl, dict):
        continue
    if pl.get('type') == 'token_count':
        rl = pl.get('rate_limits') or {}
        # 注意：文件末尾常有一条 limit_id=premium 且 primary/secondary 全为 null 的事件，
        # 所以只保留「最后一个真正带窗口数据」的那条，否则永远读不到刷新时刻。
        if rl.get('primary') or rl.get('secondary'):
            last_tc = pl
        elif last_tc is None:
            last_tc = pl
    if pl.get('codex_error_info'):
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
        print(f"{label:22} 已用 {w.get('used_percent')}%   "
              f"窗口 {w.get('window_minutes')} 分钟   "
              f"刷新 {human(w.get('resets_at'))}  ({w.get('resets_at')})")
    print(f"{'套餐 plan_type':22} {rl.get('plan_type')}")
    print(f"{'credits':22} {rl.get('credits')}")
    info = last_tc.get('info') or {}
    tot = (info.get('total_token_usage') or {}).get('total_tokens')
    if tot:
        print(f"{'本线程 tokens':22} {tot}")

if last_err:
    print()
    print(f"最后一次中断原因 : {last_err.get('codex_error_info')}")
    msg = last_err.get('message')
    if msg:
        print(f"原始信息         : {msg}")

print()
print("把 primary 的 resets_at 填进：")
print('  export CODEX_HANDOFF_RESET_EPOCH=<上面的数字>')
PYEOF
