#!/bin/zsh
# 本机每天下午 17:30 刷新 T7 看板，只推送到 wangchl03/report（GitHub Pages）。
# 密码只从 ~/.t7_dashboard.env 读取，不要写进仓库。
set -euo pipefail
PAGES_REPO="${PAGES_REPO:-$HOME/Documents/trae_projects/github_pages_repo}"
ENV_FILE="${ENV_FILE:-$HOME/.t7_dashboard.env}"
cd "$PAGES_REPO"
if [[ -f "$ENV_FILE" ]]; then
  set -a
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  set +a
fi
if [[ -z "${PGPASSWORD:-}" ]]; then
  echo "缺少 PGPASSWORD。请写在 $ENV_FILE 或先 export。" >&2
  exit 1
fi
python3 appendix_t7_0818_dashboard.py
git add t7.html t7-0818.html t7-0902.html t7-0910.html t7-0917.html \
  t7_0818_dashboard_data.json t7_0902_dashboard_data.json t7_0910_dashboard_data.json t7_0917_dashboard_data.json \
  appendix_t7_0818_dashboard.sql appendix_t7_0902_dashboard.sql appendix_t7_0910_dashboard.sql appendix_t7_0917_dashboard.sql
if git diff --cached --quiet; then
  echo "no changes in wangchl03/report"
  exit 0
fi
git commit -m "Refresh T7 recall dashboards for $(date +%Y-%m-%d)."
git push origin HEAD
