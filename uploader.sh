#!/bin/bash
# Run this script using the Bash shell interpreter

# -----------------------------------------------------------------------------
# Auto Git Sync Script
# Continuously monitors a Git repository and automatically commits & pushes
# changes based on file change count or time interval.
# -----------------------------------------------------------------------------

function debug_log() {                              # Print a timestamped debug line (always enabled)
	echo "[DEBUG $(date '+%Y-%m-%d %H:%M:%S')] $*" >&2 # Timestamped debug output sent to stderr so it doesn't pollute stdout
}                                                   # End debug_log function definition

function check_required_tools_installed() {                          # Verify every external command this script depends on is installed and runnable
	debug_log "ENTER check_required_tools_installed()"                  # Trace function entry
	required_commands=(date find basename ebook-convert gs mv qpdf git) # List of commands this script actually depends on
	missing_commands=()                                                 # Array collecting the names of any missing commands
	debug_log "Required commands: ${required_commands[*]}"              # Show the full dependency list

	for command_name in "${required_commands[@]}"; do                           # Check each required command one at a time
		if ! command -v "$command_name" >/dev/null 2>&1; then                      # See if it's installed and on PATH
			debug_log "Command NOT found: $command_name"                              # Trace missing command
			missing_commands+=("$command_name")                                       # Add it to the list of missing commands
		else                                                                       # Command was found
			debug_log "Command found: $command_name -> $(command -v "$command_name")" # Trace found command and its path
		fi                                                                         # End the individual command check
	done                                                                        # End the loop over required commands

	debug_log "Missing command count: ${#missing_commands[@]}" # Show how many commands are missing

	if [ "${#missing_commands[@]}" -gt 0 ]; then                                                        # If anything was missing
		for command_name in "${missing_commands[@]}"; do                                                   # Loop over every missing command name
			debug_log "[ERROR] Required command not found: $command_name"                                     # Report the missing command
		done                                                                                               # End the loop over missing command names
		debug_log "[ERROR] One or more required commands are missing. Install them and rerun this script." # Explain what to do
		debug_log "EXIT check_required_tools_installed() -> exiting script with status 1"                  # Trace fatal exit
		exit 1                                                                                             # Stop before doing any work
	fi                                                                                                  # End the missing-dependency check
	debug_log "EXIT check_required_tools_installed() -> all dependencies satisfied"                     # Trace successful function exit
}                                                                                                    # End check_required_tools_installed function definition

function run_auto_git_sync() { # Define the main function that contains all script logic
	debug_log "ENTER run_auto_git_sync()"
	check_required_tools_installed # Confirm all required tools are installed before doing any work

	# ---------------- Configuration ----------------

	seconds_between_checks=30           # Wait 30 seconds between each repository check
	max_seconds_before_forced_push=1800 # Force push at least every 1800 seconds (30 min)
	max_changed_files_before_push=100   # Push early if 100+ files have changed
	epub_source_folder="Assets/"        # Folder that holds the source .epub files
	pdf_output_folder="PDFs/"           # Folder that holds the converted .pdf files

	debug_log "Config: seconds_between_checks=${seconds_between_checks}"
	debug_log "Config: max_seconds_before_forced_push=${max_seconds_before_forced_push}"
	debug_log "Config: max_changed_files_before_push=${max_changed_files_before_push}"
	debug_log "Config: epub_source_folder=${epub_source_folder}"
	debug_log "Config: pdf_output_folder=${pdf_output_folder}"
	debug_log "Config: working directory (pwd)=$(pwd)"

	last_push_timestamp_seconds=$(date +%s) # Store current time in seconds since Unix epoch
	debug_log "Initial last_push_timestamp_seconds=${last_push_timestamp_seconds}"

	# ---------------- Monitoring Loop ----------------

	loop_iteration=0 # Counter tracking how many monitoring loop iterations have run

	while true; do                                                      # Run indefinitely in a loop
		((loop_iteration++))                                               # Increment iteration counter
		debug_log "===== Loop iteration #${loop_iteration} starting =====" # Trace loop iteration boundary

		current_timestamp_seconds=$(date +%s)                                                # Get current time in epoch seconds
		seconds_since_last_push=$((current_timestamp_seconds - last_push_timestamp_seconds)) # Time since last push
		debug_log "current_timestamp_seconds=${current_timestamp_seconds}"                   # Trace current timestamp
		debug_log "seconds_since_last_push=${seconds_since_last_push}"                       # Trace elapsed time

		if [ -d "$epub_source_folder" ]; then # Only run epub cleanup/conversion if the source folder exists
			debug_log "epub_source_folder '${epub_source_folder}' exists, proceeding with epub cleanup/conversion"

			large_epub_count_before=$(find "$epub_source_folder" -type f -iname '*.epub' -size +100M | wc -l)              # Count oversized epubs before deleting
			debug_log "Oversized (>100M) epub files found: ${large_epub_count_before}"                                     # Trace count of files about to be deleted
			find "$epub_source_folder" -type f -iname '*.epub' -size +100M -print -delete | while read -r removed_file; do # Remove all the files larger than 100 MB, logging each one
				debug_log "Deleted oversized epub: ${removed_file}"                                                           # Trace each deletion
			done                                                                                                           # End oversized-epub deletion loop

			converted_file_count=0 # Counter tracking how many files have been converted this iteration
			debug_log "Scanning Assets for .epub files to convert (sorted smallest first)"

			for epub_file_path in $( # Loop over every .epub file in the Assets directory
				find Assets -name '*.epub' -type f -printf '%s %p\n' | sort -n | cut -d' ' -f2-
			); do
				debug_log "Considering epub file: ${epub_file_path}"            # Trace which file is being considered
				book_name_without_extension=$(basename "$epub_file_path" .epub) # Extract the filename without the .epub extension
				pdf_output_path="PDFs/$book_name_without_extension.pdf"         # Build the corresponding output PDF path
				debug_log "Derived pdf_output_path=${pdf_output_path}"          # Trace derived output path

				if [ ! -f "$pdf_output_path" ]; then                                                                                                              # Only convert if the PDF output does not already exist
					debug_log "Converting: $epub_file_path"                                                                                                          # Notify which file is being converted
					debug_log "PDF output does not exist yet, starting conversion pipeline for ${epub_file_path}"                                                    # Trace start of conversion
					debug_log "Running ebook-convert: ${epub_file_path} -> ${pdf_output_path}"                                                                       # Trace ebook-convert invocation
					QTWEBENGINE_CHROMIUM_FLAGS="--no-sandbox --disable-gpu" ebook-convert "$epub_file_path" "$pdf_output_path" --verbose                             # Convert the epub to PDF, disabling the Chromium sandbox
					debug_log "ebook-convert exit status: $?"                                                                                                        # Trace ebook-convert result
					compressed_pdf_temp_path="${pdf_output_path}.compressed.tmp"                                                                                     # Temp path for the ghostscript-compressed output (gs can't read and write the same file)
					debug_log "Running ghostscript compression: ${pdf_output_path} -> ${compressed_pdf_temp_path}"                                                   # Trace gs invocation
					gs -sDEVICE=pdfwrite -dCompatibilityLevel=1.4 -dPDFSETTINGS=/ebook -dNOPAUSE -dBATCH -sOutputFile="$compressed_pdf_temp_path" "$pdf_output_path" # Recompress the converted PDF into the temp path
					debug_log "ghostscript exit status: $?"                                                                                                          # Trace gs result
					mv "$compressed_pdf_temp_path" "$pdf_output_path"                                                                                                # Replace the original PDF with the compressed version
					debug_log "Moved compressed file into place: ${pdf_output_path} (mv exit status: $?)"                                                            # Trace mv result
					debug_log "Running qpdf optimization on ${pdf_output_path}"                                                                                      # Trace qpdf invocation
					qpdf --optimize-images --compress-streams=y --replace-input "$pdf_output_path"                                                                   # Further optimize images and compress streams in place
					debug_log "qpdf exit status: $?"                                                                                                                 # Trace qpdf result
					rm -f "$epub_file_path"                                                                                                                          # Delete the source epub now that it has been converted
					debug_log "Removed source epub: ${epub_file_path}"                                                                                               # Trace source epub removal
					((converted_file_count++))                                                                                                                       # Increment the conversion counter
					debug_log "converted_file_count is now ${converted_file_count}"                                                                                  # Trace updated counter
				else                                                                                                                                              # PDF output already exists
					debug_log "PDF output already exists at ${pdf_output_path}, skipping conversion for ${epub_file_path}"                                           # Trace skip
				fi                                                                                                                                                # End the missing-PDF check

				if [ "$converted_file_count" -ge "$max_changed_files_before_push" ]; then                                                                                             # Stop the batch once the file-count limit has been reached
					debug_log "converted_file_count (${converted_file_count}) reached max_changed_files_before_push (${max_changed_files_before_push}), breaking out of conversion loop" # Trace early break
					break                                                                                                                                                                # Exit the for loop early once the batch size is hit
				fi                                                                                                                                                                    # End the batch-size check
			done                                                                                                                                                                   # End the loop over epub files
			debug_log "Finished epub conversion pass, total converted this iteration: ${converted_file_count}"                                                                     # Trace end of conversion pass
		else                                                                                                                                                                    # epub_source_folder does not exist
			debug_log "epub_source_folder '${epub_source_folder}' does not exist, skipping epub cleanup/conversion"                                                                # Trace skip
		fi                                                                                                                                                                      # End the epub source folder check

		if [ -d "$pdf_output_folder" ]; then                                                           # Only clean up PDFs if the output folder exists
			debug_log "pdf_output_folder '${pdf_output_folder}' exists, cleaning up oversized PDFs"       # Trace start of PDF cleanup
			large_pdf_count=$(find PDFs/ -type f -iname '*.pdf' -size +100M | wc -l)                      # Count oversized PDFs before deleting
			debug_log "Oversized (>100M) pdf files found: ${large_pdf_count}"                             # Trace count of files about to be deleted
			find PDFs/ -type f -iname '*.pdf' -size +100M -print -delete | while read -r removed_file; do # Remove all the files larger than 100 MB, logging each one
				debug_log "Deleted oversized pdf: ${removed_file}"                                           # Trace each deletion
			done                                                                                          # End oversized-pdf deletion loop
		else                                                                                           # pdf_output_folder does not exist
			debug_log "pdf_output_folder '${pdf_output_folder}' does not exist, skipping PDF cleanup"     # Trace skip
		fi                                                                                             # End the PDF output folder check

		changed_file_count=$(git status --porcelain -uall | wc -l) # Count changed files using git status in machine-readable (--porcelain) format, including untracked (-uall)
		debug_log "changed_file_count=${changed_file_count}"       # Trace changed file count

		# ---------------- Status Output ----------------

		debug_log "------------------------------------------------------------" # Print separator line
		debug_log "Repository Status Report"                                     # Header title for clarity
		debug_log "Time                : $(date)"                                # Print current human-readable time
		debug_log "Changed Files       : ${changed_file_count}"                  # Show number of changed files
		debug_log "Time Since Last Push: ${seconds_since_last_push} seconds"     # Show elapsed time since last push
		debug_log "------------------------------------------------------------" # Print separator line

		# ---------------- Trigger Conditions ----------------

		debug_log "Evaluating trigger conditions: changed_file_count=${changed_file_count} (>= ${max_changed_files_before_push}?), seconds_since_last_push=${seconds_since_last_push} (>= ${max_seconds_before_forced_push}?)" # Trace trigger evaluation

		if [[ ${changed_file_count} -ge ${max_changed_files_before_push} || ${seconds_since_last_push} -ge ${max_seconds_before_forced_push} ]]; then # Push if too many files changed or too much time has passed
			debug_log "Trigger condition met, entering push workflow"                                                                                    # Trace trigger fired

			if [[ ${changed_file_count} -eq 0 ]]; then                                                                                   # If trigger happened but there are actually no changes
				debug_log "[INFO] Trigger reached but no changes detected. Resetting timer."                                                # Inform that nothing needs to be done
				debug_log "changed_file_count is 0, nothing to push, resetting last_push_timestamp_seconds to ${current_timestamp_seconds}" # Trace timer reset
				last_push_timestamp_seconds=$current_timestamp_seconds                                                                      # Reset timer so we don't keep triggering
				debug_log "Sleeping ${seconds_between_checks}s before next iteration"                                                       # Trace sleep
				sleep "${seconds_between_checks}"                                                                                           # Wait before next check
				continue                                                                                                                    # Skip rest of loop and start next iteration
			fi                                                                                                                           # End empty-change check

			# ---------------- Pull Latest Changes ----------------

			debug_log "[INFO] Pulling latest changes from remote repository..." # Inform that we are syncing with remote
			debug_log "Running: git pull --rebase --autostash"                  # Trace git pull invocation

			if ! git pull --rebase --autostash; then                                                                                   # Pull and rebase local changes on top, auto-stashing uncommitted work
				debug_log "[ERROR] Failed to pull/rebase from remote repository."                                                         # Show error message
				debug_log "         Possible causes: merge conflicts, network issues, or auth failure."                                   # Explain likely causes
				debug_log "         Action: Resolve manually and rerun script."                                                           # State what action to take
				debug_log "git pull --rebase --autostash FAILED (exit status $?), sleeping ${seconds_between_checks}s then retrying loop" # Trace failure
				sleep "${seconds_between_checks}"                                                                                         # Wait before retrying
				continue                                                                                                                  # Skip rest of loop
			fi                                                                                                                         # End git pull block
			debug_log "git pull --rebase --autostash succeeded"                                                                        # Trace pull success

			# ---------------- Stage Changes ----------------

			debug_log "[INFO] Staging all changes (additions, modifications, deletions)..." # Explain staging step
			debug_log "Running: git add -A"                                                 # Trace git add invocation

			if ! git add -A; then                                                                                   # Stage all changes in repository
				debug_log "[ERROR] Failed to stage changes."                                                           # Error message
				debug_log "         Check file permissions or repository state."                                       # Suggest what to check
				debug_log "git add -A FAILED (exit status $?), sleeping ${seconds_between_checks}s then retrying loop" # Trace failure
				sleep "${seconds_between_checks}"                                                                      # Wait before retry
				continue                                                                                               # Skip loop iteration
			fi                                                                                                      # End git add block
			debug_log "git add -A succeeded"                                                                        # Trace add success

			# ---------------- Commit Changes ----------------

			commit_timestamp_utc=$(date -u +'%Y-%m-%d %H:%M:%S UTC')         # Create a timestamp in UTC for commit message
			commit_message_text="Auto-sync commit (${commit_timestamp_utc})" # Build readable commit message
			debug_log "Built commit message: ${commit_message_text}"         # Trace commit message

			debug_log "[INFO] Creating commit..."                         # Inform commit step started
			debug_log "Running: git commit -m \"${commit_message_text}\"" # Trace git commit invocation

			if git commit -m "${commit_message_text}"; then                                                                                # Try to commit staged changes
				debug_log "[SUCCESS] Commit created successfully."                                                                            # Success message
				debug_log "git commit succeeded"                                                                                              # Trace commit success
			else                                                                                                                           # If commit fails (likely no changes)
				debug_log "[INFO] No new changes to commit (already up-to-date)."                                                             # Inform
				debug_log "git commit reported no changes to commit (exit status $?), sleeping ${seconds_between_checks}s then retrying loop" # Trace no-op commit
				sleep "${seconds_between_checks}"                                                                                             # Wait before retry
				continue                                                                                                                      # Skip rest of loop
			fi                                                                                                                             # End commit block

			# ---------------- Push Changes ----------------

			debug_log "[INFO] Pushing changes to remote repository..." # Inform that we are pushing
			debug_log "Running: git push"                              # Trace git push invocation

			if git push; then                                                                                      # Attempt to push committed changes to remote
				debug_log "[SUCCESS] Push completed successfully."                                                    # Success message
				debug_log "git push succeeded, resetting last_push_timestamp_seconds to ${current_timestamp_seconds}" # Trace push success
				last_push_timestamp_seconds=$current_timestamp_seconds                                                # Reset timer after successful push
			else                                                                                                   # If push fails
				debug_log "[ERROR] Failed to push changes to remote repository."                                      # Error message
				debug_log "         Possible causes: authentication failure, protected branch, or network issues."    # Explain likely causes
				debug_log "         Action: Verify credentials and repository permissions."                           # State what action to take
				debug_log "git push FAILED (exit status $?)"                                                          # Trace push failure
			fi                                                                                                     # End git push block
		else                                                                                                    # Trigger condition not met
			debug_log "Trigger condition not met, no push this iteration"                                          # Trace trigger not fired
		fi                                                                                                      # End trigger condition check

		# ---------------- Wait Before Next Check ----------------

		debug_log "===== Loop iteration #${loop_iteration} complete, sleeping ${seconds_between_checks}s ====="
		sleep "${seconds_between_checks}" # Pause script before next loop iteration to avoid constant CPU usage
	done                               # End infinite loop
}                                   # End run_auto_git_sync function definition

# -----------------------------------------------------------------------------
# Entry Point
# -----------------------------------------------------------------------------

debug_log "Script started, args=$*" # Trace overall script start
run_auto_git_sync                   # Call the main function to start execution
