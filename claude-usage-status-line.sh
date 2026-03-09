#!/bin/bash
input=$(cat)

# ── Parse stdin ──
MODEL=$(echo "$input" | jq -r '.model.display_name // "?"')
DIR=$(echo "$input" | jq -r '.workspace.current_dir // ""')
DIR_NAME="${DIR##*/}"
CTX_PCT=$(echo "$input" | jq -r '.context_window.used_percentage // 0' | cut -d. -f1)
NATIVE_SP=$(echo "$input" | jq -r '.five_hour.utilization // empty' 2>/dev/null)
NATIVE_SR_AT=$(echo "$input" | jq -r '.five_hour.resets_at // empty' 2>/dev/null)
NATIVE_WP=$(echo "$input" | jq -r '.seven_day.utilization // empty' 2>/dev/null)
NATIVE_WR_AT=$(echo "$input" | jq -r '.seven_day.resets_at // empty' 2>/dev/null)
NATIVE_EU_ENABLED=$(echo "$input" | jq -r '.extra_usage.is_enabled // empty' 2>/dev/null)
NATIVE_EU_USED=$(echo "$input" | jq -r '.extra_usage.used_credits // empty' 2>/dev/null)
NATIVE_EU_LIMIT=$(echo "$input" | jq -r '.extra_usage.monthly_limit // empty' 2>/dev/null)
NATIVE_EU_PCT=$(echo "$input" | jq -r '.extra_usage.utilization // empty' 2>/dev/null)

# ── Colors ──
B='\033[1m'
D='\033[2m'
U='\033[4m'
R='\033[0m'
CY='\033[36m'
GN='\033[32m'
YL='\033[33m'
RD='\033[91m'
BL='\033[94m'
WH='\033[97m'
GR='\033[38;5;245m'
SL='\033[38;5;110m'

# ── Bar ──
bar() {
  local p=$1 n=${2:-12} f=$((p * n / 100)) e
  [ "$f" -gt "$n" ] && f=$n
  e=$((n - f))
  local c="${GN}"
  [ "$p" -ge 50 ] && c="${YL}"
  [ "$p" -ge 80 ] && c="${RD}"
  local o="${c}"
  for ((i = 0; i < f; i++)); do o+="━"; done
  o+="${GR}"
  for ((i = 0; i < e; i++)); do o+="─"; done
  echo -ne "${o}${R}"
}

percent_color() {
  local p=${1:-0}
  if [ "$p" -ge 80 ]; then
    echo -ne "$RD"
  elif [ "$p" -ge 50 ]; then
    echo -ne "$YL"
  else
    echo -ne "$GN"
  fi
}

human_age() {
  local secs=${1:-0}
  if [ "$secs" -lt 60 ]; then
    printf 'just now'
  elif [ "$secs" -lt 3600 ]; then
    local mins=$((secs / 60))
    if [ "$mins" -eq 1 ]; then
      printf '1 minute ago'
    else
      printf '%s minutes ago' "$mins"
    fi
  else
    local hrs=$((secs / 3600))
    local mins=$(((secs % 3600) / 60))
    if [ "$hrs" -eq 1 ]; then
      printf '1 hour'
    else
      printf '%s hours' "$hrs"
    fi
    if [ "$mins" -gt 0 ]; then
      printf ' %s min ago' "$mins"
    else
      printf ' ago'
    fi
  fi
}

format_iso_relative() {
  local iso="$1"
  [ -z "$iso" ] && return 1
  python3 - "$iso" <<'PY' 2>/dev/null
from datetime import datetime, timezone
import sys

iso = sys.argv[1]
try:
    rt = datetime.fromisoformat(iso)
    now = datetime.now(timezone.utc)
    secs = int((rt - now).total_seconds())
    if secs <= 0:
        print("soon")
    else:
        d, rem = divmod(secs, 86400)
        h, rem = divmod(rem, 3600)
        m = rem // 60
        parts = []
        if d > 0:
            parts.append(f"{d} day" if d == 1 else f"{d} days")
        if h > 0:
            parts.append(f"{h} hr")
        if m > 0 or not parts:
            parts.append(f"{m} min")
        print(" ".join(parts))
except Exception:
    pass
PY
}

format_iso_local() {
  local iso="$1"
  [ -z "$iso" ] && return 1
  python3 - "$iso" <<'PY' 2>/dev/null
from datetime import datetime
import sys

iso = sys.argv[1]
try:
    rt = datetime.fromisoformat(iso)
    print(rt.astimezone().strftime('%a %-I:%M %p'))
except Exception:
    pass
PY
}

# ── Fetch usage (cached) ──
CACHE="/tmp/.claude_usage_cache"

fetch_usage() {
  local CREDS="" TOKEN RESP
  CREDS=$(security find-generic-password -s "Claude Code-credentials" -w 2>/dev/null)
  [ -z "$CREDS" ] && [ -f "$HOME/.claude/.credentials.json" ] && CREDS=$(<"$HOME/.claude/.credentials.json")
  [ -z "$CREDS" ] && return 1
  TOKEN=$(echo "$CREDS" | jq -r '.claudeAiOauth.accessToken // empty' 2>/dev/null)
  [ -z "$TOKEN" ] && return 1
  RESP=$(curl -s --max-time 5 \
    "https://api.anthropic.com/api/oauth/usage" \
    -H "Authorization: Bearer $TOKEN" \
    -H "anthropic-beta: oauth-2025-04-20" \
    -H "Content-Type: application/json" 2>/dev/null)
  echo "$RESP" | jq -e '.five_hour' >/dev/null 2>&1 && echo "$RESP" >"$CACHE"
}

AGE=-1
if [ -f "$CACHE" ]; then
  AGE=$(($(date +%s) - $(stat -f %m "$CACHE" 2>/dev/null || stat -c %Y "$CACHE" 2>/dev/null || echo 0)))
  if [ "$AGE" -gt 60 ]; then
    fetch_usage 2>/dev/null || true
    AGE=$(($(date +%s) - $(stat -f %m "$CACHE" 2>/dev/null || stat -c %Y "$CACHE" 2>/dev/null || echo 0)))
  fi
else
  fetch_usage 2>/dev/null || true
  if [ -f "$CACHE" ]; then
    AGE=$(($(date +%s) - $(stat -f %m "$CACHE" 2>/dev/null || stat -c %Y "$CACHE" 2>/dev/null || echo 0)))
  fi
fi

# ── Parse cache with Python for correct timezone handling ──
SP=0
WP=0
SR=""
WR=""
EU_ENABLED=0
EU_USED=0
EU_LIMIT=0
EU_PCT=0
HAS_NATIVE_USAGE=0
if [ -f "$CACHE" ]; then
  IFS=$'\t' read -r SP WP SR WR EU_ENABLED EU_USED EU_LIMIT EU_PCT < <(python3 -c "
import json, sys
from datetime import datetime, timezone

with open('$CACHE') as f:
    d = json.load(f)

now = datetime.now(timezone.utc)

fh = d.get('five_hour') or {}
sd = d.get('seven_day') or {}

sp = round(fh.get('utilization', 0) or 0)
wp = round(sd.get('utilization', 0) or 0)

sr = ''
fh_reset = fh.get('resets_at', '')
if fh_reset:
    try:
        rt = datetime.fromisoformat(fh_reset)
        diff = rt - now
        secs = int(diff.total_seconds())
        if secs > 0:
            h, m = secs // 3600, (secs % 3600) // 60
            parts = []
            if h > 0:
                parts.append(f'{h} hr')
            if m > 0 or not parts:
                parts.append(f'{m} min')
            sr = ' '.join(parts)
        else:
            sr = 'soon'
    except: pass

wr = ''
sd_reset = sd.get('resets_at', '')
if sd_reset:
    try:
        rt = datetime.fromisoformat(sd_reset)
        local_rt = rt.astimezone()
        wr = local_rt.strftime('%a %-I:%M %p')
    except: pass

extra = d.get('extra_usage') or {}
eu_enabled = 1 if extra.get('is_enabled') else 0
eu_used = round(extra.get('used_credits', 0) or 0)
eu_limit = round(extra.get('monthly_limit', 0) or 0)
eu_pct = round(extra.get('utilization', 0) or 0)

print(f'{sp}\t{wp}\t{sr}\t{wr}\t{eu_enabled}\t{eu_used}\t{eu_limit}\t{eu_pct}')
" 2>/dev/null)
fi

# ── Prefer live stdin usage data when Claude provides it ──
if [ -n "$NATIVE_SP" ] && [ "$NATIVE_SP" != "null" ]; then
  SP=$(printf '%.0f' "$NATIVE_SP" 2>/dev/null || echo "$SP")
  SR=$(format_iso_relative "$NATIVE_SR_AT")
  AGE=0
  HAS_NATIVE_USAGE=1
fi

if [ -n "$NATIVE_WP" ] && [ "$NATIVE_WP" != "null" ]; then
  WP=$(printf '%.0f' "$NATIVE_WP" 2>/dev/null || echo "$WP")
  WR=$(format_iso_local "$NATIVE_WR_AT")
  AGE=0
  HAS_NATIVE_USAGE=1
fi

if [ -n "$NATIVE_EU_ENABLED" ] && [ "$NATIVE_EU_ENABLED" != "null" ]; then
  if [ "$NATIVE_EU_ENABLED" = "true" ]; then
    EU_ENABLED=1
  else
    EU_ENABLED=0
  fi
  [ -n "$NATIVE_EU_USED" ] && [ "$NATIVE_EU_USED" != "null" ] && EU_USED=$(printf '%.0f' "$NATIVE_EU_USED" 2>/dev/null || echo "$EU_USED")
  [ -n "$NATIVE_EU_LIMIT" ] && [ "$NATIVE_EU_LIMIT" != "null" ] && EU_LIMIT=$(printf '%.0f' "$NATIVE_EU_LIMIT" 2>/dev/null || echo "$EU_LIMIT")
  [ -n "$NATIVE_EU_PCT" ] && [ "$NATIVE_EU_PCT" != "null" ] && EU_PCT=$(printf '%.0f' "$NATIVE_EU_PCT" 2>/dev/null || echo "$EU_PCT")
  AGE=0
fi

LIVE_USAGE_OK=0
if [ "$HAS_NATIVE_USAGE" = "1" ] || { [ "$AGE" -ge 0 ] && [ "$AGE" -le 60 ]; }; then
  LIVE_USAGE_OK=1
fi

format_money_from_cents() {
  local cents=${1:-0}
  python3 - "$cents" <<'PY' 2>/dev/null
import sys
cents = float(sys.argv[1] or 0)
value = cents / 100.0
if value.is_integer():
    print(f'${int(value)}')
else:
    print(f'${value:.2f}')
PY
}

# ── Output ──
TOP="${B}${CY}● ${MODEL}${R} ${GR}in${R} ${B}${DIR_NAME}${R}  ${GR}CTX${R} $(bar "$CTX_PCT" 10) ${B}${CTX_PCT}%${R}"

if [ -f "$CACHE" ]; then
  SESSION_COLOR=$(percent_color "$SP")
  WEEK_COLOR=$(percent_color "$WP")
  EXTRA_COLOR=$(percent_color "$EU_PCT")
  UPDATED_TEXT=$(human_age "$AGE")
  EXTRA_USED_FMT=$(format_money_from_cents "$EU_USED")
  EXTRA_LIMIT_FMT=$(format_money_from_cents "$EU_LIMIT")

  LINE1="${B}${BL}Current session${R}"
  [ -n "$SR" ] && LINE1+="  ${SL}Resets in${R} ${WH}${SR}${R}"
  if [ "$LIVE_USAGE_OK" = "1" ]; then
    LINE1+="  ${SESSION_COLOR}${B}${SP}% used${R}"
  else
    LINE1+="  ${GR}usage sync unavailable${R}"
  fi

  if [ "$LIVE_USAGE_OK" = "1" ]; then
    LINE2="  $(bar "$SP" 18)"
  else
    LINE2="  ${D}Using cached reset info only${R}"
  fi

  LINE3="${B}${BL}Weekly limits${R}"
  LINE4="  ${GR}All models${R}"
  [ -n "$WR" ] && LINE4+="  ${SL}Resets${R} ${WH}${WR}${R}"
  if [ "$LIVE_USAGE_OK" = "1" ]; then
    LINE4+="  ${WEEK_COLOR}${B}${WP}% used${R}"
  else
    LINE4+="  ${GR}usage sync unavailable${R}"
  fi

  if [ "$LIVE_USAGE_OK" = "1" ]; then
    LINE5="  $(bar "$WP" 18)"
  else
    LINE5="  ${D}Open Claude's usage panel for live percentages${R}"
  fi

  LINE6=""
  if [ "$EU_ENABLED" = "1" ] && [ "$EU_LIMIT" -gt 0 ]; then
    LINE6="${B}${BL}Extra usage${R}  ${GR}${EXTRA_USED_FMT}/${EXTRA_LIMIT_FMT}${R}  ${EXTRA_COLOR}${B}${EU_PCT}% used${R}"
    LINE7="  $(bar "$EU_PCT" 18)"
    LINE8="${GR}Last updated:${R} ${UPDATED_TEXT}"
    echo -e "${TOP}\n${LINE1}\n${LINE2}\n${LINE3}\n${LINE4}\n${LINE5}\n${LINE6}\n${LINE7}\n${LINE8}"
  else
    LINE6="${GR}Last updated:${R} ${UPDATED_TEXT}"
    echo -e "${TOP}\n${LINE1}\n${LINE2}\n${LINE3}\n${LINE4}\n${LINE5}\n${LINE6}"
  fi
else
  echo -e "$TOP"
fi
