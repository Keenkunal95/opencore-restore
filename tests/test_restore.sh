#!/bin/sh

# ==============================================================================
# Test Suite for OpenCore Restoration Script
# ==============================================================================
#
# Description:
#   Mocks system commands (diskutil, mount, cp, mv, nvram, shutdown) to verify
#   the logic of restore.sh without modifying the actual system.
#
# Usage:
#   cd tests
#   ./test_restore.sh
#
# ==============================================================================

# Ensure we are running from the tests directory
cd "$(dirname "$0")"

# --- Setup Mock Environment ---
TEST_DIR="./test_env"
MOCK_BIN="$TEST_DIR/bin"
MOCK_VOLUMES="$TEST_DIR/Volumes"
MOCK_REPO="$TEST_DIR/repo"
MOCK_EFI_PARTITION="$MOCK_VOLUMES/EFI"

# Clean up previous run
rm -rf "$TEST_DIR"
mkdir -p "$MOCK_BIN"
mkdir -p "$MOCK_VOLUMES"
mkdir -p "$MOCK_REPO/BOOTEFIX64/EFI/BOOT"
mkdir -p "$MOCK_REPO/BOOTEFIX64/EFI/OC"

# Create dummy source files
touch "$MOCK_REPO/BOOTEFIX64/EFI/BOOT/BOOTx64.efi"
touch "$MOCK_REPO/BOOTEFIX64/EFI/OC/OpenCore.efi"

# Add mock bin to PATH
export PATH="$PWD/$MOCK_BIN:$PATH"

# --- Mock Commands ---

# Mock diskutil
cat << 'EOF' > "$MOCK_BIN/diskutil"
#!/bin/sh
if [ "$1" = "list" ]; then
    echo "/dev/disk0 (GUID Partition Scheme)"
    echo "   1: EFI EFI                     209.7 MB  disk0s1"
    echo "   2: Apple_APFS Container        100.0 GB  disk0s2"
elif [ "$1" = "info" ]; then
    echo "   Device Node:               /dev/disk0s1"
elif [ "$1" = "mount" ]; then
    echo "Volume EFI on disk0s1 mounted"
else
    echo "diskutil mock: unknown command $1"
fi
EOF
chmod +x "$MOCK_BIN/diskutil"

# Mock mount (for check)
cat << EOF > "$MOCK_BIN/mount"
#!/bin/sh
echo "/dev/disk0s1 on $MOCK_VOLUMES/EFI (msdos, local, nodev, nosuid, noowners)"
EOF
chmod +x "$MOCK_BIN/mount"

# Mock nvram
cat << 'EOF' > "$MOCK_BIN/nvram"
#!/bin/sh
echo "nvram: clearing..."
EOF
chmod +x "$MOCK_BIN/nvram"

# Mock shutdown
cat << 'EOF' > "$MOCK_BIN/shutdown"
#!/bin/sh
echo "shutdown: system halting..."
EOF
chmod +x "$MOCK_BIN/shutdown"

# --- Run Test ---

echo "Running restore.sh in test environment..."

# We need to modify restore.sh slightly to run in our test env (paths)
# or we can just symlink our mock repo to where the script expects it.
# The script expects ./BOOTEFIX64/EFI relative to CWD.

# Copy restore.sh to test dir
# We assume restore.sh is in the parent directory
if [ ! -f "../restore.sh" ]; then
    echo "Error: ../restore.sh not found!"
    exit 1
fi

cp ../restore.sh "$TEST_DIR/restore.sh"
chmod +x "$TEST_DIR/restore.sh"

# Create the expected repo structure in the test dir
cp -R "$MOCK_REPO/BOOTEFIX64" "$TEST_DIR/"

# Create a fake existing EFI to test backup/rename
mkdir -p "$MOCK_EFI_PARTITION/EFI/BOOT"
mkdir -p "$MOCK_EFI_PARTITION/EFI/OC"
touch "$MOCK_EFI_PARTITION/EFI/BOOT/old_boot.efi"
touch "$MOCK_EFI_PARTITION/EFI/OC/old_oc.efi"

# We need to trick the script into thinking /Volumes/EFI is our mock volume
# The script uses absolute path /Volumes/EFI.
# We use sed to patch the script for testing.

# When running restore.sh, we are inside TEST_DIR.
# So the path to Volumes is just ./Volumes
RUNTIME_MOCK_VOLUMES="./Volumes"

# Replace /Volumes/EFI with our mock path
# Use | as delimiter to avoid escaping slashes
sed "s|/Volumes/EFI|$RUNTIME_MOCK_VOLUMES/EFI|g" "$TEST_DIR/restore.sh" > "$TEST_DIR/restore.sh.tmp"
mv "$TEST_DIR/restore.sh.tmp" "$TEST_DIR/restore.sh"

# Replace /Volumes/EFI_BACKUP with our mock path
sed "s|/Volumes/EFI_BACKUP|$RUNTIME_MOCK_VOLUMES/EFI_BACKUP|g" "$TEST_DIR/restore.sh" > "$TEST_DIR/restore.sh.tmp"
mv "$TEST_DIR/restore.sh.tmp" "$TEST_DIR/restore.sh"

# Also update the mock mount script to return the path relative to CWD or absolute
# Since we are inside TEST_DIR, ./Volumes/EFI is correct.
cat << EOF > "$MOCK_BIN/mount"
#!/bin/sh
echo "/dev/disk0s1 on $RUNTIME_MOCK_VOLUMES/EFI (msdos, local, nodev, nosuid, noowners)"
EOF
chmod +x "$MOCK_BIN/mount"

chmod +x "$TEST_DIR/restore.sh"

# Run the script
# We pipe "y" to confirm the prompt, and "enter" for the final prompt
cd "$TEST_DIR"
printf "y\n\n" | ./restore.sh

EXIT_CODE=$?

# --- Assertions ---

echo ""
echo "--- Test Results ---"

if [ $EXIT_CODE -eq 0 ]; then
    echo "[PASS] Script exited with 0"
else
    echo "[FAIL] Script exited with $EXIT_CODE"
fi

# Check if backup was created
# We are inside TEST_DIR now, so use relative paths
BACKUP_COUNT=$(ls -d Volumes/EFI_BACKUP_* 2>/dev/null | wc -l)
if [ "$BACKUP_COUNT" -ge 1 ]; then
    echo "[PASS] Backup directory created"
else
    echo "[FAIL] Backup directory NOT created"
fi

# Check if new files exist
if [ -f "Volumes/EFI/EFI/BOOT/BOOTx64.efi" ]; then
    echo "[PASS] New BOOTx64.efi found"
else
    echo "[FAIL] New BOOTx64.efi NOT found"
fi

# Check if old files were renamed
OLD_BOOT_COUNT=$(ls -d Volumes/EFI/EFI/BOOT_OLD_* 2>/dev/null | wc -l)
if [ "$OLD_BOOT_COUNT" -ge 1 ]; then
    echo "[PASS] Old BOOT folder renamed"
else
    echo "[FAIL] Old BOOT folder NOT renamed"
fi

echo "--- End Test ---"
