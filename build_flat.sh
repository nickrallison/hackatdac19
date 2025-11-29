#!/bin/bash
set -e

# Configuration
YS_FILE="ariane_build.ys"
FLIST_FILE="files.list"
OUTPUT_VERILOG="ariane_flat.v"

# 1. Generate the raw file list using Bender
echo "[1/4] Generating file list from Bender..."
bender script flist -t synthesis -t fpga > $FLIST_FILE

# 2. Generate Include Directories
#    We need to be robust: some files are included as "pkg/file.svh" (requiring parent dir)
#    and some as "file.svh" (requiring the dir itself).
echo "[2/4] Scanning for include directories..."

# Find all directories containing .svh files
SVH_DIRS=$(find . -name "*.svh" -exec dirname {} \; | sort -u)

# Loop through them and add both the dir AND its parent to the list
ALL_DIRS=""
for d in $SVH_DIRS; do
    ALL_DIRS="$ALL_DIRS $d $(dirname $d)"
done

# Sort, unique, and format as a space-separated string for Yosys
INC_DIRS=$(echo $ALL_DIRS | tr ' ' '\n' | sort -u | tr '\n' ' ')
INC_DIRS="$INC_DIRS ./include"

# 3. Construct the Yosys build script
echo "[3/4] Constructing Yosys build script ($YS_FILE)..."

# Initialize file
> $YS_FILE

# --- Global Verific Configuration ---

# Register Include Directories
if [ ! -z "$INC_DIRS" ]; then
    echo "verific -vlog-incdir $INC_DIRS" >> $YS_FILE
fi

# Register Global Defines
# WT_DCACHE: Disables the complex cache subsystem, replacing it with a simpler interface suitable for flattening.
# TARGET_SYNTHESIS: Often used by IP blocks to select synthesis-friendly logic.
echo "verific -vlog-define WT_DCACHE TARGET_SYNTHESIS" >> $YS_FILE

# --- File Parsing ---

# Parse the file list and append 'verific' commands
awk '{
    # Trim whitespace
    gsub(/^[ \t]+|[ \t]+$/, "", $0);
    
    # Skip empty lines
    if (length($0) == 0) next;

    # Check extensions and write commands
    if ($0 ~ /\.vhd$/ || $0 ~ /\.vhdl$/) {
        print "verific -vhdl " $0
    } 
    else if ($0 ~ /\.sv$/ || $0 ~ /\.v$/) {
        print "verific -sv " $0
    }
}' $FLIST_FILE >> $YS_FILE

# --- Elaboration & Flattening ---

cat << EOF >> $YS_FILE

# Import the design into Yosys from Verific
verific -import ariane

# Elaborate the hierarchy
hierarchy -check -top ariane

# Flatten the design
flatten

# Cleanup (remove unused signals/cells created by flattening)
opt_clean -purge

# Write the result
write_verilog $OUTPUT_VERILOG
EOF

# 4. Run Yosys
echo "[4/4] Running Yosys..."
yosys $YS_FILE | tee flatten.log

echo "Done. Output written to $OUTPUT_VERILOG"