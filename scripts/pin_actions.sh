#!/usr/bin/env bash
# ══════════════════════════════════════════════════════════════════════════════
# pin_actions.sh —— 把 YAML 里的 PINNED_SHA_PLACEHOLDER 换成真实 commit SHA
#
# 为什么必须做：actions/checkout@v4、actions/cache@v5、upload-artifact@v7 都是
#   *可变 tag*，easimon/maximize-build-space@master 更是*分支引用*——
#   上游一推，你的 CI 就在跑一份没 review 过的代码（2025 年 maximize-build-space
#   就因 rm -rf 路径变更引发过连环事故）。
#
# 用法：
#   bash scripts/pin_actions.sh              # 只查不写，打印映射表
#   bash scripts/pin_actions.sh --write      # 回填 YAML
#
# 回填后建议加 .github/dependabot.yml（本仓库已附带），让 SHA 到期自动提更新 PR，
# 否则钉死=永远收不到安全修复。
# ══════════════════════════════════════════════════════════════════════════════
set -euo pipefail
WF=".github/workflows/Build BakaSU.yml"
WRITE=0; [[ "${1:-}" == "--write" ]] && WRITE=1
[[ -f "$WF" ]] || { echo "::error::$WF 不存在，请在仓库根目录运行"; exit 1; }

# 占位符 → (repo, ref, ref类型 tag|branch)
declare -A TARGETS=(
  ["actions/checkout@PINNED_SHA_PLACEHOLDER"]="actions/checkout|v4|tag"
  ["actions/cache@PINNED_SHA_PLACEHOLDER"]="actions/cache|v5|tag"
  ["actions/upload-artifact@PINNED_SHA_PLACEHOLDER"]="actions/upload-artifact|v7|tag"
  ["easimon/maximize-build-space@PINNED_SHA_PLACEHOLDER"]="easimon/maximize-build-space|master|branch"
)

resolve() {  # repo ref kind -> sha
  local repo="$1" ref="$2" kind="$3" sha
  if [[ "$kind" == "branch" ]]; then
    sha=$(gh api "repos/${repo}/git/refs/heads/${ref}" --jq '.object.sha' 2>/dev/null || true)
  else
    # tag 可能是 annotated object → 要解一层 ^{}
    sha=$(gh api "repos/${repo}/git/refs/tags/${ref}" --jq '.object.sha' 2>/dev/null || true)
    if [[ -n "$sha" ]]; then
      local type; type=$(gh api "repos/${repo}/git/tags/${sha}" --jq '.object.type' 2>/dev/null || echo commit)
      if [[ "$type" == "tag" ]]; then
        sha=$(gh api "repos/${repo}/git/tags/${sha}" --jq '.object.sha' 2>/dev/null)
      fi
    fi
  fi
  [[ -n "$sha" ]] || { echo "ERROR" ; return 1; }
  echo "$sha"
}

command -v gh >/dev/null 2>&1 || { echo "::error::需要 gh CLI 且已 gh auth login"; exit 1; }

declare -A MAP
echo "🔎 解析真实 SHA ..."
for key in "${!TARGETS[@]}"; do
  IFS='|' read -r repo ref kind <<< "${TARGETS[$key]}"
  sha=$(resolve "$repo" "$ref" "$kind" || echo ERROR)
  if [[ "$sha" == "ERROR" ]]; then
    echo "   ❌ $repo@$ref 解析失败（API 限流？仓库名变了？）"
  else
    printf '   ✅ %-42s %s  (%s)\n' "$repo@$ref" "${sha:0:12}" "$kind"
    MAP[$key]="${sha:0:12} # ${ref}"
  fi
done

echo
for k in "${!MAP[@]}"; do printf '  %s  →  %s\n' "$k" "${MAP[$k]}"; done | sort

if [[ "$WRITE" == "1" ]]; then
  if [[ ${#MAP[@]} -ne 4 ]]; then
    echo "::error::有 $((4-${#MAP[@]})) 个未解析成功，拒绝半写入（避免 YAML 里混入 ERROR 字样）"; exit 1
  fi
  cp "$WF" "${WF}.bak.$(date +%s)"
  python3 - "$WF" "${MAP[actions/checkout@PINNED_SHA_PLACEHOLDER]}" \
                  "${MAP[actions/cache@PINNED_SHA_PLACEHOLDER]}" \
                  "${MAP[actions/upload-artifact@PINNED_SHA_PLACEHOLDER]}" \
                  "${MAP[easimon/maximize-build-space@PINNED_SHA_PLACEHOLDER]}" <<'PY'
import sys,io
wf,co,ca,up,mx=sys.argv[1:6]
s=io.open(wf,encoding='utf-8').read()
for ph,val in [("actions/checkout@PINNED_SHA_PLACEHOLDER # v4", f"actions/checkout@{co}"),
               ("actions/cache@PINNED_SHA_PLACEHOLDER # v5", f"actions/cache@{ca}"),
               ("actions/upload-artifact@PINNED_SHA_PLACEHOLDER # v7", f"actions/upload-artifact@{up}"),
               ("easimon/maximize-build-space@PINNED_SHA_PLACEHOLDER # master", f"easimon/maximize-build-space@{mx}")]:
    n=s.count(ph)
    s=s.replace(ph,val)
    print(f"  替换 {n} 处: {ph.split('@')[0]} → {val.split('@')[1][:12]}")
io.open(wf,'w',encoding='utf-8').write(s)
print(f"✅ 已回填 {wf}")
PY
  echo
  echo "⚠️  别忘了："
  echo "   1) git diff 一眼确认没有 'ERROR' 字样残留在 YAML 里"
  echo "   2) 提交 .github/dependabot.yml（已生成在同目录），否则钉死后再也收不到安全更新"
  echo "   3) 顺手把你们 fork 里其他 4 个 workflow 也跑一遍这个脚本"
else
  echo
  echo "(dry-run。加 --write 才真正写入)"
fi
