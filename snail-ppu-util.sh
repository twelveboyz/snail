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



# ansible ppu 
if ansible ppu -m ping ;then
    echo "ansible ppu ping ok"
else
    echo "ansible ppu ping failed"
    exit 1
fi

if ansible ppu -b --become-user=root -m copy -a "src=ppu_collect.sh dest=/tmp/ppu_collect.sh mode=0755" ; then
    echo "ansible ppu copy ppu_collect.sh ok"
else
    echo "ansible ppu copy ppu_collect.sh failed"
    exit 1
fi

if ansible ppu -b --become-user=root -m shell -a "chmod +x /tmp/ppu_collect.sh && /tmp/ppu_collect.sh start $cards 5" ; then
    echo "ansible ppu run ppu_collect.sh ok"
else
    echo "ansible ppu run ppu_collect.sh failed"
    exit 1
fi


ppu_usage(){
    local startTime=$1
    local endTime=$2
    ansible ppu -b --become-user=root -m shell -a "/tmp/ppu_utilization.log analyze $startTime $endTime" | tee -a "$result_file"
}


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



# get max_model_len url
MODELLEN_URL="${url%/v1/chat/completions}/v1/models" 

get_model_len() {
    curl -s --location "$MODELLEN_URL" \
        --header "Authorization: Bearer $apiKey" \
        --header 'Content-Type: application/json' \
    | jq '.data[0].max_model_len'
}

if [ -z "$maxModelLen" ]; then
    maxModelLen=$(get_model_len)

    if [ "$(echo "$maxModelLen" | jq -r 'type')" != "number" ]; then
        echo "Err: 获取max_model_len not number, $maxModelLen"
        exit 1
    fi
fi


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
  local buffer=0
  
  totalLength=$((inputLength + outputLength + prefixLength))
  if [ $((totalLength ))  -gt "$maxModelLen" ]; then
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

      echo ">>> ppu_usage ${desc}-${parallel} startTime: $startTime, endTime: $endTime "

      ppu_usage "$startTime" "$endTime"
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
  local buffer=0

  totalLength=$((inputLength + outputLength + prefixLength))
  if [ $((totalLength + buffer))  -gt "$maxModelLen" ]; then
    echo "Warn: max_model_len=${maxModelLen}, total_length=${totalLength},$desc test skipped"
    return 6
  fi
  
  local startTime=$(timepoints)
  echo ">>> Running evalscope for SLO  ${desc}, output_dir=$output_dir"
  
  #cmd
  evalscopePerf_slo "$inputLength" "$outputLength" "$prefixLength" "$desc" "$sla_params" "$output_dir"

  local endTime=$(timepoints)  
  echo ">>> evalscope finished for SLO ${desc}"

  echo ">>> ppu_usage ${desc} startTime: $startTime, endTime: $endTime"

  ppu_usage "$startTime" "$endTime"
  
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
## ------------------ "medium_4k-1k" ------------------
auto_evalscopePerf_fixed 16 4096 1024 0  'medium_4k-1k'   
## ------------------ "medium_8k-1k" ------------------
auto_evalscopePerf_fixed 16 8192 1024 0  'medium_8k-1k'  
## ------------------ "long_32k-1k" ------------------
auto_evalscopePerf_fixed 8 32768 1024 0  'long_32k-1k' 
## ------------------ "long_64k-1k" ------------------
auto_evalscopePerf_fixed 8 65536 1024 0  'long_64k-1k' 
## ------------------ "extra_long_128K-1k-90" ------------------ 13107 1024 117965-1000
prefix_cache_evalscopePerf 'extra_long_128K-1k-90' "auto_evalscopePerf_fixed 2 13107 1024 116965  extra_long_128K-1k-90"
## ------------------ "extra_long_1M-1k-90" ------------------104754 1024 942798-1000
prefix_cache_evalscopePerf 'extra_long_1M-1k-90'   "auto_evalscopePerf_fixed 2 104754 1024 941798 extra_long_1M-1k-90"
## ------------------ "extra_long_1M-1k-99" ------------------10475 1024 1037077-1000
prefix_cache_evalscopePerf 'extra_long_1M-1k-99'   "auto_evalscopePerf_fixed 2 10475 1024 1036077 extra_long_1M-1k-99"


# 备份SLO并发模型旧目录
backdir "$original_home/slo_outputs/${serverName}"

# SLO
## ------------------ "short_0.5k-0.5k" ------------------
auto_evalscopePerf_slo 512 512 0  "short_0.5k-0.5k"  '[{"p99_ttft": "<=3.0", "p99_tpot": "<=0.05"}]'
## ------------------ "short_2k-1k" ------------------
auto_evalscopePerf_slo 2048 1024 0  "short_2k-1k"     '[{"p99_ttft": "<=3.0", "p99_tpot": "<=0.05"}]'
## ------------------ "medium_4k-1k" ------------------
auto_evalscopePerf_slo 4096 1024 0  "medium_4k-1k"    '[{"p99_ttft": "<=5.0", "p99_tpot": "<=0.05"}]'
## ------------------ "medium_8k-1k" ------------------
auto_evalscopePerf_slo 8192 1024 0  "medium_8k-1k"      '[{"p99_ttft": "<=8.0", "p99_tpot": "<=0.05"}]'
## ------------------ "long_32k-1k" ------------------
auto_evalscopePerf_slo 32768 1024 0  "long_32k-1k"     '[{"p99_ttft": "<=10.0", "p99_tpot": "<=0.1"}]'
## ------------------ "long_64k-1k" ------------------
auto_evalscopePerf_slo 65536 1024 0  "long_64k-1k"     '[{"p99_ttft": "<=15.0", "p99_tpot": "<=0.1"}]'
## ------------------ "extra_long_128K-1k-90" ------------------  13107 1024 117965-1000
auto_evalscopePerf_slo 13107 1024 116965 extra_long_128K-1k-90 '[{"p99_ttft": "<=25.0", "p99_tpot": "<=0.15"}]'
## ------------------ "extra_long_1M-1k-90" ------------------ 104754 1024 942798-1000  
auto_evalscopePerf_slo 104754 1024 941798 extra_long_1M-1k-90 '[{"p99_ttft": "<=120.0", "p99_tpot": "<=0.2"}]'
## ------------------ "extra_long_1M-1k-99" ------------------10475 1024 1037077-1000
auto_evalscopePerf_slo 10475 1024 1036077 extra_long_1M-1k-99 '[{"p99_ttft": "<=120.0", "p99_tpot": "<=0.2"}]'



if ansible ppu -b --become-user=root -m shell -a "/tmp/ppu_collect.sh stop" ; then
    echo "ansible ppu run ppu_collect.sh stop ok"
else
    echo "ansible ppu run ppu_collect.sh stop failed"
    exit 1
fi

echo "${serverName} testing completed!!!"
