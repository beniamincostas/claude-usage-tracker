#!/bin/bash
umask 077  # Files created by this script are user-only (0600)
input=$(cat)

# Parse all input fields in one jq call (one field per line preserves empty fields)
{
  IFS= read -r MODEL
  IFS= read -r MODEL_ID
  IFS= read -r DIR
  IFS= read -r SESSION_ID
  IFS= read -r SESSION_NAME
  IFS= read -r VIM_MODE
  IFS= read -r AGENT_NAME
  IFS= read -r WORKTREE_BRANCH
  IFS= read -r CTX_PCT
  IFS= read -r TOTAL_IN
  IFS= read -r TOTAL_OUT
  IFS= read -r CACHE_WRITE
  IFS= read -r CACHE_READ
  IFS= read -r DAY_PCT_RAW
  IFS= read -r DAY_RESETS
  IFS= read -r WEEK_PCT_RAW
  IFS= read -r WEEK_RESETS
} < <(printf '%s' "$input" | jq -r '
  (.model.display_name // ""),
  (.model.id // "unknown"),
  (.workspace.current_dir // ""),
  (.session_id // "unknown"),
  (.session_name // ""),
  (.vim.mode // ""),
  (.agent.name // ""),
  (.worktree.branch // ""),
  ((.context_window.used_percentage // 0) | floor | tostring),
  (.context_window.total_input_tokens // 0 | tostring),
  (.context_window.total_output_tokens // 0 | tostring),
  (.context_window.current_usage.cache_creation_input_tokens // 0 | tostring),
  (.context_window.current_usage.cache_read_input_tokens // 0 | tostring),
  (.rate_limits.five_hour.used_percentage // ""),
  (.rate_limits.five_hour.resets_at | if . == null then "" else tostring end),
  (.rate_limits.seven_day.used_percentage // ""),
  (.rate_limits.seven_day.resets_at | if . == null then "" else tostring end)
')

# Convert ISO 8601 resets_at to epoch seconds (handles both epoch ints and ISO strings)
iso_to_epoch() {
  local val="$1"
  [ -z "$val" ] && echo "" && return
  # Already a number? Pass through
  if [[ "$val" =~ ^[0-9]+$ ]]; then echo "$val"; return; fi
  # Strip fractional seconds and timezone offset for macOS date parsing
  local clean="${val%%.*}"
  clean="${clean%%+*}"  # Strip +HH:MM timezone offset
  clean="${clean%%Z*}"  # Strip trailing Z
  # macOS date: parse as UTC (-u flag)
  date -u -jf "%Y-%m-%dT%H:%M:%S" "$clean" +%s 2>/dev/null && return
  # GNU date fallback (handles full ISO 8601 natively)
  date -d "$val" +%s 2>/dev/null && return
  echo ""
}
DAY_RESETS=$(iso_to_epoch "$DAY_RESETS")
WEEK_RESETS=$(iso_to_epoch "$WEEK_RESETS")

# If display name not provided, derive from model ID
if [ -z "$MODEL" ] || [ "$MODEL" = "null" ]; then
  MODEL=$(printf '%s' "$MODEL_ID" | sed \
    -e 's/^claude-//' \
    -e 's/-[0-9]\{8,\}$//' \
    -e 's/-\([0-9]\)-\([0-9][0-9]*\)$/ \1.\2/' \
    -e 's/-\([0-9][0-9]*\)$/ \1/' | \
    awk '{for(i=1;i<=NF;i++){$i=toupper(substr($i,1,1))substr($i,2)};print}')
fi

CYAN='\033[36m'; GREEN='\033[32m'; YELLOW='\033[33m'; RED='\033[31m'; BLUE='\033[34m'; MAGENTA='\033[35m'; RESET='\033[0m'

# --- helper: build a 10-char bar from an integer percentage ---
make_bar() {
  local pct=$1
  [ "$pct" -gt 100 ] && pct=100
  local filled=$((pct / 10))
  local empty=$((10 - filled))
  printf -v f "%${filled}s"; printf -v p "%${empty}s"
  echo "${f// /█}${p// /░}"
}

# --- helper: format token count as compact string (e.g. 1.2M, 120k) ---
fmt_tokens() {
  echo "$1" | awk '{
    if ($1 >= 1000000) printf "%.1fM", $1/1000000
    else if ($1 >= 1000) printf "%dk", int($1/1000+0.5)
    else printf "%d", $1
  }'
}

# -----------------------------------------------------------------------
# Persistent monthly + weekly token tracking
# -----------------------------------------------------------------------
USAGE_FILE="$HOME/.claude/monthly_usage.json"
USAGE_LOCK="$HOME/.claude/.monthly_usage.lock"
NOW_EPOCH=$(date +%s)
CURRENT_MONTH=$(date +%Y-%m)

# Acquire exclusive lock (mkdir is atomic); retry up to 2 seconds
_lock_attempts=0
while ! mkdir "$USAGE_LOCK" 2>/dev/null; do
  _lock_attempts=$((_lock_attempts + 1))
  if [ "$_lock_attempts" -ge 20 ]; then
    # Stale lock? Remove if older than 10 seconds
    if [ -d "$USAGE_LOCK" ]; then
      _lock_age=$(( $(date +%s) - $(stat -f %m "$USAGE_LOCK" 2>/dev/null || echo 0) ))
      if [ "$_lock_age" -gt 10 ]; then
        rmdir "$USAGE_LOCK" 2>/dev/null
        mkdir "$USAGE_LOCK" 2>/dev/null && break
      fi
    fi
    exit 0  # Skip this update rather than risk data corruption
  fi
  sleep 0.1
done
trap 'rmdir "$USAGE_LOCK" 2>/dev/null' EXIT

# Read existing log or start fresh; guard against malformed JSON
if [ -f "$USAGE_FILE" ]; then
  LOG=$(jq '.' "$USAGE_FILE" 2>/dev/null)
  [ -z "$LOG" ] && LOG='{}'
else
  LOG='{}'
fi

# Read all LOG fields in one jq call (one field per line preserves empty fields)
CURRENT_DATE=$(date +%Y-%m-%d)
{
  IFS= read -r STORED_MONTH
  IFS= read -r STORED_WEEK_RESETS
  IFS= read -r STORED_DAY_RESETS
  IFS= read -r MONTH_IN
  IFS= read -r MONTH_OUT
  IFS= read -r WEEK_IN
  IFS= read -r WEEK_OUT
  IFS= read -r DAY_IN
  IFS= read -r DAY_OUT
  IFS= read -r STORED_CAL_DATE
  IFS= read -r CAL_DAY_IN
  IFS= read -r CAL_DAY_OUT
  IFS= read -r SESS_PREV_IN
  IFS= read -r SESS_PREV_OUT
  IFS= read -r SESS_PREV_CACHE_WRITE
  IFS= read -r SESS_PREV_CACHE_READ
  IFS= read -r SESS_LOG_MODEL
} < <(printf '%s' "$LOG" | jq -r --arg sid "$SESSION_ID" '
  (.billing_month // ""),
  (.week_resets_at // 0 | tostring),
  (.day_resets_at // 0 | tostring),
  (.month_input_tokens // 0 | tostring),
  (.month_output_tokens // 0 | tostring),
  (.week_input_tokens // 0 | tostring),
  (.week_output_tokens // 0 | tostring),
  (.day_input_tokens // 0 | tostring),
  (.day_output_tokens // 0 | tostring),
  (.cal_date // ""),
  (.cal_day_input_tokens // 0 | tostring),
  (.cal_day_output_tokens // 0 | tostring),
  (.sessions[$sid].input_tokens // 0 | tostring),
  (.sessions[$sid].output_tokens // 0 | tostring),
  (.sessions[$sid].cache_write_tokens // 0 | tostring),
  (.sessions[$sid].cache_read_tokens // 0 | tostring),
  (.sessions[$sid].model // "")
')

# If the model changed mid-session, set baseline to current totals so DELTA=0.
# Only genuinely new tokens after the switch will flow into the new model.
# The old model's counters remain correct (they captured everything up to the switch).
if [ -n "$SESS_LOG_MODEL" ] && [ "$SESS_LOG_MODEL" != "$MODEL_ID" ]; then
  SESS_PREV_IN=$TOTAL_IN
  SESS_PREV_OUT=$TOTAL_OUT
  SESS_PREV_CACHE_WRITE=$CACHE_WRITE
  SESS_PREV_CACHE_READ=$CACHE_READ
fi

# --- Reset month counters if billing month rolled over ---
# IMPORTANT: Only zero the period counters. Do NOT replace LOG or clear sessions.
# The current session will re-baseline naturally because SESS_PREV_IN is set to 0,
# meaning the full TOTAL_IN/OUT will be re-added as a fresh delta.
# Sessions from the old month are left intact temporarily; they will be pruned below.
if [ "$STORED_MONTH" != "$CURRENT_MONTH" ]; then
  MONTH_IN=0
  MONTH_OUT=0
  WEEK_IN=0
  WEEK_OUT=0
  DAY_IN=0
  DAY_OUT=0
  CAL_DAY_IN=0
  CAL_DAY_OUT=0
  # Re-baseline the current session from scratch (delta = TOTAL_IN - 0 = all tokens)
  SESS_PREV_IN=0
  SESS_PREV_OUT=0
  SESS_PREV_CACHE_WRITE=0
  SESS_PREV_CACHE_READ=0
  # Reset stored resets_at so period resets don't double-fire
  STORED_WEEK_RESETS="0"
  STORED_DAY_RESETS="0"
  # Zero all per-model counters in LOG (keep sessions object intact)
  LOG=$(echo "$LOG" | jq '
    .week_resets_at = 0 | .day_resets_at = 0 |
    if .models then
      .models |= map_values(
        .month_input_tokens          = 0 |
        .month_output_tokens         = 0 |
        .week_input_tokens           = 0 |
        .week_output_tokens          = 0 |
        .day_input_tokens            = 0 |
        .day_output_tokens           = 0 |
        .cal_day_input_tokens        = 0 |
        .cal_day_output_tokens       = 0 |
        .month_cache_write_tokens    = 0 |
        .month_cache_read_tokens     = 0 |
        .week_cache_write_tokens     = 0 |
        .week_cache_read_tokens      = 0 |
        .day_cache_write_tokens      = 0 |
        .day_cache_read_tokens       = 0 |
        .cal_day_cache_write_tokens  = 0 |
        .cal_day_cache_read_tokens   = 0
      )
    else . end
  ')
fi

# --- Reset calendar-day counters if the date has changed ---
# Only zeros cal_day counters. Does NOT touch week/month counters or sessions.
if [ "$STORED_CAL_DATE" != "$CURRENT_DATE" ]; then
  CAL_DAY_IN=0
  CAL_DAY_OUT=0
  LOG=$(echo "$LOG" | jq 'if .models then .models |= map_values(.cal_day_input_tokens = 0 | .cal_day_output_tokens = 0 | .cal_day_cache_write_tokens = 0 | .cal_day_cache_read_tokens = 0) else . end')
fi

# --- Reset week counters if the 7-day window has reset ---
# Only zeros week counters. Does NOT touch month counters or sessions.
EFFECTIVE_WEEK_RESETS="${WEEK_RESETS:-$STORED_WEEK_RESETS}"
if [ -n "$EFFECTIVE_WEEK_RESETS" ] && [ "$EFFECTIVE_WEEK_RESETS" != "0" ]; then
  if [ -n "$WEEK_RESETS" ] && [ "$WEEK_RESETS" != "$STORED_WEEK_RESETS" ] && [ "$STORED_WEEK_RESETS" != "0" ] && [ "$NOW_EPOCH" -ge "$STORED_WEEK_RESETS" ]; then
    WEEK_IN=0
    WEEK_OUT=0
    # Zero per-model weekly counts only; leave month/day/sessions untouched
    LOG=$(echo "$LOG" | jq 'if .models then .models |= map_values(.week_input_tokens = 0 | .week_output_tokens = 0 | .week_cache_write_tokens = 0 | .week_cache_read_tokens = 0) else . end')
  fi
fi

# --- Reset daily (5h) counters if the 5-hour window has reset ---
# Only zeros day counters. Does NOT touch cal_day, week, month counters or sessions.
EFFECTIVE_DAY_RESETS="${DAY_RESETS:-$STORED_DAY_RESETS}"
if [ -n "$EFFECTIVE_DAY_RESETS" ] && [ "$EFFECTIVE_DAY_RESETS" != "0" ]; then
  if [ -n "$DAY_RESETS" ] && [ "$DAY_RESETS" != "$STORED_DAY_RESETS" ] && [ "$STORED_DAY_RESETS" != "0" ] && [ "$NOW_EPOCH" -ge "$STORED_DAY_RESETS" ]; then
    DAY_IN=0
    DAY_OUT=0
    # Zero per-model 5h counts only; leave cal_day/week/month/sessions untouched
    LOG=$(echo "$LOG" | jq 'if .models then .models |= map_values(.day_input_tokens = 0 | .day_output_tokens = 0 | .day_cache_write_tokens = 0 | .day_cache_read_tokens = 0) else . end')
  fi
fi

# --- Compute token delta for this session since last statusline call ---
DELTA_IN=$(( TOTAL_IN  - SESS_PREV_IN  ))
DELTA_OUT=$(( TOTAL_OUT - SESS_PREV_OUT ))
DELTA_CACHE_WRITE=$(( CACHE_WRITE - SESS_PREV_CACHE_WRITE ))
DELTA_CACHE_READ=$(( CACHE_READ - SESS_PREV_CACHE_READ ))
[ "$DELTA_IN"  -lt 0 ] && DELTA_IN=0
[ "$DELTA_OUT" -lt 0 ] && DELTA_OUT=0
[ "$DELTA_CACHE_WRITE" -lt 0 ] && DELTA_CACHE_WRITE=0
[ "$DELTA_CACHE_READ"  -lt 0 ] && DELTA_CACHE_READ=0

MONTH_IN=$(( MONTH_IN  + DELTA_IN  ))
MONTH_OUT=$(( MONTH_OUT + DELTA_OUT ))
WEEK_IN=$(( WEEK_IN   + DELTA_IN  ))
WEEK_OUT=$(( WEEK_OUT  + DELTA_OUT ))
DAY_IN=$(( DAY_IN    + DELTA_IN  ))
DAY_OUT=$(( DAY_OUT   + DELTA_OUT ))
CAL_DAY_IN=$(( CAL_DAY_IN  + DELTA_IN  ))
CAL_DAY_OUT=$(( CAL_DAY_OUT + DELTA_OUT ))

# Read all per-model accumulated values in one jq call
{
  IFS= read -r MODEL_MONTH_IN_PREV
  IFS= read -r MODEL_MONTH_OUT_PREV
  IFS= read -r MODEL_WEEK_IN_PREV
  IFS= read -r MODEL_WEEK_OUT_PREV
  IFS= read -r MODEL_DAY_IN_PREV
  IFS= read -r MODEL_DAY_OUT_PREV
  IFS= read -r MODEL_CAL_DAY_IN_PREV
  IFS= read -r MODEL_CAL_DAY_OUT_PREV
  IFS= read -r MODEL_MONTH_CW_PREV
  IFS= read -r MODEL_MONTH_CR_PREV
  IFS= read -r MODEL_WEEK_CW_PREV
  IFS= read -r MODEL_WEEK_CR_PREV
  IFS= read -r MODEL_DAY_CW_PREV
  IFS= read -r MODEL_DAY_CR_PREV
  IFS= read -r MODEL_CAL_DAY_CW_PREV
  IFS= read -r MODEL_CAL_DAY_CR_PREV
} < <(printf '%s' "$LOG" | jq -r --arg mid "$MODEL_ID" '
  (.models[$mid].month_input_tokens // 0 | tostring),
  (.models[$mid].month_output_tokens // 0 | tostring),
  (.models[$mid].week_input_tokens // 0 | tostring),
  (.models[$mid].week_output_tokens // 0 | tostring),
  (.models[$mid].day_input_tokens // 0 | tostring),
  (.models[$mid].day_output_tokens // 0 | tostring),
  (.models[$mid].cal_day_input_tokens // 0 | tostring),
  (.models[$mid].cal_day_output_tokens // 0 | tostring),
  (.models[$mid].month_cache_write_tokens // 0 | tostring),
  (.models[$mid].month_cache_read_tokens // 0 | tostring),
  (.models[$mid].week_cache_write_tokens // 0 | tostring),
  (.models[$mid].week_cache_read_tokens // 0 | tostring),
  (.models[$mid].day_cache_write_tokens // 0 | tostring),
  (.models[$mid].day_cache_read_tokens // 0 | tostring),
  (.models[$mid].cal_day_cache_write_tokens // 0 | tostring),
  (.models[$mid].cal_day_cache_read_tokens // 0 | tostring)
')

MODEL_MONTH_IN=$(( MODEL_MONTH_IN_PREV  + DELTA_IN  ))
MODEL_MONTH_OUT=$(( MODEL_MONTH_OUT_PREV + DELTA_OUT ))
MODEL_WEEK_IN=$(( MODEL_WEEK_IN_PREV   + DELTA_IN  ))
MODEL_WEEK_OUT=$(( MODEL_WEEK_OUT_PREV  + DELTA_OUT ))
MODEL_DAY_IN=$(( MODEL_DAY_IN_PREV  + DELTA_IN  ))
MODEL_DAY_OUT=$(( MODEL_DAY_OUT_PREV + DELTA_OUT ))
MODEL_CAL_DAY_IN=$(( MODEL_CAL_DAY_IN_PREV  + DELTA_IN  ))
MODEL_CAL_DAY_OUT=$(( MODEL_CAL_DAY_OUT_PREV + DELTA_OUT ))
MODEL_MONTH_CW=$(( MODEL_MONTH_CW_PREV + DELTA_CACHE_WRITE ))
MODEL_MONTH_CR=$(( MODEL_MONTH_CR_PREV + DELTA_CACHE_READ ))
MODEL_WEEK_CW=$(( MODEL_WEEK_CW_PREV + DELTA_CACHE_WRITE ))
MODEL_WEEK_CR=$(( MODEL_WEEK_CR_PREV + DELTA_CACHE_READ ))
MODEL_DAY_CW=$(( MODEL_DAY_CW_PREV + DELTA_CACHE_WRITE ))
MODEL_DAY_CR=$(( MODEL_DAY_CR_PREV + DELTA_CACHE_READ ))
MODEL_CAL_DAY_CW=$(( MODEL_CAL_DAY_CW_PREV + DELTA_CACHE_WRITE ))
MODEL_CAL_DAY_CR=$(( MODEL_CAL_DAY_CR_PREV + DELTA_CACHE_READ ))

# --- Persist updated log ---
NEW_WEEK_RESETS="${WEEK_RESETS:-$STORED_WEEK_RESETS}"
NEW_DAY_RESETS="${DAY_RESETS:-$STORED_DAY_RESETS}"
jq -n \
  --arg  billing_month         "$CURRENT_MONTH" \
  --argjson month_in           "$MONTH_IN" \
  --argjson month_out          "$MONTH_OUT" \
  --argjson week_in            "$WEEK_IN" \
  --argjson week_out           "$WEEK_OUT" \
  --argjson day_in             "$DAY_IN" \
  --argjson day_out            "$DAY_OUT" \
  --arg    week_resets_at      "${NEW_WEEK_RESETS:-0}" \
  --arg    day_resets_at       "${NEW_DAY_RESETS:-0}" \
  --arg    cal_date            "$CURRENT_DATE" \
  --argjson cal_day_in         "$CAL_DAY_IN" \
  --argjson cal_day_out        "$CAL_DAY_OUT" \
  --arg    sid                 "$SESSION_ID" \
  --arg    mid                 "$MODEL_ID" \
  --argjson sess_in            "$TOTAL_IN" \
  --argjson sess_out           "$TOTAL_OUT" \
  --argjson sess_cw            "$CACHE_WRITE" \
  --argjson sess_cr            "$CACHE_READ" \
  --argjson model_month_in     "$MODEL_MONTH_IN" \
  --argjson model_month_out    "$MODEL_MONTH_OUT" \
  --argjson model_week_in      "$MODEL_WEEK_IN" \
  --argjson model_week_out     "$MODEL_WEEK_OUT" \
  --argjson model_day_in       "$MODEL_DAY_IN" \
  --argjson model_day_out      "$MODEL_DAY_OUT" \
  --argjson model_cal_day_in   "$MODEL_CAL_DAY_IN" \
  --argjson model_cal_day_out  "$MODEL_CAL_DAY_OUT" \
  --argjson model_month_cw     "$MODEL_MONTH_CW" \
  --argjson model_month_cr     "$MODEL_MONTH_CR" \
  --argjson model_week_cw      "$MODEL_WEEK_CW" \
  --argjson model_week_cr      "$MODEL_WEEK_CR" \
  --argjson model_day_cw       "$MODEL_DAY_CW" \
  --argjson model_day_cr       "$MODEL_DAY_CR" \
  --argjson model_cal_day_cw   "$MODEL_CAL_DAY_CW" \
  --argjson model_cal_day_cr   "$MODEL_CAL_DAY_CR" \
  --arg    day_used_pct        "${DAY_PCT_RAW:-}" \
  --arg    week_used_pct       "${WEEK_PCT_RAW:-}" \
  --argjson existing           "$LOG" \
  '{
    billing_month:          $billing_month,
    month_input_tokens:     $month_in,
    month_output_tokens:    $month_out,
    week_input_tokens:      $week_in,
    week_output_tokens:     $week_out,
    day_input_tokens:       $day_in,
    day_output_tokens:      $day_out,
    week_resets_at:         (if $week_resets_at == "" then 0 else ($week_resets_at | tonumber) end),
    day_resets_at:          (if $day_resets_at == "" then 0 else ($day_resets_at | tonumber) end),
    cal_date:               $cal_date,
    cal_day_input_tokens:   $cal_day_in,
    cal_day_output_tokens:  $cal_day_out,
    day_used_pct:           (if $day_used_pct == "" then null else ($day_used_pct | tonumber) end),
    week_used_pct:          (if $week_used_pct == "" then null else ($week_used_pct | tonumber) end),
    current_session_id:     $sid,
    models: (
      (($existing.models // {}) + {
        ($mid): (
          (($existing.models // {})[$mid] // {}) + {
            month_input_tokens:         $model_month_in,
            month_output_tokens:        $model_month_out,
            week_input_tokens:          $model_week_in,
            week_output_tokens:         $model_week_out,
            day_input_tokens:           $model_day_in,
            day_output_tokens:          $model_day_out,
            cal_day_input_tokens:       $model_cal_day_in,
            cal_day_output_tokens:      $model_cal_day_out,
            month_cache_write_tokens:   $model_month_cw,
            month_cache_read_tokens:    $model_month_cr,
            week_cache_write_tokens:    $model_week_cw,
            week_cache_read_tokens:     $model_week_cr,
            day_cache_write_tokens:     $model_day_cw,
            day_cache_read_tokens:      $model_day_cr,
            cal_day_cache_write_tokens: $model_cal_day_cw,
            cal_day_cache_read_tokens:  $model_cal_day_cr
          }
        )
      })
    ),
    sessions: (
      (($existing.sessions // {}) + {
        ($sid): {model: $mid, input_tokens: $sess_in, output_tokens: $sess_out, cache_write_tokens: $sess_cw, cache_read_tokens: $sess_cr}
      })
      # Prune sessions: remove zero-token entries, keep last 50, but always preserve current session.
      | to_entries
      | map(select((.value.input_tokens // 0) > 0 or (.value.output_tokens // 0) > 0))
      | (map(select(.key == $sid))) as $current
      | map(select(.key != $sid))
      | if length > 49 then .[(length - 49):] else . end
      | . + $current
      | from_entries
    )
  }' > "${USAGE_FILE}.tmp" && mv "${USAGE_FILE}.tmp" "$USAGE_FILE"

# -----------------------------------------------------------------------
# Column layout
#   Left area : label(9) + sp(1) + bar(10) + sp(1) + pct(4) = 25 chars total
#   sep       : " │ "
#   InTok     : 13 chars right-aligned
#   InCst     : 10 chars right-aligned
#   sep       : " │ "
#   OutTok    : 13 chars right-aligned
#   OutCst    : 10 chars right-aligned
#   sep       : " │ "
#   Total     : 10 chars right-aligned
#
#   Model rows span the full 25-char left area so the │ stays aligned.
# -----------------------------------------------------------------------
LEFT_AREA=25  # label(9) + sp(1) + bar(10) + sp(1) + pct(4)

# --- helper: colorize a pre-padded string without affecting width ---
colorize() {
  printf '%s%s%s' "$1" "$2" "$RESET"
}

# --- helper: print one data row ---
# Arguments: label bar_raw bar_color pct_raw in_tok ignored out_tok ignored total [trail]
print_row() {
  local label="$1" bar_raw="$2" bar_color="$3" pct_raw="$4"
  local in_tok="$5" out_tok="$7" total="$9"
  local trail="${10:-}"

  local label_f; printf -v label_f "%-9s" "$label"

  local bar_f pct_f
  if [ -n "$pct_raw" ]; then
    printf -v pct_f "%3d%%" "$pct_raw"
    bar_f=$(colorize "$bar_color" "$bar_raw")
  elif [ -n "$bar_raw" ] && [ -n "$bar_color" ]; then
    bar_f=$(colorize "$bar_color" "$bar_raw")
    pct_f="    "
  else
    bar_f="          "
    pct_f="    "
  fi

  local in_tok_f out_tok_f total_f
  printf -v in_tok_f   "%13s" "$in_tok"
  printf -v out_tok_f  "%13s" "$out_tok"
  printf -v total_f    "%10s" "$total"

  local total_c
  total_c=$(colorize "$YELLOW" "$total_f")

  local trail_str=""; [ -n "$trail" ] && trail_str="  ${trail}"

  echo -e "${label_f} ${bar_f} ${pct_f} │ ${in_tok_f} │ ${out_tok_f} │ ${total_c}${trail_str}"
}

# --- helper: print one model breakdown row ---
# The model name spans the full LEFT_AREA (25 chars) so │ stays aligned.
# Arguments: prefix short_name in_tok ignored out_tok ignored total
print_model_row() {
  local prefix="$1" short_name="$2"
  local in_tok="$3" out_tok="$5" total="$7"

  local raw_label="${prefix} ${short_name}"
  local raw_len=${#raw_label}
  local pad_needed=$(( LEFT_AREA - raw_len ))
  local pad_str=""
  [ "$pad_needed" -gt 0 ] && printf -v pad_str "%${pad_needed}s" ""

  local colored_label="${CYAN}${prefix}${RESET} ${short_name}"

  local in_tok_f out_tok_f total_f
  printf -v in_tok_f   "%13s" "$in_tok"
  printf -v out_tok_f  "%13s" "$out_tok"
  printf -v total_f    "%10s" "$total"

  local total_c
  total_c=$(colorize "$YELLOW" "$total_f")

  echo -e "${colored_label}${pad_str} │ ${in_tok_f} │ ${out_tok_f} │ ${total_c}"
}

# -----------------------------------------------------------------------
# Per-model breakdown helper
# Reads the saved log file and emits indented lines for each model that
# has non-zero usage in the requested period (week or month).
# Usage: model_breakdown_lines <period>   where period = "week" | "month" | "day"
# -----------------------------------------------------------------------
model_breakdown_lines() {
  local period="$1"   # "week", "month", "day", or "cal_day"
  local in_key="${period}_input_tokens"
  local out_key="${period}_output_tokens"
  local cw_key="${period}_cache_write_tokens"
  local cr_key="${period}_cache_read_tokens"

  # Collect models with non-zero usage into an array of "id:in:out:cw:cr" strings
  local entries=()
  while IFS= read -r line; do
    entries+=("$line")
  done < <(
    jq -r --arg ik "$in_key" --arg ok "$out_key" --arg cwk "$cw_key" --arg crk "$cr_key" '
      .models // {} |
      to_entries[] |
      select((.value[$ik] // 0) > 0 or (.value[$ok] // 0) > 0 or (.value[$cwk] // 0) > 0 or (.value[$crk] // 0) > 0) |
      "\(.key):\(.value[$ik] // 0):\(.value[$ok] // 0):\(.value[$cwk] // 0):\(.value[$crk] // 0)"
    ' "$USAGE_FILE" 2>/dev/null
  )

  local n=${#entries[@]}
  [ "$n" -eq 0 ] && return

  local i=0
  for entry in "${entries[@]}"; do
    local mid_entry="${entry%%:*}"
    local rest="${entry#*:}"
    local min="${rest%%:*}"; rest="${rest#*:}"
    local mout="${rest%%:*}"; rest="${rest#*:}"
    local mcw="${rest%%:*}"
    local mcr="${rest#*:}"

    local min_fmt mout_fmt mtotal mtotal_fmt
    min_fmt=$(fmt_tokens "$min")
    mout_fmt=$(fmt_tokens "$mout")
    mtotal=$(( min + mout ))
    mtotal_fmt=$(fmt_tokens "$mtotal")

    # Derive a short display name from the model ID
    # e.g. claude-sonnet-4-6 -> Sonnet 4.6 ; claude-opus-4-5 -> Opus 4.5
    local short_name
    # Build a human-readable short name from the model ID, e.g.:
    #   claude-opus-4-6            -> Opus 4.6
    #   claude-sonnet-4-6          -> Sonnet 4.6
    #   claude-haiku-4-5           -> Haiku 4.5
    #   claude-opus-4              -> Opus 4   (no minor version)
    #   claude-3-5-sonnet-20241022 -> 3.5 Sonnet
    #   claude-3-7-sonnet-...      -> 3.7 Sonnet
    #   claude-3-opus-...          -> 3 Opus
    short_name=$(echo "$mid_entry" | sed \
      -e 's/^claude-//' \
      -e 's/-[0-9]\{8,\}$//' \
      -e 's/-\([0-9]\)-\([0-9][0-9]*\)$/ \1.\2/' \
      -e 's/-\([0-9][0-9]*\)$/ \1/' \
      -e 's/^\([0-9]\)-\([0-9]\)-/\1.\2 /' | \
      awk '{for(i=1;i<=NF;i++){$i=toupper(substr($i,1,1))substr($i,2)};print}')

    # Tree prefix
    local prefix
    i=$(( i + 1 ))
    if [ "$i" -lt "$n" ]; then
      prefix="  ├─"
    else
      prefix="  └─"
    fi

    print_model_row "$prefix" "$short_name" \
      "$min_fmt" "" \
      "$mout_fmt" "" \
      "$mtotal_fmt"
  done
}

# -----------------------------------------------------------------------
# Cost calculations (session uses current model pricing)
# Cache write tokens are billed at 1.25× input price; cache read at 0.1× input price.
# -----------------------------------------------------------------------
# Format helpers
# -----------------------------------------------------------------------
TOTAL_IN_FMT=$(fmt_tokens      "$TOTAL_IN");      TOTAL_OUT_FMT=$(fmt_tokens      "$TOTAL_OUT")
DAY_IN_FMT=$(fmt_tokens        "$DAY_IN");        DAY_OUT_FMT=$(fmt_tokens        "$DAY_OUT");        DAY_TOTAL_FMT=$(fmt_tokens        "$((DAY_IN + DAY_OUT))")
CAL_DAY_IN_FMT=$(fmt_tokens    "$CAL_DAY_IN");    CAL_DAY_OUT_FMT=$(fmt_tokens    "$CAL_DAY_OUT");    CAL_DAY_TOTAL_FMT=$(fmt_tokens    "$((CAL_DAY_IN + CAL_DAY_OUT))")
WEEK_IN_FMT=$(fmt_tokens       "$WEEK_IN");       WEEK_OUT_FMT=$(fmt_tokens       "$WEEK_OUT");       WEEK_TOTAL_FMT=$(fmt_tokens       "$((WEEK_IN + WEEK_OUT))")
MONTH_IN_FMT=$(fmt_tokens      "$MONTH_IN");      MONTH_OUT_FMT=$(fmt_tokens      "$MONTH_OUT");      MONTH_TOTAL_FMT=$(fmt_tokens      "$((MONTH_IN + MONTH_OUT))")

# -----------------------------------------------------------------------
# Context bar
# -----------------------------------------------------------------------
if [ "$CTX_PCT" -ge 90 ]; then CTX_COLOR="$RED"
elif [ "$CTX_PCT" -ge 70 ]; then CTX_COLOR="$YELLOW"
else CTX_COLOR="$GREEN"; fi
CTX_BAR=$(make_bar "$CTX_PCT")

GIT_BRANCH=""
git -C "$DIR" rev-parse --git-dir > /dev/null 2>&1 && \
  GIT_BRANCH=$(git -C "$DIR" branch --show-current 2>/dev/null)

# Prefer worktree branch if available
DISPLAY_BRANCH="${WORKTREE_BRANCH:-$GIT_BRANCH}"

# -----------------------------------------------------------------------
# Output
# -----------------------------------------------------------------------

# --- 1. Session free-form line (above the table) ---
printf '%b' "${CYAN}[${MODEL}]${RESET}"
# Agent label
[ -n "$AGENT_NAME" ] && printf '%b' " ${MAGENTA}(${AGENT_NAME})${RESET}"
# Vim mode
[ -n "$VIM_MODE" ] && printf '%b' " ${YELLOW}[${VIM_MODE}]${RESET}"
# Directory / session name
if [ -n "$SESSION_NAME" ]; then
  printf '%b' " ${SESSION_NAME}"
else
  printf '%b' " 📁 ${DIR##*/}"
fi
# Git / worktree branch
[ -n "$DISPLAY_BRANCH" ] && printf '%b' " | 🌿 ${DISPLAY_BRANCH}"
printf '%b' " | $(colorize "$CTX_COLOR" "${CTX_BAR}") ${CTX_PCT}%"
printf '%b' " | 📥 ${TOTAL_IN_FMT} 📤 ${TOTAL_OUT_FMT}\n"

# --- 2. Table header ---
# left area: label(9) + sp(1) + bar(10) + sp(1) + pct(4) = 25 chars, matching data rows
printf -v HDR_PERIOD "%-9s" "Period"
printf -v HDR_BAR    "%10s" "Bar"
printf -v HDR_PCT    "%4s"  "%"
printf -v HDR_INTOK  "%13s" "In tokens"
printf -v HDR_OUTTOK "%13s" "Out tokens"
printf -v HDR_TOTAL  "%10s" "Total"
echo -e "${HDR_PERIOD} ${HDR_BAR} ${HDR_PCT} │ ${HDR_INTOK} │ ${HDR_OUTTOK} │ ${HDR_TOTAL}"

# --- 3. 5-hour / rate-limit row (only when data is available) ---
if [ -n "$DAY_PCT_RAW" ]; then
  DAY_PCT=$(echo "$DAY_PCT_RAW" | cut -d. -f1)
  [ "$DAY_PCT" -gt 100 ] && DAY_PCT=100
  # If server reports 0% (Enterprise plans with very high limits), fall back to
  # 5h tokens as % of today's total so the bar still shows meaningful activity
  if [ "$DAY_PCT" -eq 0 ] && [ "$CAL_DAY_IN" -gt 0 ]; then
    DAY_PCT=$(awk "BEGIN {p=int($DAY_IN/$CAL_DAY_IN*100); if(p>100)p=100; print p}")
  fi
  if [ "$DAY_PCT" -ge 90 ]; then DAY_COLOR="$RED"
  elif [ "$DAY_PCT" -ge 70 ]; then DAY_COLOR="$YELLOW"
  else DAY_COLOR="$BLUE"; fi

  DAY_BAR=$(make_bar "$DAY_PCT")

  DAY_RESET_STR=""
  if [ -n "$DAY_RESETS" ] && [[ "$DAY_RESETS" =~ ^[0-9]+$ ]]; then
    DIFF=$((DAY_RESETS - NOW_EPOCH))
    if [ "$DIFF" -gt 0 ]; then
      RH=$(( DIFF / 3600 ))
      RM=$(( (DIFF % 3600) / 60 ))
      DAY_RESET_STR="resets in ${RH}h ${RM}m"
    fi
  fi

  print_row "5h" "$DAY_BAR" "$DAY_COLOR" "$DAY_PCT" \
    "$DAY_IN_FMT"  "" \
    "$DAY_OUT_FMT" "" \
    "$DAY_TOTAL_FMT" "$DAY_RESET_STR"
fi

# --- 4. Weekly rate limit (only when data is available) ---
if [ -n "$WEEK_PCT_RAW" ]; then
  WEEK_PCT=$(echo "$WEEK_PCT_RAW" | cut -d. -f1)
  [ "$WEEK_PCT" -gt 100 ] && WEEK_PCT=100
  if [ "$WEEK_PCT" -ge 90 ]; then WEEK_COLOR="$RED"
  elif [ "$WEEK_PCT" -ge 70 ]; then WEEK_COLOR="$YELLOW"
  else WEEK_COLOR="$BLUE"; fi

  WEEK_BAR=$(make_bar "$WEEK_PCT")

  WEEK_RESET_STR=""
  if [ -n "$WEEK_RESETS" ] && [[ "$WEEK_RESETS" =~ ^[0-9]+$ ]]; then
    DIFF=$((WEEK_RESETS - NOW_EPOCH))
    if [ "$DIFF" -gt 0 ]; then
      RD=$(( DIFF / 86400 ))
      RH=$(( (DIFF % 86400) / 3600 ))
      RM=$(( (DIFF % 3600) / 60 ))
      if [ "$RD" -gt 0 ]; then
        WEEK_RESET_STR="resets in ${RD}d ${RH}h"
      else
        WEEK_RESET_STR="resets in ${RH}h ${RM}m"
      fi
    fi
  fi

  print_row "7d" "$WEEK_BAR" "$WEEK_COLOR" "$WEEK_PCT" \
    "$WEEK_IN_FMT"  "" \
    "$WEEK_OUT_FMT" "" \
    "$WEEK_TOTAL_FMT" "$WEEK_RESET_STR"
fi

