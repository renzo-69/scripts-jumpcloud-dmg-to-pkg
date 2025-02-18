#!/bin/bash

# Destination folder for .pkg files
DEST_FOLDER="./apps/"
# Temporary folder
TMP_FOLDER="./tmp/"
# CSV file
CSV_FILE="./software_list.csv"
# Debug mode
DEBUG_MODE=false

# Required tools
REQUIRED_TOOLS=("curl" "hdiutil" "pkgbuild")

# Function to check required tools
check_required_tools() {
  for tool in "${REQUIRED_TOOLS[@]}"; do
    if ! type "$tool" > /dev/null 2>&1; then
      show_error_message "The required tool $tool is not installed."
      exit 1
    fi
  done
}

# Function to clean temporary files
clean_temp_files() {
  rm -rf "$TMP_FOLDER"
}

# Function to display an error message
show_error_message() {
  echo "Error: $1" >&2
}

# Function to display a warning message
show_warning_message() {
  echo "Warning: $1"
}

# Function to display a debug message
show_debug_message() {
  if [ "$DEBUG_MODE" = true ]; then
    echo "Debug: $1"
  fi
}

# Function to check the existence of an entry in the CSV file
entry_exists_in_csv() {
  local csv_file="$1"
  local software_name="$2"
  local download_url="$3"
  local existing_entry=$(awk -F ',' -v name="$software_name" -v url="$download_url" '$1 == name && $2 == url {print $0}' "$csv_file")
  if [ -n "$existing_entry" ]; then
    return 0
  else
    return 1
  fi
}

# Function to handle conversion error
handle_conversion_error() {
  local software_name="$1"
  local download_url="$2"
  local converted_dmg="$TMP_FOLDER$software_name-converted.dmg"

  echo "Error: Failed to convert $software_name to .pkg format."
  echo "Retrying conversion with hdiutil convert..."

  hdiutil convert "$TMP_FOLDER$software_name.dmg" -format UDTO -o "$converted_dmg" >/dev/null 2>&1
  local conversion_status=$?

  if [ $conversion_status -eq 0 ]; then
    local MOUNT_OUTPUT=$(hdiutil attach -nobrowse "$converted_dmg" | grep -oE '/Volumes/[^[:space:]]+' | tail -1)
    local VOLUME_NAME=$(basename "$MOUNT_OUTPUT")

    # Check successful mount
    if [ -z "$VOLUME_NAME" ]; then
      show_error_message "Failed to mount the converted .dmg file properly."
      return 1
    fi

    show_debug_message "The converted .dmg file has been successfully mounted to volume $VOLUME_NAME."

    # Perform conversion again
    pkgbuild --root "$MOUNT_OUTPUT" --install-location "/Applications" "$DEST_FOLDER$software_name.pkg" >/dev/null 2>&1
    conversion_status=$?

    if [ $conversion_status -eq 0 ]; then
      echo "Conversion to .pkg format was successful."

      # Check if the software already exists in the CSV file
      if [ -f "$CSV_FILE" ]; then
        if entry_exists_in_csv "$CSV_FILE" "$software_name" "$download_url"; then
          show_warning_message "The software already exists in the CSV file."
          return 0
        fi
      fi

      # Ask if the software should be added to the CSV file
      read -r -p "Do you want to add it to the CSV file? (Y/N): " response
      if [ "$response" = "Y" ] || [ "$response" = "y" ]; then
        # Add to CSV file
        cp "$CSV_FILE" "$TMP_FOLDER"
        echo "$software_name,$download_url" >> "$TMP_FOLDER$CSV_FILE"
        sort -t',' -k1,1 -o "$TMP_FOLDER$CSV_FILE" "$TMP_FOLDER$CSV_FILE"
        mv "$TMP_FOLDER$CSV_FILE" "$CSV_FILE"
        echo "The software has been added to the CSV file."
      fi

      # Detach the converted file
      hdiutil detach "$MOUNT_OUTPUT"
      rm "$converted_dmg"
      return 0
    else
      show_error_message "Failed to convert to .pkg format."
      show_error_message "Please check the .dmg file or conversion permissions."
      return 1
    fi
  else
    show_error_message "Failed to convert the .dmg file."
    show_error_message "Please check the .dmg file or conversion permissions."
    return 1
  fi
}

# Check if the URL and software name were provided as arguments
if [ $# -lt 2 ]; then
  # If no arguments were provided, check the CSV file
  if [ -f "$CSV_FILE" ]; then
    # Read the CSV file and print the list of software
    echo "Available software list:"
    awk -F ',' 'NR>1 {print $2}' "$CSV_FILE"
    exit 0
  else
    show_error_message "URL and software name must be provided as arguments."
    exit 1
  fi
fi

# Check if debug mode is enabled
if [ "$1" = "--debug" ]; then
  DEBUG_MODE=true
  shift
fi

# Function to process a software entry
process_software_entry() {
  local software_name="$1"
  local download_url="$2"

  echo "Processing $software_name..."

  # Create temporary folder if it doesn't exist
  mkdir -p "$TMP_FOLDER" || show_error_message "Failed to create temporary folder $TMP_FOLDER."

  # Create destination folder if it doesn't exist
  mkdir -p "$DEST_FOLDER" || show_error_message "Failed to create destination folder $DEST_FOLDER."

  # Download the file to the temporary folder
  echo "Downloading $download_url..."
  retry_count=3
  while [ $retry_count -gt 0 ]; do
    curl -o "$TMP_FOLDER$software_name.dmg" -JL "$download_url" && break
    echo "Download error. Retrying..."
    ((retry_count--))
  done
  [ $retry_count -eq 0 ] && show_error_message "Failed to download file from $download_url."

  # Verify the integrity of the .dmg file
  echo "Verifying .dmg file integrity..."
  hdiutil verify "$TMP_FOLDER$software_name.dmg" >/dev/null 2>&1
  verify_status=$?

  if [ $verify_status -ne 0 ]; then
    show_error_message "The downloaded .dmg file for $software_name is either damaged or not valid."
    return
  fi

  # Mount the .dmg file and get the volume name
  show_debug_message "Mounting $software_name.dmg..."
  MOUNT_OUTPUT=$(hdiutil attach -nobrowse "$TMP_FOLDER$software_name.dmg" | awk -F '\t' '/\/Volumes\// {print $NF; exit}')
  VOLUME_NAME=$(basename "$MOUNT_OUTPUT")

  # Check successful mount
  if [ -z "$VOLUME_NAME" ]; then
    show_error_message "Failed to mount the .dmg file properly."
    return
  fi

  show_debug_message "The .dmg file has been successfully mounted to volume $VOLUME_NAME."

  # Remove existing .pkg file
  if [ -f "$DEST_FOLDER$software_name.pkg" ]; then
    rm "$DEST_FOLDER$software_name.pkg"
  fi

  # Convert to .pkg format
  echo "Converting $software_name to .pkg format..."
  pkg_name="$DEST_FOLDER$software_name.pkg"
  pkgbuild --root "$MOUNT_OUTPUT" --install-location "/Applications" "$pkg_name" >/dev/null 2>&1
  conversion_status=$?

  # Check conversion status
  if [ $conversion_status -eq 0 ]; then
    echo "Conversion to .pkg format was successful."

    # Check if the software already exists in the CSV file
    if [ -f "$CSV_FILE" ]; then
      if entry_exists_in_csv "$CSV_FILE" "$software_name" "$download_url"; then
        show_warning_message "The software already exists in the CSV file."
      fi
    fi

    # Ask if the software should be added to the CSV file
    read -r -p "Do you want to add it to the CSV file? (Y/N): " response
    if [ "$response" = "Y" ] || [ "$response" = "y" ]; then
      # Add to CSV file
      cp "$CSV_FILE" "$TMP_FOLDER"
      echo "$software_name,$download_url" >> "$TMP_FOLDER$CSV_FILE"
      sort -t',' -k1,1 -o "$TMP_FOLDER$CSV_FILE" "$TMP_FOLDER$CSV_FILE"
      mv "$TMP_FOLDER$CSV_FILE" "$CSV_FILE"
      echo "The software has been added to the CSV file."
    fi

    # Check if debug mode is enabled
    if [ "$DEBUG_MODE" = true ]; then
      echo "Conversion details:"
      cat "$TMP_FOLDER$software_name_conversion_log.txt"
    fi
  else
    handle_conversion_error "$software_name" "$download_url"
  fi

  # Detach the .dmg file
  hdiutil detach "$MOUNT_OUTPUT"

  # Clean up temporary files
  clean_temp_files

  echo "--------------------------------------"
}

# Iterate through the CSV file
while IFS=, read -r software_name download_url; do
  process_software_entry "$software_name" "$download_url"
done <"$CSV_FILE"