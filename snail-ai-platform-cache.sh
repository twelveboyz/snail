#!/bin/bash

evalscope="/usr/local/anaconda3/envs/evalscope/bin/evalscope"

apiKey=$(cat .apiKey)


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

# 0. 关键步骤：先清除旧值，防止Python脚本失败时沿用上次的结果
unset X_Server_Param X_CurTime X_CheckSum AUTHORIZAION x_systemname x_ai_domain x_ai_industry x_ai_scene_name x_source x_category
# 1. 生成头部
OUTPUT=$(python gen_headers.py $url)

# 2. 执行export命令（设置Shell变量）
# 建议：检查OUTPUT是否为空，避免eval空命令
if [ -z "$OUTPUT" ]; then
    echo "Error: gen_headers.py produced no output."
    exit 1
fi
eval "$OUTPUT"



# 3. 验证环境变量（此时如果Python没跑通，变量一定是空的）
if [ -z "$X_Server_Param" ] || [ -z "$X_CurTime" ] || [ -z "$X_CheckSum" ] || [ -z "$AUTHORIZAION" ] || [ -z "$x_systemname" ] || [ -z "$x_ai_domain" ] || [ -z "$x_ai_industry" ] || [ -z "$x_ai_scene_name" ] || [ -z "$x_source" ] || [ -z "$x_category" ]; then
  echo "X_Server_Param: $X_Server_Param"
  echo "X_CurTime: $X_CurTime"
  echo "X_CheckSum: $X_CheckSum"
  echo "AUTHORIZAION: $AUTHORIZAION"
  echo "x_systemname: $x_systemname"
  echo "x_ai_domain: $x_ai_domain"
  echo "x_ai_industry: $x_ai_industry"
  echo "x_ai_scene_name: $x_ai_scene_name"
  echo "x_source: $x_source"
  echo "x_category: $x_category"
  echo "err: args is nil"
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
    # Prometheus 计数值变大后会输出科学计数法（如 5.58336e+07），bc 无法解析会报 syntax error；
    # 这里统一转为整数，为空时保持为空以便上层做缺失判断
    [ -n "$hit" ]   && hit=$(printf '%.0f' "$hit")
    [ -n "$total" ] && total=$(printf '%.0f' "$total")
    echo "$hit $total"
}


# 超长文本前缀缓存测试
prefix_cache_evalscopePerf() {
  local desc=$1
  shift
  local stats_ok=1

  # 读取开始计数
  echo ">>> $desc 压测开始前，读取缓存计数器..."
  read start_hit start_total <<< $(get_cache_counts)
  
  if [ -z "$start_hit" ] || [ -z "$start_total" ]; then
      echo "警告: 未获取到前缀缓存计数器，本档 $desc 跳过命中率统计（压测照常执行）"
      stats_ok=0
  else
      echo ">>> 开始前: hit_tokens=$start_hit, request_tokens=$start_total"
  fi
  

  # 执行压测命令（压测优先，无论统计是否可用都执行）。
  # 被包装命令返回 6 表示本档被跳过(超长未测)，此时不统计。
  # 本函数对调用方统一返回 0：是否产出命中率行由日志体现，不用返回码表达“跳过”。
  "$@" ; [ $? -eq 6 ] &&  return 0

  # 开始计数缺失则本档跳过统计
  [ "$stats_ok" -eq 1 ] || return 0

  # 读取结束计数
  read end_hit end_total <<< $(get_cache_counts)
  if [ -z "$end_hit" ] || [ -z "$end_total" ]; then
      echo "警告: 结束计数获取失败，本档 $desc 跳过命中率统计"
      return 0
  fi
  echo ">>> 结束后: hit_tokens=$end_hit, request_tokens=$end_total"
  
  # 计算差值（使用 bc 处理浮点）
  delta_hit=$(echo "$end_hit - $start_hit" | bc)
  delta_total=$(echo "$end_total - $start_total" | bc)
  
  
  # 比较（bc 不支持直接比较，用 if 结合 bc 条件）
  if [ $(echo "$delta_total == 0" | bc) -eq 1 ]; then
      echo ">>> 警告: 压测期间没有新增前缀请求，无法计算命中率"
      echo "$model No prefix cache enabled!" | tee -a  "$result_file"
  else
      hit_rate=$(echo "scale=4; $delta_hit / $delta_total" | bc)
      hit_percent=$(echo "scale=2; $hit_rate * 100" | bc)
      printf ">>> $desc 本时段缓存命中率: %.2f%% (命中 %d / 请求 %d)\n" "$hit_percent" "$delta_hit" "$delta_total" >> "$result_file"
  fi

  return 0
}
############# perfix cache code #############\


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
    --headers \
      "X-Server-Param=$X_Server_Param" \
      "X-CurTime=$X_CurTime" \
      "X-CheckSum=$X_CheckSum" \
      "AUTHORIZAION=$AUTHORIZAION" \
      "x_systemname=$x_systemname" \
      "x_ai_domain=$x_ai_domain" \
      "x_ai_industry=$x_ai_industry" \
      "x_ai_scene_name=$x_ai_scene_name" \
      "x_source=$x_source" \
      "x_category=$x_category" \
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
  if [ "$totalLength" -ge "$maxModelLen" ]; then
    echo "Warn: max_model_len=${maxModelLen}, total_length=${totalLength},$desc test skipped"
    return 6
  fi

  while true; do
      local startTime=$(timepoints)
      echo ">>> Running evalscope for short, parallel=$parallel, output_dir=$output_dir"
  
      #cmd：带前缀的用例(extra_long)才逐档统计缓存命中率，其余用例直接跑
      if [ "$prefixLength" -gt 0 ]; then
          prefix_cache_evalscopePerf "${desc}_${parallel}" \
              evalscopePerf_fixed "$parallel" "$inputLength" "$outputLength" "$prefixLength" "$desc" "$output_dir"
      else
          evalscopePerf_fixed "$parallel" "$inputLength" "$outputLength" "$prefixLength" "$desc" "$output_dir"
      fi

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
      --headers \
      "X-Server-Param=$X_Server_Param" \
      "X-CurTime=$X_CurTime" \
      "X-CheckSum=$X_CheckSum" \
      "AUTHORIZAION=$AUTHORIZAION" \
      "x_systemname=$x_systemname" \
      "x_ai_domain=$x_ai_domain" \
      "x_ai_industry=$x_ai_industry" \
      "x_ai_scene_name=$x_ai_scene_name" \
      "x_source=$x_source" \
      "x_category=$x_category" \
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
  local  totalLength

  totalLength=$((inputLength + outputLength + prefixLength))
  if [ "$totalLength" -ge "$maxModelLen" ]; then
    echo "Warn: max_model_len=${maxModelLen}, total_length=${totalLength},$desc test skipped"
    return 6
  fi
  
  local startTime=$(timepoints)
  echo ">>> Running evalscope for SLO  ${desc}, output_dir=$output_dir"
  
  #cmd
  evalscopePerf_slo "$inputLength" "$outputLength" "$prefixLength" "$desc" "$sla_params" "$output_dir"

  local endTime=$(timepoints)  
  echo ">>> evalscope finished for SLO ${desc}"

  echo ">>> npu_utilization ${desc} startTime: $startTime, endTime: $endTime"

  npu_monitor  "$projectSpace" "$deployType" "$serverName" "$startTime" "$endTime"  "$ecToken"
  
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
auto_evalscopePerf_fixed 2 13107 1024 116965  extra_long_128K-1k-90
## ------------------ "extra_long_1M-1k-90" ------------------104754 1024 942798-1000
auto_evalscopePerf_fixed 2 104754 1024 941798 extra_long_1M-1k-90
## ------------------ "extra_long_1M-1k-99" ------------------10475 1024 1037077-1000
auto_evalscopePerf_fixed 2 10475 1024 1036077 extra_long_1M-1k-99


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
prefix_cache_evalscopePerf 'extra_long_128K-1k-90' auto_evalscopePerf_slo 13107 1024 116965 extra_long_128K-1k-90 '[{"p99_ttft": "<=25.0", "p99_tpot": "<=0.15"}]'
## ------------------ "extra_long_1M-1k-90" ------------------ 104754 1024 942798-1000  
prefix_cache_evalscopePerf 'extra_long_1M-1k-90'   auto_evalscopePerf_slo 104754 1024 941798 extra_long_1M-1k-90 '[{"p99_ttft": "<=120.0", "p99_tpot": "<=0.2"}]'
## ------------------ "extra_long_1M-1k-99" ------------------10475 1024 1037077-1000
prefix_cache_evalscopePerf 'extra_long_1M-1k-99'   auto_evalscopePerf_slo 10475 1024 1036077 extra_long_1M-1k-99 '[{"p99_ttft": "<=120.0", "p99_tpot": "<=0.2"}]'


echo "${serverName} testing completed!!!"