#!/bin/bash

# Specify the location of the .env file
ENV_PATH="./.env"

# Load environment variables from .env
if [ -f "$ENV_PATH" ]; then
  set -o allexport
  source "$ENV_PATH"
  set +o allexport
else
  echo "Error: .env file not found at $ENV_PATH. Please create one with DB_PATH, LOG_PATH, and optionally EXEC_USER variables."
  exit 1
fi

# Function to display usage
usage() {
  echo "Available commands:"
  echo "  --query DID          Query posts by a specific DID"
  echo "  --query --phrase     Query posts containing a specific phrase"
  echo "  --delete --latest    Delete the latest post by DID"
  echo "  --delete --all       Delete all posts by DID"
  echo "  --delete --uri       Delete a specific post by its URI"
  exit 1
}

# Parse commands and options
COMMAND=$1
OPTION=$2

case $COMMAND in
  --query)
    if [[ "$OPTION" == "--phrase" && -n "$3" ]]; then
      MODE="query-phrase"
      PHRASE=$3
    elif [[ -n "$OPTION" ]]; then
      MODE="query-did"
      DID=$OPTION
    else
      usage
    fi
    ;;
  --delete)
    if [[ "$OPTION" == "--latest" && -n "$3" ]]; then
      MODE="delete-latest"
      DID=$3
    elif [[ "$OPTION" == "--uri" && -n "$3" ]]; then
      MODE="delete-uri"
      URI=$3
    elif [[ "$OPTION" == "--all" && -n "$3" ]]; then
      MODE="delete-all"
      DID=$3
    else
      usage
    fi
    ;;
  *)
    usage
    ;;
esac

# Function to execute commands as specified user or current user
run_as_user() {
  local COMMAND=$1
  if [ -n "$EXEC_USER" ]; then
    sudo su "$EXEC_USER" -c "$COMMAND"
  else
    eval "$COMMAND"
  fi
}

# Function to execute SQL commands
execute_sql() {
  local SQL_COMMAND=$1
  run_as_user "sqlite3 $DB_PATH <<SQL
$SQL_COMMAND
.exit
SQL"
}

# Function to search logs
search_logs() {
  local SEARCH_TERM=$1
  run_as_user "grep -i '$SEARCH_TERM' '$LOG_PATH'"
}

# Function to calculate column widths dynamically
calculate_widths() {
  local MAX_DID_LENGTH=40 # Default value
  if [ -n "$LOG_CONTENT" ]; then
    MAX_DID_LENGTH=$(echo "$LOG_CONTENT" | grep -oP "(?<=Found post by )[a-zA-Z0-9:.-]+" | awk '{ print length }' | sort -nr | head -n1)
  fi
  DID_WIDTH=$((MAX_DID_LENGTH + 2)) # Adding margin
  CONTENT_WIDTH=80
  URI_WIDTH=100
}

# Function to create a separator line
create_separator() {
  local WIDTHS=("$@")
  local SEPARATOR=""
  for WIDTH in "${WIDTHS[@]}"; do
    SEPARATOR+=$(printf '%*s' "$WIDTH" '' | tr ' ' '-')
    SEPARATOR+="  "
  done
  echo "$SEPARATOR"
}

# Function to query posts by DID
query_by_did() {
  echo "Querying posts for DID: $DID"
  OUTPUT=$(execute_sql "SELECT uri AS 'URI' FROM post WHERE uri LIKE '%$DID%';")
  if [[ -z "$OUTPUT" ]]; then
    echo "No posts found for DID: $DID"
  else
    DID_WIDTH=$((40 + 2)) # Adjusted width for DIDs
    URI_WIDTH=100         # Width for URI column
    printf "%-${DID_WIDTH}s  %-${URI_WIDTH}s\n" "DID" "URI"
    create_separator "$DID_WIDTH" "$URI_WIDTH"
    echo "$OUTPUT" | while IFS='|' read -r DID URI; do
      printf "%-${DID_WIDTH}s  %-${URI_WIDTH}s\n" "$DID" "$URI"
    done
  fi
}

# Function to query posts by phrase
query_by_phrase() {
  echo "Searching logs for phrase: \"$PHRASE\""
  LOG_CONTENT=$(search_logs "$PHRASE")
  if [[ -z "$LOG_CONTENT" ]]; then
    echo "No posts found containing the phrase: \"$PHRASE\""
  else
    echo "Results for phrase: \"$PHRASE\""
    calculate_widths
    # Print headers
    printf "%-${DID_WIDTH}s  %-${CONTENT_WIDTH}s\n" "DID" "Content"
    create_separator "$DID_WIDTH" "$CONTENT_WIDTH"
    while IFS= read -r LINE; do
      if [[ "$LINE" =~ Found\ post\ by ]]; then
        DID=$(echo "$LINE" | grep -oP "(?<=Found post by )[a-zA-Z0-9:.-]+")
        DID=${DID%:} # Strip trailing colon if any
        CONTENT=$(echo "$LINE" | sed -E "s/^.*: //" | cut -c1-$((CONTENT_WIDTH - 3)))
        [ "${#LINE}" -gt $CONTENT_WIDTH ] && CONTENT="${CONTENT}..."
        printf "%-${DID_WIDTH}s  %-${CONTENT_WIDTH}s\n" "$DID" "$CONTENT"
      fi
    done <<< "$LOG_CONTENT"
  fi
}

# Function to delete posts
delete_post() {
  echo "Executing SQL command for deletion:"
  echo "$1"
  execute_sql "$1"
  if [ $? -eq 0 ]; then
    echo "Command executed successfully."
  else
    echo "Command failed to execute."
  fi
}

# Handle commands
case $MODE in
  query-did)
    query_by_did
    ;;
  query-phrase)
    query_by_phrase
    ;;
  delete-latest)
    SQL_COMMAND="DELETE FROM post WHERE uri IN (SELECT uri FROM post WHERE uri LIKE '%$DID%' ORDER BY indexedAt DESC LIMIT 1);"
    delete_post "$SQL_COMMAND"
    ;;
  delete-uri)
    SQL_COMMAND="DELETE FROM post WHERE uri = '$URI';"
    delete_post "$SQL_COMMAND"
    ;;
  delete-all)
    SQL_COMMAND="DELETE FROM post WHERE uri LIKE '%$DID%';"
    delete_post "$SQL_COMMAND"
    ;;
  *)
    usage
    ;;
esac

