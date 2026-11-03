#!/bin/bash

evalscope="/usr/local/anaconda3/envs/evalscope/bin/evalscope"

apiKey=$(cat .apiKey)


gen_headers() {
  # 0. 关键步骤：先清除旧值，防止Python脚本失败时沿用上次的结果
  unset X_Server_Param X_CurTime X_CheckSum AUTHORIZAION

  # 1. 生成头部
  OUTPUT=$(python gen_headers.py)
  
  # 2. 执行export命令（设置Shell变量）
  # 建议：检查OUTPUT是否为空，避免eval空命令
  if [ -z "$OUTPUT" ]; then
      echo "Error: gen_headers.py produced no output."
      exit 1
  fi
  eval "$OUTPUT"
  
  # 3. 验证环境变量（此时如果Python没跑通，变量一定是空的）
  if [ -z "$X_Server_Param" ] || [ -z "$X_CurTime" ] || [ -z "$X_CheckSum" ] || [ -z "$AUTHORIZAION" ]; then
    echo "X_Server_Param: $X_Server_Param"
    echo "X_CurTime: $X_CurTime"
    echo "X_CheckSum: $X_CheckSum"
    echo "AUTHORIZAION: $AUTHORIZAION"
    echo "err: args is nil"
    exit 1
  fi
}

gen_headers

# 解析命令行参数
while getopts "s:m:t:u:e:p:d:l:h" opt; do
    case $opt in
        s) serverName="$OPTARG" ;;
        m) model="$OPTARG" ;;
        t) tokenizerPath="$OPTARG" ;;
        u) url="$OPTARG" ;;
        e) ecToken="$OPTARG" ;;
        p) projectSpace="$OPTARG" ;;
        d) deployType="$OPTARG" ;;
        l) maxModelLen="$OPTARG" ;;
        h) echo "Usage: $0 -p [projectSpace] -d [deployType] -s <server_name> -m <model> -t [tokenizer_path] -u <url> -e [ecToken]"; exit 0 ;;
        ?) echo "Invalid option"; exit 1 ;;
    esac
done

shift $((OPTIND-1))

# 如果不携带ecToken则无法获取利用率,如果是调用apikey的模型不需要加-t
if   [ -z "$serverName" ] || [ -z "$model" ] || [ -z "$url" ]  ; then
    echo "Error: Missing required arguments"
    echo "Usage: $0 -p [projectSpace] -d [deployType] -s <server_name> -m <model> -t [tokenizer_path] -u <url> -e [ecToken]"
    echo "moma: snail.sh -p d008aipublic -d 0 -s qwen35-35b -m qwen3.5-35b -t Qwen/Qwen3.5-35B -u xxx -e xxx"
    echo "api:  snail.sh -s qwen35-35b -m qwen3.5-35b -t Qwen/Qwen3.5-35B -u xxx "
    exit 1
fi


modelName=$(basename "$model")


# 获取原始用户目录，考虑sudo权限
if [ -n "$SUDO_USER" ]; then
    original_home=$(getent passwd "$SUDO_USER" | cut -d: -f6)
else
    original_home="$HOME"
fi


# token不是空时
if [ "$ecToken" != "" ];then

  # 检查npu-usage命令是否存在
  if ! command -v npu-usage &>/dev/null; then
      echo "Warning: npu-usage not found."
      exit 1
  fi
  
  # 检查token是否有效
  if ! npu-usage -test "$ecToken" >/dev/null 2>&1; then
      echo "Error: Invalid ecToken: $ecToken"
      exit 1
  fi
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


######## npu-usage #########/
timepoints(){
    date '+%Y-%m-%d %H:%M:%S'
}

npu_monitor(){
    local project_space=$1
    local deploy_type=$2
    local server_name=$3
    local start_time=$4
    local end_time=$5
    local ecToken=$6
    
    if [ "$ecToken" != "" ];then
      npu-usage -project "$project_space" -deploy_type "$deploy_type" -server_name "$server_name" -start_time "$start_time" -end_time "$end_time"   -token "$ecToken" 2>&1   | tee -a "$result_file"
    fi
}

######## npu-usage #########\

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

# metrics url
METRICS_URL="${url%/v1/chat/completions}/metrics"

# get metrics（-f 使 HTTP 错误返回非零退出码）
get_Metrics() {
    curl -sf --location "$METRICS_URL" \
        --header "Authorization: Bearer $apiKey" \
        --header 'Content-Type: application/json'
}

# 满足测试缓存的模型必须获取到 metrics
CACHE_TEST_THRESHOLD=132096
if [ "$maxModelLen" -gt "$CACHE_TEST_THRESHOLD" ]; then
    if ! get_Metrics &>/dev/null; then
        echo "Err: get $model Metrics failed!"
        exit 1
    else
        echo "metrics normal!"
    fi
fi

echo "$model max_model_len=$maxModelLen" | tee -a "$result_file"

############# perfix cache code #############/
# 函数：获取当前缓存计数（返回 hit_tokens 和 request_tokens）
get_cache_counts() {
    local metrics_output
    metrics_output=$(get_Metrics)
    local hit=$(echo "$metrics_output" | grep '^vllm:prefix_cache_hits_total'    |  awk '{print $2}')
    local total=$(echo "$metrics_output" | grep '^vllm:prefix_cache_queries_total' |  awk '{print $2}')
    echo "$hit $total"
}


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
    --headers "X-Server-Param=$X_Server_Param" "X-CurTime=$X_CurTime" "X-CheckSum=$X_CheckSum" "AUTHORIZAION=$AUTHORIZAION" \
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
  local buffer=8
  
  totalLength=$((inputLength + outputLength + prefixLength))
  if [ $((totalLength + buffer))  -gt "$maxModelLen" ]; then
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

      echo ">>> npu_utilization ${desc}-${parallel} startTime: $startTime, endTime: $endTime "

      npu_monitor  "$projectSpace" "$deployType" "$serverName" "$startTime" "$endTime"  "$ecToken"
      save_result "Fixed" "${desc}_${parallel}" "$original_home/outputs/${serverName}/${desc}_${parallel}/${modelName}"
  
      # 判断是否继续（基于刚测完的并发数）
      IsContinue "$desc" "$parallel" || break
  
      # 翻倍并发，准备下一次测试
      if [[ $parallel -lt 1024 ]]; then
          parallel=$((parallel * 2))
      else 
          parallel=$((parallel + 256))
      fi

      if [ $parallel -gt 10 ] ; then
         echo "parallel $parallel > 10, break"
         break
      fi 
      
      output_dir="$original_home/outputs/${serverName}/${desc}_${parallel}"
  done
}
############# evalscope Fixed ##############\





#============================ main ================================#


# 备份固定并发模型旧目录
backdir "$original_home/outputs/${serverName}"

# 固定并发
## ------------------ "short_0.5k-0.5k" ------------------
auto_evalscopePerf_fixed 1 512 512 0  'short_0.5k-0.5k'


echo "${serverName} testing completed!!!"