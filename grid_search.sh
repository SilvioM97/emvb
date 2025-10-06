#!/bin/bash

set -euo pipefail

output_file=${1:-}
index_path=${2:-}

if [ -z "$output_file" ] || [ -z "$index_path" ]; then
        echo "Usage: $0 <output_tsv> <index_path>"
        exit 1
fi

# Header for the final TSV: configuration fields + avg_query_time (ns) + mrr@10 + recall@10
echo -e "k\tnprobe\tthresh\tthresh_query\tn_doc_to_score\tout_second_stage\tavg_query_time_ns\tmrr@10\trecall@10" > "$output_file"

# temporary ranking file reused for every run (keeps only one results file on disk)
tmp_ranking="temp_ranking.tsv"

# Parameters to sweep - only k=10
KS=(10)
NPROBES=(1 2 3)
THRESHES=(0.3 0.4 0.5)
THRESH_QUERY=(0.3 0.4 0.5) # m=16
#THRESH_QUERY=(0.4 0.5 0.6) # m=32
NDOCS=(200 500 1000)
OUTSECOND=(64 128 256)

# qrels and queries used for evaluation (relative to repo root)
QRELS="aux_data/msmarco/qrels.dev.tsv"
QUERIES="aux_data/msmarco/queries_dev_small_idonly.tsv"
ALLDOCLENS="aux_data/msmarco/doclens_msmarco.npy"

total_runs=0
for k in "${KS[@]}"; do
    for nprobe in "${NPROBES[@]}"; do
        for thresh in "${THRESHES[@]}"; do
            for thresh_query in "${THRESH_QUERY[@]}"; do
                for n_doc_to_score in "${NDOCS[@]}"; do
                    for out_second_stage in "${OUTSECOND[@]}"; do
                        total_runs=$((total_runs+1))
                    done
                done
            done
        done
    done
done

echo "Starting grid search: $total_runs runs"

run_idx=0
for k in "${KS[@]}"; do
    for nprobe in "${NPROBES[@]}"; do
        for thresh in "${THRESHES[@]}"; do
            for thresh_query in "${THRESH_QUERY[@]}"; do
                for n_doc_to_score in "${NDOCS[@]}"; do
                    for out_second_stage in "${OUTSECOND[@]}"; do
                        run_idx=$((run_idx+1))
                        echo "[${run_idx}/${total_runs}] Running: k=$k nprobe=$nprobe thresh=$thresh thresh_query=$thresh_query n_doc_to_score=$n_doc_to_score out_second_stage=$out_second_stage"

                        # Run search and capture stdout+stderr. perf_emvb prints "Average Elapsed Time per query <ns>" to stdout.
                        perf_output=$(./build/perf_emvb -k $k -nprobe $nprobe -thresh $thresh -out-second-stage $out_second_stage -thresh-query $thresh_query -n-doc-to-score $n_doc_to_score -queries-id-file $QUERIES -alldoclens-path $ALLDOCLENS -index-dir-path $index_path -out-file $tmp_ranking 2>&1 || true)

                        # Extract average query time in nanoseconds from perf_emvb output
                        avg_ns=$(echo "$perf_output" | grep -oP "Average Elapsed Time per query \K[0-9]+" || true)

                        # Run metrics computation and capture its stdout
                        mrr_output=$(python compute_mrr.py --qrels $QRELS --ranking $tmp_ranking 2>&1 || true)

                        # Extract MRR@10 and Recall@10 for "only for ranked queries" from compute_mrr.py output
                        mrr10=$(echo "$mrr_output" | grep "MRR@10 (only for ranked queries)" | head -n1 | awk -F"=" '{print $2}' | tr -d ' ' || true)
                        recall10=$(echo "$mrr_output" | grep "Recall@10 (only for ranked queries)" | head -n1 | awk -F"=" '{print $2}' | tr -d ' ' || true)

                        # If the '(only for ranked queries)' lines are missing, fall back to the overall values
                        if [ -z "$mrr10" ] || [ "$mrr10" = "" ]; then
                            mrr10=$(echo "$mrr_output" | grep "MRR@10 =" | head -n1 | awk -F"=" '{print $2}' | tr -d ' ' || true)
                        fi
                        if [ -z "$recall10" ] || [ "$recall10" = "" ]; then
                            recall10=$(echo "$mrr_output" | grep "Recall@10 =" | head -n1 | awk -F"=" '{print $2}' | tr -d ' ' || true)
                        fi

                        # Fallbacks if parsing failed
                        if [ -z "$avg_ns" ]; then avg_ns="NA"; fi
                        if [ -z "$mrr10" ]; then mrr10="NA"; fi
                        if [ -z "$recall10" ]; then recall10="NA"; fi

                        # Append one TSV line and flush to disk so it's immediately visible
                        echo -e "${k}\t${nprobe}\t${thresh}\t${thresh_query}\t${n_doc_to_score}\t${out_second_stage}\t${avg_ns}\t${mrr10}\t${recall10}" >> "$output_file"
                        sync "$output_file" || true

                        # small delay to avoid hammering I/O
                        sleep 0.05

                    done
                done
            done
        done
    done
done

echo "Grid search finished. Results saved to $output_file"

