#!/bin/bash
# tmux AI CLI notification daemon
# Detects AI CLI tools (Claude Code, Codex CLI, Gemini CLI) by inspecting child processes
# and shows status icons on window names:
#   💬 = responding (sustained output for 2.5s+)
#   ❓ = waiting (output stopped + permission prompt detected)
#   ✅ = done (output stopped after responding)

SNAPSHOT_DIR="/tmp/agent-pulse-snapshots"
STATE_DIR="/tmp/agent-pulse-states"
COUNTER_DIR="/tmp/agent-pulse-counters"
DONE_COUNTER_DIR="/tmp/agent-pulse-done-counters"
PID_FILE="/tmp/agent-pulse-daemon.pid"
mkdir -p "$SNAPSHOT_DIR" "$STATE_DIR" "$COUNTER_DIR" "$DONE_COUNTER_DIR"

# Single-instance guard: kill any previous daemon
if [ -f "$PID_FILE" ]; then
  OLD_PID=$(cat "$PID_FILE")
  if kill -0 "$OLD_PID" 2>/dev/null; then
    kill "$OLD_PID" 2>/dev/null
    sleep 0.3
  fi
fi
echo $$ > "$PID_FILE"
trap 'rm -f "$PID_FILE"' EXIT

POLL_INTERVAL="${AGENT_PULSE_INTERVAL:-0.5}"
THRESHOLD="${AGENT_PULSE_THRESHOLD:-2}"
DONE_THRESHOLD="${AGENT_PULSE_DONE_THRESHOLD:-3}"
ICON_RESPONDING="${AGENT_PULSE_ICON_RESPONDING:-💬}"
ICON_DONE="${AGENT_PULSE_ICON_DONE:-✅}"
ICON_WAITING="${AGENT_PULSE_ICON_WAITING:-❓}"
WAITING_PATTERN="${AGENT_PULSE_WAITING_PATTERN:-Do you want to allow|Do you want to proceed}"

# md5 command differs between macOS and Linux
if command -v md5 &>/dev/null; then
  MD5_CMD="md5 -q"
elif command -v md5sum &>/dev/null; then
  MD5_CMD="md5sum | cut -d' ' -f1"
fi

CLI_PATTERN="${AGENT_PULSE_CLI_PATTERN:-claude|codex|gemini}"

while true; do
  VISIBLE=$(tmux list-clients -F '#{session_name}:#{window_index}' 2>/dev/null)

  # Snapshot process tree once per poll cycle
  PS_TREE=$(ps -eo pid,ppid,args 2>/dev/null)

  # Phase 1: Update per-pane states (runs in subshell via pipe, writes to state files)
  tmux list-panes -a -F '#{session_name}:#{window_index} #{pane_id} #{pane_pid} #{pane_active}' 2>/dev/null | while read TARGET PANE_ID PANE_PID PANE_ACTIVE; do
    PANE_KEY=$(echo "$PANE_ID" | tr -d '%')
    STATE_FILE="$STATE_DIR/$PANE_KEY"
    STATE=$(cat "$STATE_FILE" 2>/dev/null || echo "idle")

    # Detect AI CLI tools by checking child process args
    CLI_RUNNING=$(echo "$PS_TREE" | awk -v ppid="$PANE_PID" '$2 == ppid' | grep -qE "$CLI_PATTERN" && echo "1" || echo "0")

    # If no CLI is running, reset any stale done/waiting state immediately
    # (prevents ✅/❓ from persisting after the session has ended)
    if [ "$CLI_RUNNING" = "0" ]; then
      if [ "$STATE" = "done" ] || [ "$STATE" = "waiting" ] || [ "$STATE" = "responding" ]; then
        echo "idle" > "$STATE_FILE"
        echo "0" > "$COUNTER_DIR/$PANE_KEY"
        echo "0" > "$DONE_COUNTER_DIR/$PANE_KEY"
        rm -f "$SNAPSHOT_DIR/$PANE_KEY"
      fi
      continue
    fi

    # User is viewing this window + done state → reset pane state to idle
    # (waiting is NOT reset here — it persists until the user answers the prompt)
    if [ "$STATE" = "done" ] && [ "$PANE_ACTIVE" = "1" ] && echo "$VISIBLE" | grep -qFx "$TARGET"; then
      echo "idle" > "$STATE_FILE"
      echo "0" > "$COUNTER_DIR/$PANE_KEY"
      echo "0" > "$DONE_COUNTER_DIR/$PANE_KEY"
      rm -f "$SNAPSHOT_DIR/$PANE_KEY"
      continue
    fi

    # Early permission prompt detection — only for idle state
    # (responding/waiting states use DONE_COUNT fallback in hash comparison)
    if [ "$STATE" = "idle" ]; then
      PANE_RAW=$(tmux capture-pane -t "$PANE_ID" -p -S -10 2>/dev/null)
      if echo "$PANE_RAW" | grep -vE "^[[:space:]]*❯" | grep -qE "$WAITING_PATTERN"; then
        echo "waiting" > "$STATE_FILE"
        continue
      fi
    fi

    SNAP_FILE="$SNAPSHOT_DIR/$PANE_KEY"
    COUNT_FILE="$COUNTER_DIR/$PANE_KEY"
    DONE_COUNT_FILE="$DONE_COUNTER_DIR/$PANE_KEY"
    COUNT=$(cat "$COUNT_FILE" 2>/dev/null || echo "0")
    DONE_COUNT=$(cat "$DONE_COUNT_FILE" 2>/dev/null || echo "0")

    # Compare pane output snapshot
    CURRENT=$(tmux capture-pane -t "$PANE_ID" -p -S -30 2>/dev/null \
      | awk '{a[NR]=$0} /^─/{seps[++c]=NR} END{cut=(c>=2?seps[c-1]:(c==1?seps[1]:NR+1)); lo=(cut>10?cut-10:1); for(i=lo;i<cut;i++) print a[i]}' \
      | tail -3 \
      | eval "$MD5_CMD")
    LAST=$(cat "$SNAP_FILE" 2>/dev/null)
    echo "$CURRENT" > "$SNAP_FILE"

    [ -z "$LAST" ] && continue

    if [ "$CURRENT" != "$LAST" ]; then
      # Content changed while in done state (e.g., user pressed /clear or typed new message)
      # Reset to idle so the next response can be detected from scratch
      if [ "$STATE" = "done" ]; then
        echo "idle" > "$STATE_FILE"
        echo "0" > "$COUNT_FILE"
        echo "0" > "$DONE_COUNT_FILE"
        rm -f "$SNAP_FILE"
        continue
      fi

      COUNT=$((COUNT + 1))
      echo "$COUNT" > "$COUNT_FILE"
      echo "0" > "$DONE_COUNT_FILE"

      if [ "$COUNT" -ge "$THRESHOLD" ] && [ "$STATE" != "responding" ]; then
        echo "responding" > "$STATE_FILE"
      fi
    else
      if [ "$STATE" = "responding" ] || [ "$STATE" = "waiting" ]; then
        DONE_COUNT=$((DONE_COUNT + 1))
        echo "$DONE_COUNT" > "$DONE_COUNT_FILE"
        if [ "$DONE_COUNT" -ge "$DONE_THRESHOLD" ]; then
          # Check if pane is showing a permission prompt
          PANE_TEXT=$(tmux capture-pane -t "$PANE_ID" -p -S -10 2>/dev/null)
          if echo "$PANE_TEXT" | grep -vE "^[[:space:]]*❯" | grep -qE "$WAITING_PATTERN"; then
            if [ "$STATE" != "waiting" ]; then
              echo "waiting" > "$STATE_FILE"
            fi
          else
            echo "done" > "$STATE_FILE"
          fi
          echo "0" > "$COUNT_FILE"
        fi
      # Do not reset COUNT for idle state — allow accumulation for slow-changing content
      fi
    fi
  done

  # Phase 2: Aggregate per-window state and update icons
  # For each window, find the highest-priority pane state and set the icon accordingly
  tmux list-windows -a -F '#{session_name}:#{window_index}' 2>/dev/null | while read WIN; do
    HIGHEST=0  # 0=idle, 1=done, 2=responding, 3=waiting

    # Iterate panes in this window, find highest priority state
    for PANE_ID in $(tmux list-panes -t "$WIN" -F '#{pane_id}' 2>/dev/null); do
      PANE_KEY=$(echo "$PANE_ID" | tr -d '%')
      PANE_STATE=$(cat "$STATE_DIR/$PANE_KEY" 2>/dev/null || echo "idle")
      case "$PANE_STATE" in
        waiting)    P=3 ;;
        responding) P=2 ;;
        done)       P=1 ;;
        *)          P=0 ;;
      esac
      [ "$P" -gt "$HIGHEST" ] && HIGHEST=$P
    done

    WINDOW_NAME=$(tmux display-message -t "$WIN" -p '#{window_name}' 2>/dev/null) || continue
    CLEAN_NAME=$(echo "$WINDOW_NAME" | sed -E "s/^($ICON_DONE|$ICON_RESPONDING|$ICON_WAITING) //")

    case "$HIGHEST" in
      3) DESIRED="$ICON_WAITING $CLEAN_NAME" ;;
      2) DESIRED="$ICON_RESPONDING $CLEAN_NAME" ;;
      1) DESIRED="$ICON_DONE $CLEAN_NAME" ;;
      *) DESIRED="$CLEAN_NAME" ;;
    esac

    [ "$WINDOW_NAME" != "$DESIRED" ] && tmux rename-window -t "$WIN" "$DESIRED" 2>/dev/null
  done

  sleep "$POLL_INTERVAL"
done
