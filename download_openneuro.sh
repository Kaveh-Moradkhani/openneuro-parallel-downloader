#!/usr/bin/env bash
set -uo pipefail

# ── Defaults ───────────────────────────────────────────────────────────────────
DEST=""
DATASET_INPUT=""
MODALITY="T1w"
N_JOBS=15
DL_JOBS_PER_DS=8
DOWNLOAD_ALL=false

# ── Usage ──────────────────────────────────────────────────────────────────────
usage() {
  cat <<EOF

Usage:
  $(basename "$0") --dest <path> --datasets <ds1,ds2,...> [options]
  $(basename "$0") --dest <path> --datasets-file <file.txt> [options]

Required:
  --dest          Directory where datasets will be saved
  --datasets      Comma-separated list of OpenNeuro dataset IDs
                  e.g. ds000115,ds000144,ds002862
  --datasets-file Path to a plain text file with one dataset ID per line

Options:
  --modality      Which files to download (default: T1w)
                  Examples: T1w, T2w, bold, dwi
  --all           Download the entire dataset, not just one modality
  --jobs          Number of datasets to download in parallel (default: 15)
  --conn          Number of connections per dataset (default: 8)
  --help          Show this message

Examples:
  # Download only T1w images from 3 datasets
  $(basename "$0") --dest /data/openneuro --datasets ds000115,ds000144,ds002862

  # Download everything from a list of datasets
  $(basename "$0") --dest /data/openneuro --datasets-file my_datasets.txt --all

  # Download T2w images with custom parallelism
  $(basename "$0") --dest /data/openneuro --datasets ds000115 --modality T2w --jobs 4 --conn 4

EOF
  exit 0
}

# ── Parse arguments ────────────────────────────────────────────────────────────
if [[ $# -eq 0 ]]; then usage; fi

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dest)           DEST="$2";           shift 2 ;;
    --datasets)       DATASET_INPUT="$2";  shift 2 ;;
    --datasets-file)  DATASETS_FILE="$2";  shift 2 ;;
    --modality)       MODALITY="$2";       shift 2 ;;
    --all)            DOWNLOAD_ALL=true;   shift   ;;
    --jobs)           N_JOBS="$2";         shift 2 ;;
    --conn)           DL_JOBS_PER_DS="$2"; shift 2 ;;
    --help)           usage ;;
    *) echo "Unknown option: $1"; usage ;;
  esac
done

# ── Validate ───────────────────────────────────────────────────────────────────
if [[ -z "$DEST" ]]; then
  echo "Error: --dest is required."
  exit 1
fi

DATASETS=()
if [[ -n "$DATASET_INPUT" ]]; then
  IFS=',' read -ra DATASETS <<< "$DATASET_INPUT"
elif [[ -n "${DATASETS_FILE:-}" ]]; then
  if [[ ! -f "$DATASETS_FILE" ]]; then
    echo "Error: File not found: $DATASETS_FILE"
    exit 1
  fi
  mapfile -t DATASETS < "$DATASETS_FILE"
else
  echo "Error: Provide --datasets or --datasets-file."
  exit 1
fi

if [[ ${#DATASETS[@]} -eq 0 ]]; then
  echo "Error: No datasets found."
  exit 1
fi

# ── Setup ──────────────────────────────────────────────────────────────────────
LOG_DIR="$DEST/logs"
SUCCESS_FILE="$LOG_DIR/success.txt"
FAILED_FILE="$LOG_DIR/failed.txt"

mkdir -p "$LOG_DIR"
: > "$SUCCESS_FILE"
: > "$FAILED_FILE"

# ── Check dependencies ─────────────────────────────────────────────────────────
for cmd in datalad git parallel flock; do
  if ! command -v "$cmd" &>/dev/null; then
    echo "Error: '$cmd' is not installed or not in PATH."
    exit 1
  fi
done

# ── Core download function ─────────────────────────────────────────────────────
download_one() {
  local ds="$1"
  local DL_JOBS="$2"
  local MODALITY="$3"
  local DOWNLOAD_ALL="$4"
  local REPO_URL="https://github.com/OpenNeuroDatasets/${ds}.git"
  local OUTDIR="$DEST/$ds"
  local LOG_FILE="$LOG_DIR/${ds}.log"

  echo "[START] $ds at $(date)" | tee "$LOG_FILE"

  # Clone metadata
  if [[ ! -d "$OUTDIR/.git" ]]; then
    echo "[CLONE] $ds" | tee -a "$LOG_FILE"
    if ! datalad clone "$REPO_URL" "$OUTDIR" >> "$LOG_FILE" 2>&1; then
      echo "[FAILED] $ds clone" | tee -a "$LOG_FILE"
      flock "$FAILED_FILE" bash -c "echo '$ds (clone failed)' >> '$FAILED_FILE'"
      return 1
    fi
  else
    echo "[SKIP CLONE] $ds already cloned, resuming..." | tee -a "$LOG_FILE"
  fi

  cd "$OUTDIR" || return 1

  # Download all content or a specific modality
  if [[ "$DOWNLOAD_ALL" == "true" ]]; then
    echo "[GET] Downloading ALL files for $ds" | tee -a "$LOG_FILE"
    if ! datalad get -J "$DL_JOBS" -r . >> "$LOG_FILE" 2>&1; then
      echo "[FAILED] $ds get" | tee -a "$LOG_FILE"
      flock "$FAILED_FILE" bash -c "echo '$ds (get failed)' >> '$FAILED_FILE'"
      return 1
    fi
    datalad unlock -r . >> "$LOG_FILE" 2>&1 || \
      echo "[WARNING] unlock issue (data still ok)" | tee -a "$LOG_FILE"
    echo "[SUCCESS] $ds (full dataset) at $(date)" | tee -a "$LOG_FILE"
    flock "$SUCCESS_FILE" bash -c "echo '$ds (all files)' >> '$SUCCESS_FILE'"

  else
    # Find files matching the requested modality
    mapfile -t FILES < <(find . -path "*/anat/*_${MODALITY}.nii*" \
                                -o -path "*/func/*_${MODALITY}.nii*" \
                                -o -path "*/dwi/*_${MODALITY}.nii*" \
                                2>/dev/null)

    if [[ ${#FILES[@]} -eq 0 || -z "${FILES[0]:-}" ]]; then
      echo "[WARNING] No ${MODALITY} files found in $ds" | tee -a "$LOG_FILE"
      flock "$FAILED_FILE" bash -c "echo '$ds (no ${MODALITY} found)' >> '$FAILED_FILE'"
      return 1
    fi

    echo "[INFO] Found ${#FILES[@]} ${MODALITY} files — using $DL_JOBS connections" | tee -a "$LOG_FILE"

    if ! datalad get -J "$DL_JOBS" "${FILES[@]}" >> "$LOG_FILE" 2>&1; then
      echo "[FAILED] $ds get" | tee -a "$LOG_FILE"
      flock "$FAILED_FILE" bash -c "echo '$ds (get failed)' >> '$FAILED_FILE'"
      return 1
    fi

    datalad unlock "${FILES[@]}" >> "$LOG_FILE" 2>&1 || \
      echo "[WARNING] unlock issue (data still ok)" | tee -a "$LOG_FILE"

    # Verify files are real, not symlinks
    local real_count=0
    for f in "${FILES[@]}"; do
      [[ -f "$f" && ! -L "$f" ]] && ((real_count++))
    done
    echo "[VERIFY] $real_count/${#FILES[@]} real files (not symlinks)" | tee -a "$LOG_FILE"

    echo "[SUCCESS] $ds at $(date)" | tee -a "$LOG_FILE"
    flock "$SUCCESS_FILE" bash -c "echo '$ds (${#FILES[@]} ${MODALITY} files)' >> '$SUCCESS_FILE'"
  fi
}

export -f download_one
export DEST LOG_DIR SUCCESS_FILE FAILED_FILE

# ── Summary before starting ────────────────────────────────────────────────────
echo ""
echo "======================================================"
echo "OpenNeuro Dataset Downloader"
echo "======================================================"
echo "Destination  : $DEST"
echo "Datasets     : ${#DATASETS[@]}"
if [[ "$DOWNLOAD_ALL" == "true" ]]; then
echo "Modality     : ALL files"
else
echo "Modality     : $MODALITY only"
fi
echo "Parallel     : $N_JOBS datasets at once"
echo "Connections  : $DL_JOBS_PER_DS per dataset"
echo "Total conn   : $(( N_JOBS * DL_JOBS_PER_DS ))"
echo "======================================================"
echo ""

# ── Run ────────────────────────────────────────────────────────────────────────
printf '%s\n' "${DATASETS[@]}" | \
  parallel -j "$N_JOBS" --load 80% download_one {} "$DL_JOBS_PER_DS" "$MODALITY" "$DOWNLOAD_ALL"

# ── Final report ───────────────────────────────────────────────────────────────
echo ""
echo "======================================================"
echo "Completed at : $(date)"
echo "Successful   : $(wc -l < "$SUCCESS_FILE") / ${#DATASETS[@]} datasets"
echo "Failed       : $(wc -l < "$FAILED_FILE") datasets"
echo "Logs         : $LOG_DIR"
echo "======================================================"

if [[ $(wc -l < "$FAILED_FILE") -gt 0 ]]; then
  echo ""
  echo "Failed datasets:"
  cat "$FAILED_FILE"
fi
