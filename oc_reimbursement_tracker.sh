#!/bin/bash

# === CONFIGURATION ===
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
API_KEY_FILE="$SCRIPT_DIR/.torn_api_key"
ITEM_CACHE="$SCRIPT_DIR/known_oc_items.txt"
LAST_RUN_FILE="$SCRIPT_DIR/.last_run_time"
LOG_FILE="$SCRIPT_DIR/oc_reimbursement_logs.txt"

# === FLAGS ===
IGNORE_CUTOFF=false
CLI_API_KEY=""
for ((i=1; i<=$#; i++)); do
  if [[ "${!i}" == "--ignore-cutoff" ]]; then
    IGNORE_CUTOFF=true
  elif [[ "${!i}" == "--key" ]]; then
    next=$((i+1))
    CLI_API_KEY="${!next}"
  fi
done

# === CUTOFF HANDLING ===
if [[ -f "$LAST_RUN_FILE" && "$IGNORE_CUTOFF" = false ]]; then
  CUTOFF=$(<"$LAST_RUN_FILE")
  echo "⏳ Using last run time as cutoff: $CUTOFF"
else
  today=$(date -u +"%Y-%m-%d")
  CUTOFF="${today}T00:00:00"
  echo "⏳ No saved last run — using today's date at midnight UTC: $CUTOFF"
fi

# === API KEY HANDLING ===
if [[ -n "$CLI_API_KEY" ]]; then
  API_KEY="$CLI_API_KEY"
elif [[ -f "$API_KEY_FILE" ]]; then
  API_KEY=$(<"$API_KEY_FILE")
else
  read -p "🔑 Enter your Torn API key: " API_KEY
  echo "$API_KEY" > "$API_KEY_FILE"
  echo "✅ API key saved in plain text at $API_KEY_FILE"
fi

# === PLAYER NAME LOOKUP ===
get_player_name() {
  local id="$1"
  curl -s "https://api.torn.com/user/${id}?selections=basic&key=$API_KEY" | jq -r '.name'
}

# === FETCH DATA ===
LOG_JSON=$(curl -s "https://api.torn.com/user/?selections=log&key=$API_KEY")
FACTION_JSON=$(curl -s "https://api.torn.com/faction/?selections=basic&key=$API_KEY")
ITEM_JSON=$(curl -s "https://api.torn.com/torn/?selections=items&key=$API_KEY")

FACTION_MEMBERS=($(echo "$FACTION_JSON" | jq -r '.members | keys[]'))

touch "$ITEM_CACHE"
declare -A OC_ITEMS
while IFS= read -r item; do OC_ITEMS["$item"]=1; done < "$ITEM_CACHE"

declare -A SENT_FOR_OC

TMP_LOG="$(mktemp)"
total_reimbursed=0
total_cost=0

while read -r entry; do
  timestamp=$(echo "$entry" | jq -r '.timestamp')
  iso_time=$(date -u -d "@$timestamp" +"%Y-%m-%dT%H:%M:%S")
  time_fmt=$(date -u -d "@$timestamp" +"%H:%M:%S - %d/%m/%y")
  if [[ "$iso_time" < "$CUTOFF" ]]; then continue; fi

  title=$(echo "$entry" | jq -r '.title')

  # Learn OC items only from sends with "For OC." message
  if [[ "$title" == "Item send" ]]; then
    message=$(echo "$entry" | jq -r '.data.message')
    receiver=$(echo "$entry" | jq -r '.data.receiver')
    while IFS= read -r item_entry; do
      item_id=$(echo "$item_entry" | jq -r '.id')
      [[ -z "$item_id" || "$item_id" == "null" ]] && continue
      name=$(echo "$ITEM_JSON" | jq -r ".items[\"$item_id\"].name")
      [[ -z "$name" || "$name" == "null" ]] && continue
      if [[ " ${FACTION_MEMBERS[*]} " == *" $receiver "* ]]; then
        SENT_FOR_OC["$name"]=1
      fi
      if [[ "$message" == "For OC." && -z "${OC_ITEMS["$name"]}" ]]; then
        OC_ITEMS["$name"]=1
        grep -Fxq "$name" "$ITEM_CACHE" || echo "$name" >> "$ITEM_CACHE"
      fi
    done < <(echo "$entry" | jq -c '.data.items[]')
  fi

  # Purchases (only log if reimbursable)
  if [[ "$title" == "Item market buy" ]]; then
    seller_id=$(echo "$entry" | jq -r '.data.seller')
    seller_name=$(get_player_name "$seller_id")
    while IFS= read -r item_entry; do
      item_id=$(echo "$item_entry" | jq -r '.id')
      [[ -z "$item_id" || "$item_id" == "null" ]] && continue
      name=$(echo "$ITEM_JSON" | jq -r ".items[\"$item_id\"].name")
      [[ -z "$name" || "$name" == "null" ]] && continue
      cost_total=$(echo "$entry" | jq -r '.data.cost_total')
      cost_each=$(echo "$entry" | jq -r '.data.cost_each')
      qty=$(echo "$item_entry" | jq -r '.qty // 1')

      if [[ -n "${OC_ITEMS["$name"]}" && -n "${SENT_FOR_OC["$name"]}" ]]; then
        total_cost=$((total_cost + cost_total))
        if (( qty > 1 )); then
          echo "$time_fmt You bought ${qty}x $name on the item market from $seller_name at \$$(printf "%'d" $cost_each) each for a total of \$$(printf "%'d" $cost_total)" >> "$TMP_LOG"
        else
          article="a"
          [[ "$name" == "Zip Ties" ]] && article="some"
          echo "$time_fmt You bought $article $name on the item market from $seller_name at \$$(printf "%'d" $cost_each) each for a total of \$$(printf "%'d" $cost_total)" >> "$TMP_LOG"
        fi
      fi
    done < <(echo "$entry" | jq -c '.data.items[]')
  fi

  # Sends
  if [[ "$title" == "Item send" ]]; then
    receiver=$(echo "$entry" | jq -r '.data.receiver')
    while IFS= read -r item_entry; do
      item_id=$(echo "$item_entry" | jq -r '.id')
      [[ -z "$item_id" || "$item_id" == "null" ]] && continue
      name=$(echo "$ITEM_JSON" | jq -r ".items[\"$item_id\"].name")
      [[ -z "$name" || "$name" == "null" ]] && continue
      if [[ " ${FACTION_MEMBERS[*]} " == *" $receiver "* ]]; then
        receiver_name=$(get_player_name "$receiver")
        article="a"
        [[ "$name" == "Zip Ties" ]] && article="some"
        echo "$time_fmt You sent $article $name to $receiver_name with the message: For OC." >> "$TMP_LOG"
      fi
    done < <(echo "$entry" | jq -c '.data.items[]')
  fi

  # Reimbursements
  if [[ "$title" == "Faction payday receive" ]]; then
    amt=$(echo "$entry" | jq -r '.data.money_given')
    total_reimbursed=$((total_reimbursed + amt))
    echo "$time_fmt You paid \$$(printf "%'d" $amt) to hoggson from The ZOO" >> "$TMP_LOG"
  fi
done < <(echo "$LOG_JSON" | jq -c '.log | to_entries[] | .value')

# === FINAL SUMMARY ===
echo "📄 Torn-style logs saved to: $LOG_FILE"
echo "📦 Total OC item purchases: \$$(printf "%'d" $total_cost)"
echo "💸 Reimbursements received: \$$(printf "%'d" $total_reimbursed)"

if (( total_cost == 0 && total_reimbursed == 0 )); then
  echo "🟡 No OC purchases or reimbursements found — nothing to send."
elif (( total_reimbursed >= total_cost )); then
  echo "✅ Reimbursement complete."
else
  owed=$((total_cost - total_reimbursed))
  echo "❌ Reimbursement incomplete — you still need to send yourself \$$(printf "%'d" $owed)"
fi

# === ARCHIVE OUTPUTS ===
ARCHIVE_DIR="$SCRIPT_DIR/archive"
mkdir -p "$ARCHIVE_DIR"

timestamp=$(date +"%Y-%m-%d_%H-%M-%S")
tac "$TMP_LOG" > "$LOG_FILE"
rm "$TMP_LOG"
cp "$LOG_FILE" "$ARCHIVE_DIR/oc_reimbursement_logs_$timestamp.txt"
echo "🗂️ Archived log saved to: $ARCHIVE_DIR/oc_reimbursement_logs_$timestamp.txt"

# === UPDATE LAST RUN TIME ===
now=$(date -u +"%Y-%m-%dT%H:%M:%S")
echo "$now" > "$LAST_RUN_FILE"
echo "🕒 Updated last run time to: $now"

# === DISPLAY LOG CONTENTS ===
echo -e "\n📋 Log contents:\n"
cat "$LOG_FILE"
