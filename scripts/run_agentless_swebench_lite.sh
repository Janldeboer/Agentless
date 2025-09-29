#!/usr/bin/env bash

set -euo pipefail

# Run all Agentless steps for SWE-Bench (Lite or Verified)
#
# Usage (examples):
#   bash scripts/run_agentless_swebench_lite.sh \
#     --project-file-loc "/absolute/path/to/swebench_lite_repo_structure" \
#     --dataset "princeton-nlp/SWE-bench_Lite" \
#     --target-id "django__django-10914" \
#     --threads 10
#
# Key flags:
#   --project-file-loc PATH   Required. Local path to preprocessed repo structure; exported as PROJECT_FILE_LOC.
#   --dataset DATASET         Optional. Default: princeton-nlp/SWE-bench_Lite. Use .../SWE-bench_Verified for Verified.
#   --target-id ID            Optional. Run only for a single SWE-bench instance ID.
#   --results-dir DIR         Optional. Default computed from dataset (results/swe-bench-lite or results/swe-bench-verified).
#   --threads N               Optional. Default 10. Used across most steps.
#   --repair-threads N        Optional. Default 2. Parallelism per repair run.
#   --top-n N                 Optional. Default 3. Number of files/elements to keep.
#   --edit-loc-samples N      Optional. Default 4. Sets of edit locations to generate.
#   --repair-samples N        Optional. Default 10. Patches per repair run (1 greedy + N-1 sampled).
#   --repro-samples N         Optional. Default 40. Reproduction test samples (1 greedy + N-1 sampled).
#   --persist-dir DIR         Optional. Default embedding/swe-bench_simple. Where embeddings index persists.
#   --no-skip-existing        Optional. By default, we add --skip_existing to localization steps; this disables that.
#
# Requirements:
#   - OPENAI_API_KEY must be exported in your shell environment.
#   - Python env with requirements installed. Run from repo root.

print_usage() {
  sed -n '1,80p' "$0" | sed -n '1,80p' | sed 's/^# \{0,1\}//' | sed '1,1d'
}

# Defaults
DATASET="princeton-nlp/SWE-bench_Lite"
TARGET_ID=""
RESULTS_DIR=""
THREADS=10
REPAIR_THREADS=2
TOP_N=3
EDIT_LOC_SAMPLES=4
REPAIR_SAMPLES=10
REPRO_SAMPLES=40
PERSIST_DIR="embedding/swe-bench_simple"
SKIP_EXISTING=1
PROJECT_FILE_LOC_INPUT=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --project-file-loc)
      PROJECT_FILE_LOC_INPUT=${2:-}
      shift 2
      ;;
    --dataset)
      DATASET=${2:-}
      shift 2
      ;;
    --target-id)
      TARGET_ID=${2:-}
      shift 2
      ;;
    --results-dir)
      RESULTS_DIR=${2:-}
      shift 2
      ;;
    --threads)
      THREADS=${2:-}
      shift 2
      ;;
    --repair-threads)
      REPAIR_THREADS=${2:-}
      shift 2
      ;;
    --top-n)
      TOP_N=${2:-}
      shift 2
      ;;
    --edit-loc-samples)
      EDIT_LOC_SAMPLES=${2:-}
      shift 2
      ;;
    --repair-samples)
      REPAIR_SAMPLES=${2:-}
      shift 2
      ;;
    --repro-samples)
      REPRO_SAMPLES=${2:-}
      shift 2
      ;;
    --persist-dir)
      PERSIST_DIR=${2:-}
      shift 2
      ;;
    --no-skip-existing)
      SKIP_EXISTING=0
      shift 1
      ;;
    -h|--help)
      print_usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      print_usage
      exit 1
      ;;
  esac
done

# Validate required inputs
if [[ -z "${PROJECT_FILE_LOC_INPUT}" ]]; then
  echo "[ERROR] --project-file-loc is required (path to preprocessed SWE-bench repo structure)." >&2
  exit 1
fi
if [[ -z "${OPENAI_API_KEY:-}" ]]; then
  echo "[ERROR] OPENAI_API_KEY is not set. Please export it before running." >&2
  exit 1
fi

# Compute repo root and move there to ensure relative paths work
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${REPO_ROOT}"

export PYTHONPATH="${PYTHONPATH:-}:${REPO_ROOT}"
export PROJECT_FILE_LOC="${PROJECT_FILE_LOC_INPUT}"

# Compute default results dir if not provided
if [[ -z "${RESULTS_DIR}" ]]; then
  if [[ "${DATASET}" == *"Verified"* ]]; then
    RESULTS_DIR="results/swe-bench-verified"
  else
    RESULTS_DIR="results/swe-bench-lite"
  fi
fi

mkdir -p "${RESULTS_DIR}" "${PERSIST_DIR}"

DATASET_FLAG=("--dataset=${DATASET}")
TARGET_ID_FLAG=()
TARGET_INSTANCE_FLAG=()
if [[ -n "${TARGET_ID}" ]]; then
  # Many scripts accept --target_id (single), but test runners expect --instance_ids (variadic)
  TARGET_ID_FLAG=("--target_id=${TARGET_ID}")
  TARGET_INSTANCE_FLAG=("--instance_ids" "${TARGET_ID}")
fi
SKIP_FLAG=()
if [[ ${SKIP_EXISTING} -eq 1 ]]; then
  SKIP_FLAG=("--skip_existing")
fi

info() { echo "[INFO] $*"; }
run() {
  echo "+ $*"
  "$@"
}

# Paths used across steps
FILE_LEVEL_DIR="${RESULTS_DIR}/file_level"
IRRELEVANT_DIR="${RESULTS_DIR}/file_level_irrelevant"
RETRIEVAL_DIR="${RESULTS_DIR}/retrievel_embedding"
COMBINED_DIR="${RESULTS_DIR}/file_level_combined"
RELATED_DIR="${RESULTS_DIR}/related_elements"
EDIT_SAMPLES_DIR="${RESULTS_DIR}/edit_location_samples"
EDIT_INDIVIDUAL_DIR="${RESULTS_DIR}/edit_location_individual"

mkdir -p "${FILE_LEVEL_DIR}" "${IRRELEVANT_DIR}" "${RETRIEVAL_DIR}" \
         "${COMBINED_DIR}" "${RELATED_DIR}" "${EDIT_SAMPLES_DIR}" "${EDIT_INDIVIDUAL_DIR}"

info "Dataset=${DATASET}; Results dir=${RESULTS_DIR}; Target ID='${TARGET_ID}'"
info "PROJECT_FILE_LOC='${PROJECT_FILE_LOC}'"

#############################
# 1) Localize suspicious files
#############################
info "Step 1.1: File-level localization (LLM)"
run python agentless/fl/localize.py \
  --file_level \
  --output_folder "${FILE_LEVEL_DIR}" \
  --num_threads "${THREADS}" \
  ${SKIP_FLAG[@]+"${SKIP_FLAG[@]}"} \
  ${DATASET_FLAG[@]+"${DATASET_FLAG[@]}"} \
  ${TARGET_ID_FLAG[@]+"${TARGET_ID_FLAG[@]}"}

info "Step 1.2: Identify irrelevant folders"
run python agentless/fl/localize.py \
  --file_level \
  --irrelevant \
  --output_folder "${IRRELEVANT_DIR}" \
  --num_threads "${THREADS}" \
  ${SKIP_FLAG[@]+"${SKIP_FLAG[@]}"} \
  ${DATASET_FLAG[@]+"${DATASET_FLAG[@]}"} \
  ${TARGET_ID_FLAG[@]+"${TARGET_ID_FLAG[@]}"}

info "Step 1.3: Retrieve additional suspicious files via embeddings"
run python agentless/fl/retrieve.py \
  --index_type simple \
  --filter_type given_files \
  --filter_file "${IRRELEVANT_DIR}/loc_outputs.jsonl" \
  --output_folder "${RETRIEVAL_DIR}" \
  --persist_dir "${PERSIST_DIR}" \
  --num_threads "${THREADS}" \
  ${DATASET_FLAG[@]+"${DATASET_FLAG[@]}"} \
  ${TARGET_ID_FLAG[@]+"${TARGET_ID_FLAG[@]}"}

info "Step 1.4: Combine retrieved + LLM-predicted files"
run python agentless/fl/combine.py \
  --retrieval_loc_file "${RETRIEVAL_DIR}/retrieve_locs.jsonl" \
  --model_loc_file "${FILE_LEVEL_DIR}/loc_outputs.jsonl" \
  --top_n "${TOP_N}" \
  --output_folder "${COMBINED_DIR}"

#############################################
# 2) Localize to related elements
#############################################
info "Step 2: Related elements localization"
run python agentless/fl/localize.py \
  --related_level \
  --output_folder "${RELATED_DIR}" \
  --top_n "${TOP_N}" \
  --compress_assign \
  --compress \
  --start_file "${COMBINED_DIR}/combined_locs.jsonl" \
  --num_threads "${THREADS}" \
  ${SKIP_FLAG[@]+"${SKIP_FLAG[@]}"} \
  ${DATASET_FLAG[@]+"${DATASET_FLAG[@]}"} \
  ${TARGET_ID_FLAG[@]+"${TARGET_ID_FLAG[@]}"}

#############################################
# 3) Localize to fine-grained edit locations
#############################################
info "Step 3.1: Fine-grain edit location sampling (${EDIT_LOC_SAMPLES} samples)"
run python agentless/fl/localize.py \
  --fine_grain_line_level \
  --output_folder "${EDIT_SAMPLES_DIR}" \
  --top_n "${TOP_N}" \
  --compress \
  --temperature 0.8 \
  --num_samples "${EDIT_LOC_SAMPLES}" \
  --start_file "${RELATED_DIR}/loc_outputs.jsonl" \
  --num_threads "${THREADS}" \
  ${SKIP_FLAG[@]+"${SKIP_FLAG[@]}"} \
  ${DATASET_FLAG[@]+"${DATASET_FLAG[@]}"} \
  ${TARGET_ID_FLAG[@]+"${TARGET_ID_FLAG[@]}"}

info "Step 3.2: Merge edit location samples into individual sets"
run python agentless/fl/localize.py \
  --merge \
  --output_folder "${EDIT_INDIVIDUAL_DIR}" \
  --top_n "${TOP_N}" \
  --num_samples "${EDIT_LOC_SAMPLES}" \
  --start_file "${EDIT_SAMPLES_DIR}/loc_outputs.jsonl"

#############################
# 4) Repair for each edit-location set
#############################
info "Step 4: Repair (per edit-location set)"
for ((i=0; i<EDIT_LOC_SAMPLES; i++)); do
  idx=$i
  num=$((i+1))
  LOC_FILE="${EDIT_INDIVIDUAL_DIR}/loc_merged_${idx}-${idx}_outputs.jsonl"
  REPAIR_DIR="${RESULTS_DIR}/repair_sample_${num}"
  mkdir -p "${REPAIR_DIR}"

  run python agentless/repair/repair.py \
    --loc_file "${LOC_FILE}" \
    --output_folder "${REPAIR_DIR}" \
    --loc_interval \
    --top_n "${TOP_N}" \
    --context_window 10 \
    --max_samples "${REPAIR_SAMPLES}" \
    --cot \
    --diff_format \
    --gen_and_process \
    --num_threads "${REPAIR_THREADS}" \
    ${DATASET_FLAG[@]+"${DATASET_FLAG[@]}"} \
    ${TARGET_ID_FLAG[@]+"${TARGET_ID_FLAG[@]}"}
done

######################################################
# 5) Patch validation: Regression tests (selection + run)
######################################################
info "Step 5.1: List passing tests in original codebase"
run python agentless/test/run_regression_tests.py \
  --run_id generate_regression_tests \
  --output_file "${RESULTS_DIR}/passing_tests.jsonl" \
  ${DATASET_FLAG[@]+"${DATASET_FLAG[@]}"} \
  ${TARGET_INSTANCE_FLAG[@]+"${TARGET_INSTANCE_FLAG[@]}"}

info "Step 5.2: LLM-assisted selection of regression tests"
run python agentless/test/select_regression_tests.py \
  --passing_tests "${RESULTS_DIR}/passing_tests.jsonl" \
  --output_folder "${RESULTS_DIR}/select_regression" \
  ${DATASET_FLAG[@]+"${DATASET_FLAG[@]}"} \
  ${TARGET_ID_FLAG[@]+"${TARGET_ID_FLAG[@]}"}

info "Step 5.3: Run selected regression tests against each candidate patch"
for num in $(seq 0 $((REPAIR_SAMPLES-1))); do
  for sample in $(seq 1 ${EDIT_LOC_SAMPLES}); do
    folder="${RESULTS_DIR}/repair_sample_${sample}"
    run_id_prefix="$(basename "$folder")"
    run python agentless/test/run_regression_tests.py \
      --regression_tests "${RESULTS_DIR}/select_regression/output.jsonl" \
      --predictions_path="${folder}/output_${num}_processed.jsonl" \
      --run_id="${run_id_prefix}_regression_${num}" \
      --num_workers "${THREADS}" \
      ${DATASET_FLAG[@]+"${DATASET_FLAG[@]}"} \
      ${TARGET_INSTANCE_FLAG[@]+"${TARGET_INSTANCE_FLAG[@]}"}
  done
done

######################################################
# 6) Reproduction tests: generate, run, select, evaluate patches
######################################################
info "Step 6.1: Generate reproduction tests (${REPRO_SAMPLES} samples)"
run python agentless/test/generate_reproduction_tests.py \
  --max_samples "${REPRO_SAMPLES}" \
  --output_folder "${RESULTS_DIR}/reproduction_test_samples" \
  --num_threads "${THREADS}" \
  ${DATASET_FLAG[@]+"${DATASET_FLAG[@]}"} \
  ${TARGET_ID_FLAG[@]+"${TARGET_ID_FLAG[@]}"}

info "Step 6.2: Execute generated reproduction tests on original repo (sequential)"
for num in $(seq 0 $((REPRO_SAMPLES-1))); do
  run python agentless/test/run_reproduction_tests.py \
    --run_id="reproduction_test_generation_filter_sample_${num}" \
    --test_jsonl="${RESULTS_DIR}/reproduction_test_samples/output_${num}_processed_reproduction_test.jsonl" \
    --num_workers "${THREADS}" \
    --testing \
    ${DATASET_FLAG[@]+"${DATASET_FLAG[@]}"} \
    ${TARGET_INSTANCE_FLAG[@]+"${TARGET_INSTANCE_FLAG[@]}"}
done

info "Step 6.3: Majority vote selection of reproduction tests"
run python agentless/test/generate_reproduction_tests.py \
  --max_samples "${REPRO_SAMPLES}" \
  --output_folder "${RESULTS_DIR}/reproduction_test_samples" \
  --output_file reproduction_tests.jsonl \
  --select \
  ${DATASET_FLAG[@]+"${DATASET_FLAG[@]}"} \
  ${TARGET_ID_FLAG[@]+"${TARGET_ID_FLAG[@]}"}

info "Step 6.4: Run selected reproduction tests against each candidate patch"
for num in $(seq 0 $((REPAIR_SAMPLES-1))); do
  for sample in $(seq 1 ${EDIT_LOC_SAMPLES}); do
    folder="${RESULTS_DIR}/repair_sample_${sample}"
    run_id_prefix="$(basename "$folder")"
    run python agentless/test/run_reproduction_tests.py \
      --test_jsonl "${RESULTS_DIR}/reproduction_test_samples/reproduction_tests.jsonl" \
      --predictions_path="${folder}/output_${num}_processed.jsonl" \
      --run_id="${run_id_prefix}_reproduction_${num}" \
      --num_workers "${THREADS}" \
      ${DATASET_FLAG[@]+"${DATASET_FLAG[@]}"} \
      ${TARGET_INSTANCE_FLAG[@]+"${TARGET_INSTANCE_FLAG[@]}"}
  done
done

######################################################
# 7) Rerank and patch selection
######################################################
info "Step 7: Rerank and select final patches"
PATCH_FOLDERS=()
for sample in $(seq 1 ${EDIT_LOC_SAMPLES}); do
  PATCH_FOLDERS+=("${RESULTS_DIR}/repair_sample_${sample}/")
done

IFS="," read -r -a PATCH_FOLDERS_CSV <<< "$(printf "%s," "${PATCH_FOLDERS[@]}")"
PATCH_FOLDERS_ARG="$(printf ",%s" "${PATCH_FOLDERS[@]}")"
PATCH_FOLDERS_ARG="${PATCH_FOLDERS_ARG:1}"

TOTAL_SAMPLES=$((EDIT_LOC_SAMPLES * REPAIR_SAMPLES))
run python agentless/repair/rerank.py \
  --patch_folder "${PATCH_FOLDERS_ARG}" \
  --num_samples "${TOTAL_SAMPLES}" \
  --deduplicate \
  --regression \
  --reproduction

info "Done. Final selections are in ${RESULTS_DIR} (see rerank outputs and per-run folders)."
