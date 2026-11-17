#!/usr/bin/env bash
# ══════════════════════════════════════════════════════════════════════════════
# gen_cpu_map.sh —— 从 Xiaomichael/kernel_manifest 真实分支自动生成 CPU_OF / KMI_OF
#
# 用途：填回 Build BakaSU.yml 里 "✅ Validate Matrix" 步的那两张关联数组。
#      手填必错（13个CPU分支 × 34个机型，合法组合只有十几个），
#      所以直接从 manifest 仓库的分支内容反查——那是唯一的事实来源。
#
# 用法：
#   cd your_fork_of_OnePlus-Actions
#   bash scripts/gen_cpu_map.sh              # 打印到 stdout
#   bash scripts/gen_cpu_map.sh --write      # 直接回填到 .github/workflows/Build BakaSU.yml
#
# 依赖：gh CLI (已登录) 或 curl + GITHUB_TOKEN
# ══════════════════════════════════════════════════════════════════════════════
set -euo pipefail

MANIFEST_REPO="${MANIFEST_REPO:-Xiaomichael/kernel_manifest}"
CPUS=(sm8750 sm8735 sm8650 sm8635 sm8550 sm8450 sm8475 sm7675 sm7635 sm7550 sm6375 mt6991 mt6989)
WRITE=0
[[ "${1:-}" == "--write" ]] && WRITE=1

WF=".github/workflows/Build BakaSU.yml"

# ── 拉某分支下的 xml 清单 ────────────────────────────────────────────────────
list_xml() {
  local cpu="$1"
  if command -v gh >/dev/null 2>&1; then
    gh api "repos/${MANIFEST_REPO}/contents/?ref=oneplus/${cpu}" --jq '.[].name' 2>/dev/null \
      | grep '\.xml$' || true
  else
    curl -fsSL -H "${GITHUB_TOKEN:+-Authorization: token $GITHUB_TOKEN}" \
      "https://api.github.com/repos/${MANIFEST_REPO}/contents/?ref=oneplus/${cpu}" \
      | python3 -c "import sys,json;[print(x['name']) for x in json.load(sys.stdin) if x['name'].endswith('.xml')]" 2>/dev/null || true
  fi
}

declare -A CPU_OF
CONFLICT=()

echo "🔍 扫描 ${MANIFEST_REPO} 的 oneplus/* 分支..." >&2
for cpu in "${CPUS[@]}"; do
  xmls=$(list_xml "$cpu")
  if [[ -z "$xmls" ]]; then
    echo "   ⚠️  oneplus/${cpu} : 无 xml 或分支不存在，跳过" >&2
    continue
  fi
  n=$(echo "$xmls" | wc -l)
  echo "   ✅ oneplus/${cpu} : ${n} 个机型" >&2
  while IFS= read -r x; do
    dev="${x%.xml}"
    if [[ -n "${CPU_OF[$dev]:-}" ]]; then
      CONFLICT+=("$dev 同时在 ${CPU_OF[$dev]} 和 ${cpu}")
    fi
    CPU_OF[$dev]="$cpu"
  done <<< "$xmls"
done

# ── 交叉校验：同一个 xml 出现在两个 CPU 分支 = 需要人工确认 ──────────────────
if [[ ${#CONFLICT[@]} -gt 0 ]]; then
  echo >&2
  echo "🚨 警告：以下机型在多个 CPU 分支下都存在，请人工确认哪个是真的：" >&2
  printf '   • %s\n' "${CONFLICT[@]}" >&2
  echo "   （保留最后扫描到的那个，可能不对！）" >&2
fi

# ── KMI 推断：按 CPU 代际映射（一加 GKI 实机口径）────────────────────────────
kmi_of_cpu() {
  case "$1" in
    sm8750|sm8735|mt6991|mt6989) echo "android15/6.6" ;;
    sm8650|sm8635|sm8550|sm8450|sm8475|sm7675|sm7635|sm7550) echo "android14/6.1" ;;
    sm6375) echo "android13/5.10" ;;
    *) echo "UNKNOWN" ;;
  esac
}

# 已知例外（实机确认过的，覆盖上面的粗粒度推断）
declare -A KMI_OVERRIDE=(
  # OP10 Pro / 10T / Ace Pro / Open 是 5.10 + android12（不是 android14！）
  [oneplus_10_pro_b]=android12/5.10
  [oneplus_10t_v]=android12/5.10
  [oneplus_ace_pro_v]=android12/5.10
  [oneplus_open_b]=android12/5.10
  # Nord CE4 系是 sm6375 + 5.10 + android13
  [oneplus_nord_ce4_lite_5g]=android13/5.10
  [oneplus_nord_ce4_b]=android13/5.10
  # sm8450 系里 Ace2 Pro/OP11 是 6.1，但 Ace Pro(sm8450) 是 5.10 —— 已在 OVERRIDE 里
)

# ── 输出 ────────────────────────────────────────────────────────────────────
OUT_CPU=$(mktemp); OUT_KMI=$(mktemp)
{
  echo "          # ←←← 由 scripts/gen_cpu_map.sh 自动生成于 $(date -u '+%F %T UTC')，请勿手改 ←←←"
  echo "          declare -A CPU_OF=("
  lineno=0
  for dev in $(printf '%s\n' "${!CPU_OF[@]}" | sort); do
    printf '            [%s]=%s\n' "$dev" "${CPU_OF[$dev]}" >> "$OUT_CPU"
  done
  # 每行塞两个，紧凑好看
  paste -sd' \n' "$OUT_CPU" | sed 's/^/          /' 
  echo "          )"
} 

{
  echo "          # ←←← 同上自动生成；KMI_OVERRIDE 里的例外来自实机确认 ←←←"
  echo "          declare -A KMI_OF=("
  : > "$OUT_KMI"
  for dev in $(printf '%s\n' "${!CPU_OF[@]}" | sort); do
    k="${KMI_OVERRIDE[$dev]:-$(kmi_of_cpu "${CPU_OF[$dev]}")}"
    printf '[%s]=%s\n' "$dev" "$k" >> "$OUT_KMI"
  done
  paste -sd' \n' "$OUT_KMI" | sed 's/^/          /'
  echo "          )"
}

echo >&2
echo "📊 汇总：$(printf '%s\n' "${!CPU_OF[@]}" | wc -l) 个机型 / ${#CPUS[@]} 个CPU分支" >&2

# ── 回填 ────────────────────────────────────────────────────────────────────
if [[ "$WRITE" == "1" ]]; then
  [[ -f "$WF" ]] || { echo "::error::$WF 不存在，请在仓库根目录运行"; exit 1; }
  cp "$WF" "${WF}.bak.$(date +%s)"
  python3 - "$WF" "$OUT_CPU" "$OUT_KMI" <<'PY'
import sys,io,re
wf,cpu_f,kmi_f=sys.argv[1:4]
s=io.open(wf,encoding='utf-8').read()
new_cpu=io.open(cpu_f,encoding='utf-8').read().rstrip('\n')
new_kmi=io.open(kmi_f,encoding='utf-8').read().rstrip('\n')
# 替换 CPU_OF=( ... ) 块
s2=re.sub(r'          # ←←← 由 scripts/gen_cpu_map\.sh 自动生成.*?\n          declare -A CPU_OF=\(.*?\n          \)',
          new_cpu, s, count=1, flags=re.S)
s2=re.sub(r'          # ←←← 同上自动生成；KMI_OVERRIDE 里的例外来自实机确认 ←←←\n          declare -A KMI_OF=\(.*?\n          \)',
          new_kmi, s2, count=1, flags=re.S)
if s2==s:
    print("::warning::未发生替换（锚点注释被改过？），请手工拷贝上面输出"); sys.exit(1)
io.open(wf,'w',encoding='utf-8').write(s2)
print(f"✅ 已回填 {wf}（原文件备份为 {wf}.bak.<ts>）")
PY
fi
rm -f "$OUT_CPU" "$OUT_KMI"
echo >&2 "💡 提示：生成后请 diff 一遍，重点看 CONFLICT 警告里的机型；" >&2
echo >&2 "   有疑问就用 adb shell 'getprop ro.board.platform' + 'uname -r' 在真机上核。" >&2
