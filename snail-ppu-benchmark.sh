#!/bin/bash

evalscope="/usr/local/anaconda3/envs/evalscope/bin/evalscope"



# 解析命令行参数
while getopts "s:m:t:u:l:c:h" opt; do
    case $opt in
        s) serverName="$OPTARG" ;;
        m) model="$OPTARG" ;;
        t) tokenizerPath="$OPTARG" ;;
        u) url="$OPTARG" ;;
        l) maxModelLen="$OPTARG" ;;
        c) cards="$OPTARG" ;;
        h) echo "Usage: $0 -s <server_name> -m <model> -t [tokenizer_path] -u <url> -l [max_model_len] -c [cards]"; exit 0 ;;
        ?) echo "Invalid option"; exit 1 ;;
    esac
done

shift $((OPTIND-1))

# 如果不携带ecToken则无法获取利用率,如果是调用apikey的模型不需要加-t
if   [ -z "$serverName" ] || [ -z "$model" ] || [ -z "$url" ]  ; then
    echo "Error: Missing required arguments"
    echo "Usage: $0 -s <server_name> -m <model> -t [tokenizer_path] -u <url> -l [max_model_len] -c [cards]"
    exit 1
fi


modelName=$(basename "$model")


# 获取原始用户目录，考虑sudo权限
if [ -n "$SUDO_USER" ]; then
    original_home=$(getent passwd "$SUDO_USER" | cut -d: -f6)
else
    original_home="$HOME"
fi



IsContinue(){
    local desc=$1
    local current_parallel=$2
    local curr_file
    local history_file
    local prev_concurrency

    echo "IsContinue: desc=$desc, current_parallel=$current_parallel"

    curr_file="$original_home/outputs/${serverName}/${desc}_${current_parallel}/${modelName}/benchmark.log"

    # 当前文件必须存在（刚测完）
    if [ ! -f "$curr_file" ]; then
        echo "Error: Current result file missing: $curr_file"
        return 1
    fi

    if [ "$current_parallel" -gt 1024 ];then
        prev_concurrency=$((current_parallel - 256))
    else 
        prev_concurrency=$((current_parallel / 2)) 
    fi

    history_file="$original_home/outputs/${serverName}/${desc}_${prev_concurrency}/${modelName}/benchmark.log"

    echo "curr_file: $curr_file"
    echo "history_file: $history_file"

    # 历史文件不存在时，不报错，继续下一档
    if [ ! -f "$history_file" ]; then
        echo "No history file for concurrency $prev_concurrency (first doubling), continue."
        return 0
    fi

    # 提取吞吐量
    local curr_throughput
    local history_throughput
    curr_throughput=$(tail -n 100 "$curr_file" | sed -nE 's/\|\s+Total\s+token\s+throughput\s+\(tok\/s\)\s+\|\s+(.*?)\s+\|/\1/p' | tr -d ',')
    history_throughput=$(tail -n 100 "$history_file" | sed -nE 's/\|\s+Total\s+token\s+throughput\s+\(tok\/s\)\s+\|\s+(.*?)\s+\|/\1/p' | tr -d ',')

    echo "curr_throughput: $curr_throughput   history_throughput: $history_throughput"

    if [ -z "$curr_throughput" ] || [ -z "$history_throughput" ]; then
        echo "Error: Failed to extract throughput"
        return 1
    fi

    if [ $(qalc -t "$curr_throughput > $history_throughput") == "true" ]; then
        echo "Throughput increased, continue."
        return 0
    else
        echo "Throughput did not increase, stop."
        return 1
    fi
}

####### save result function #########/

weekly=$(date +W%V-%g)

mkdir -p "$original_home/result/$weekly" &>/dev/null

result_file="$original_home/result/$weekly/${serverName}_result.txt"

save_result(){
    local describe=$1
    local desc=$2
    local file_path=$3

    local benchmark_file="$file_path/benchmark.log"
    local performance_summary="$file_path/performance_summary.txt"

    {
        echo "###### $describe $desc ######" 

        echo ""
        if [ -f "$benchmark_file" ] ; then
            if [ "$describe" == "SLO" ];then
                grep -Pv '^[0-9]{4}-[0-9]{2}-[0-9]{2}\s+[0-9]{2}:[0-9]{2}:[0-9]{2}.*|".*?":\s+.*?,?|\s*[{}\[\]],?' "$benchmark_file"
            else
                sed -n '/^Benchmarking summary:/,$p' "$benchmark_file"
            fi
        else
            echo "No Benchmarking summary found in $benchmark_file"
        fi        

        echo ""
        if [ -f "$performance_summary" ]; then
            cat "$performance_summary"
        else
            echo "Performance summary not found: $performance_summary"
        fi

        echo ""
        echo "----------------------------------------"
    } | tee -a "$result_file"
}

####### save result function #########\


backdir(){
    local dir=$1
    local timestamp
    timestamp=$(date '+%Y%m%d%H%M')

    if [ -d "$dir" ]; then
        mv "$dir" "$dir-$timestamp"
    fi
}



timepoints(){
    date '+%Y-%m-%d %H:%M:%S'
}



echo "$model max_model_len=$maxModelLen" | tee -a "$result_file"


############# evalscope Fixed ##############/
evalscopePerf_fixed(){
    local parallel=$1
    local inputLength=$2
    local outputLength=$3
    local prefixLength=${4:-0}
    local desc=$5
    local output_dir=$6


    $evalscope perf --model "$model" \
    --api openai \
    --api-key "$apiKey" \
    --tokenizer-path "$tokenizerPath" \
    --url "$url" \
    -n $((parallel * 10)) \
    --prefix-length "$prefixLength" \
    --parallel "$parallel" \
    --min-prompt-length "$inputLength" \
    --max-prompt-length "$inputLength" \
    --dataset random \
    --min-tokens "$outputLength" \
    --max-tokens "$outputLength" \
    --outputs-dir "$output_dir" \
    --no-timestamp \
    --extra-args '{"ignore_eos": true}' \
    --total-timeout 3600 \
    --read-timeout 1800
}


auto_evalscopePerf_fixed(){
  local parallel=$1
  local inputLength=$2
  local outputLength=$3
  local prefixLength=${4:-0}
  local desc=$5
  local output_dir="$original_home/outputs/${serverName}/${desc}_${parallel}"
  local totalLength
  
  totalLength=$((inputLength + outputLength + prefixLength))
  if [ "$totalLength"  -gt "$maxModelLen" ]; then
    echo "Warn: max_model_len=${maxModelLen}, total_length=${totalLength},$desc test skipped"
    return 6
  fi

  while true; do
      local startTime=$(timepoints)
      echo ">>> Running evalscope for short, parallel=$parallel, output_dir=$output_dir"
  
      #cmd
      evalscopePerf_fixed "$parallel" "$inputLength" "$outputLength" "$prefixLength" "$desc" "$output_dir" 

      local endTime=$(timepoints)
      echo ">>> evalscope finished for parallel=$parallel"

      save_result "Fixed" "${desc}_${parallel}" "$original_home/outputs/${serverName}/${desc}_${parallel}/${modelName}"
  
      # 判断是否继续（基于刚测完的并发数）
      IsContinue "$desc" "$parallel" || break
  
      # 翻倍并发，准备下一次测试
      if [[ $parallel -lt 1024 ]]; then
          parallel=$((parallel * 2))
      else 
          parallel=$((parallel + 256))
      fi
      
      output_dir="$original_home/outputs/${serverName}/${desc}_${parallel}"
  done
}
############# evalscope Fixed ##############\


############# evalscope SLO ##############/
evalscopePerf_slo(){
  local inputLength=$1
  local outputLength=$2
  local prefixLength=${3:-0}
  local desc=$4
  local sla_params=$5
  local output_dir=$6

  $evalscope perf --model "$model" \
      --api openai \
      --api-key "$apiKey" \
      --tokenizer-path "$tokenizerPath" \
      --url "$url" \
      --dataset random \
      --min-prompt-length "$inputLength" \
      --max-prompt-length "$inputLength" \
      --min-tokens "$outputLength" \
      --max-tokens "$outputLength" \
      --prefix-length "$prefixLength" \
      --sla-auto-tune \
      --sla-variable parallel \
      --sla-params "$sla_params" \
      --outputs-dir  "$output_dir" \
      --no-timestamp \
      --extra-args '{"ignore_eos": true}' \
      --total-timeout 3600 \
      --read-timeout 1800
}

auto_evalscopePerf_slo(){
  local inputLength=$1
  local outputLength=$2
  local prefixLength=${3:-0}
  local desc=$4
  local sla_params=$5
  local output_dir="$original_home/slo_outputs/${serverName}/${desc}"


  totalLength=$((inputLength + outputLength + prefixLength))
  if [ "$totalLength"  -gt "$maxModelLen" ]; then
    echo "Warn: max_model_len=${maxModelLen}, total_length=${totalLength},$desc test skipped"
    return 6
  fi
  
  local startTime=$(timepoints)
  echo ">>> Running evalscope for SLO  ${desc}, output_dir=$output_dir"
  
  #cmd
  evalscopePerf_slo "$inputLength" "$outputLength" "$prefixLength" "$desc" "$sla_params" "$output_dir"

  local endTime=$(timepoints)  
  echo ">>> evalscope finished for SLO ${desc}"
  
  save_result "SLO" "$desc" "$output_dir/${modelName}"

}

############# evalscope SLO ##############\




#============================ main ================================#


# 备份固定并发模型旧目录
backdir "$original_home/outputs/${serverName}"

# 固定并发
## ------------------ "short_0.5k-0.5k" ------------------
auto_evalscopePerf_fixed 32 512 512 0  'short_0.5k-0.5k'
## ------------------ "short_2k-1k" ------------------
auto_evalscopePerf_fixed 32 2048 1024 0  'short_2k-1k' 
## ------------------ "medium_8k-2k" ------------------
auto_evalscopePerf_fixed 16 8192 2048 0  'medium_8k-2k'  
## ------------------ "long_15k-2k" ------------------
auto_evalscopePerf_fixed 8 15360 2048 0  'long_15k-2k' 
## ------------------ "long_24k-2k" ------------------
auto_evalscopePerf_fixed 8 24576 2048 0  'long_24k-2k' 



# 备份SLO并发模型旧目录
backdir "$original_home/slo_outputs/${serverName}"

# SLO
## ------------------ "short_0.5k-0.5k" ------------------
auto_evalscopePerf_slo 512 512 0    "short_0.5k-0.5k"  '[{"p99_ttft": "<=1.0", "p99_tpot": "<=0.0667"}]'
## ------------------ "short_2k-1k" ------------------
auto_evalscopePerf_slo 2048 1024 0  "short_2k-1k"     '[{"p99_ttft": "<=1.0", "p99_tpot": "<=0.0667"}]'
## ------------------ "medium_8k-2k" ------------------
auto_evalscopePerf_slo 8192 2048 0 'medium_8k-2k'        '[{"p99_ttft": "<=3.0", "p99_tpot": "<=0.0667"}]'
## ------------------ "long_15k-2k" ------------------
auto_evalscopePerf_slo 15360 2048 0  'long_15k-2k'      '[{"p99_ttft": "<=5.0", "p99_tpot": "<=0.0667"}]'
## ------------------ "long_24k-2k" ------------------
auto_evalscopePerf_slo 24576 2048 0  'long_24k-2k'      '[{"p99_ttft": "<=5.0", "p99_tpot": "<=0.0667"}]'


echo "${serverName} testing completed!!!"
