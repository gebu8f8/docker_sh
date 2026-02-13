#!/bin/bash

# 定義顏色
GREEN="\033[1;32m"
BLUE="\033[1;34m"
YELLOW="\033[1;33m"
CYAN="\033[1;36m"
RED="\033[1;31m"
BOLD_CYAN="\033[1;36;1m"
GRAY="\033[0;90m"
RESET="\033[0m"

#版本
version="2.9.5"

#變量
CURRENT_PAGE=1
TOTAL_PAGES=1

#檢查是否root權限
if [ "$(id -u)" -ne 0 ]; then
  echo "此腳本需要root權限運行" 
  if command -v sudo >/dev/null 2>&1; then
    exec sudo "$0" "$@"
  else
    echo "無sudo指令"
  fi
fi

check_dba(){
  if ! command -v dba >/dev/null 2>&1; then
    bash <(curl -sL https://gitlab.com/gebu8f/sh/-/raw/main/db/dba.sh) install_script
  fi
}

configure_redis_with_firewall_interface() {
  local iface="$(ip route | grep default | grep -o 'dev [^ ]*' | cut -d' ' -f2)"
  local conf="/etc/redis/redis.conf"

  echo "[INFO] 檢查 Redis 是否已監聽所有介面..."

  if ss -lntp | grep -qE 'LISTEN.*(0\.0\.0\.0|\[::\]):6379'; then
    echo "[SKIP] Redis 已監聽所有介面，無需修改 bind。"
    return 0
  else
    echo "[INFO] Redis 未監聽所有介面，開始修改 redis.conf..."

    cp "$conf" "$conf.bak.$(date +%s)"
    sed -i 's/^bind .*/bind * -::*/' "$conf"

    service redis restart
    sleep 1

    if ss -lntp | grep -qE 'LISTEN.*(0\.0\.0\.0|\[::\]):6379'; then
      echo "[OK] Redis 已成功監聽所有介面。"
    else
      echo "[ERR] Redis 重啟後仍未正確監聽，請手動檢查。"
      return 1
    fi
  fi

  echo "[INFO] 使用 redis-cli 關閉 protected-mode..."

  redis-cli CONFIG SET protected-mode no
  redis-cli CONFIG REWRITE

  echo "[INFO] 設定防火牆：封鎖 interface $iface 的 Redis 外部連線..."

  iptables -C INPUT -i "$iface" -p tcp --dport 6379 -j DROP 2>/dev/null || \
  iptables -A INPUT -i "$iface" -p tcp --dport 6379 -j DROP

  ip6tables -C INPUT -i "$iface" -p tcp --dport 6379 -j DROP 2>/dev/null || \
  ip6tables -A INPUT -i "$iface" -p tcp --dport 6379 -j DROP

  if systemctl is-active firewalld &>/dev/null; then
    echo "[INFO] 偵測到 firewalld，加入封鎖 rich rule..."
    firewall-cmd --permanent --add-rich-rule="rule interface name=\"$iface\" port port=\"6379\" protocol=\"tcp\" reject"
    firewall-cmd --reload
  fi

  if command -v ufw &>/dev/null && ufw status | grep -q 'Status: active'; then
    echo "[INFO] 偵測到 UFW，插入 deny in on $iface..."
    ufw deny in on "$iface" to any port 6379 proto tcp
  fi

  echo "[DONE] Redis 防火牆限制完成。"
  sheep 3
}

#檢查系統版本
check_system(){
  if command -v apt >/dev/null 2>&1; then
    system=1
  elif command -v yum >/dev/null 2>&1; then
    system=2
  elif command -v apk >/dev/null 2>&1; then
    system=3
   else
    echo -e "${RED}不支援的系統。${RESET}" >&2
    exit 1
  fi
}
#檢查需要安裝之軟體
check_app(){
  if ! command -v ss &>/dev/null; then
    case $system in
      1)
        apt update && apt install -y iproute2
        ;;
      2)
        yum install -y iproute2
        ;;
      3)
        apk update && apk add iproute2
        ;;
    esac
  fi
}
check_site(){
  if ! command -v site &>/dev/null; then
    echo -e "${RED}您好，您尚未安裝gebu8f站點管理器，請手動安裝${RESET}"
    read -p "操作完成，按任意鍵繼續..." -n1
    return 1
  fi
}
check_site_proxy_domain(){
  local port=$1
  if command -v site &>/dev/null; then
    site api search proxy_domain "127.0.0.1:$port" | awk '{print "https://"$0}'
  fi
}

delete_docker_containers() {
  local all_containers=$(docker ps -a --format "{{.ID}}|{{.Names}}|{{.Status}}|{{.Image}}")

  if [ -z "$all_containers" ]; then
    echo "系統沒有任何容器！"
    return
  fi

  local containers_list=()
  local index=1

  echo "以下是目前所有容器："
  while IFS='|' read -r id name status image; do
    containers_list+=("$id|$name|$status|$image")
    echo "$index ） $name"
    index=$((index+1))
  done <<< "$all_containers"
  local selected_ids=()

  read -p "請輸入要刪除的容器編號（可空白隔開多個）: " input_indexes

  for i in $input_indexes; do
    if ! [[ "$i" =~ ^[0-9]+$ ]]; then
      echo -e "${RED} 無效編號：$i${RESET}" >&2
      continue
    fi
    if [ "$i" -ge 1 ] && [ "$i" -lt "$index" ]; then
      IFS='|' read -r id name status image <<< "${containers_list[$((i-1))]}"
        selected_ids+=("$id|$name|$status|$image")
    else
      echo -e "${RED}編號 $i 不存在！${RESET}"  >&2
    fi
  done

  if [ ${#selected_ids[@]} -eq 0 ]; then
    echo -e "${RED} 沒有選擇任何有效容器，操作中止。${RESET}" >&2
    sleep 1
    return 0
  fi

  for info in "${selected_ids[@]}"; do
    IFS='|' read -r id name status image <<< "$info"

    echo "正在處理容器：$name ($id)"

    # 若容器正在運行，先停止
    local state=$(docker inspect -f '{{.State.Status}}' "$id")
    case "$state" in
      running)
        docker stop "$id" && docker rm "$id" || {
        docker update --restart=no "$id" >/dev/null 2>&1
        docker kill "$id"
        docker rm -f "$id"
      }
      ;;
    restarting)
      docker update --restart=no "$id" >/dev/null 2>&1
      docker kill "$id"
      docker rm -f "$id"
      ;;
    paused)
      docker unpause "$id"
      docker stop "$id"
      docker rm "$id"
      ;;
    exited|created|dead)
      docker rm "$id" || {
        docker rm "$id" -f
      }
      ;;
    esac
    read -p "是否同時刪除鏡像 $image？ (y/n) [預設：y]" delete_image
    delete_image=${delete_image,,}
    delete_image=${delete_image:-y}
    if [[ "$delete_image" == y ]]; then
      if docker rmi "$image" ; then
        echo -e "${GREEN}鏡像 $image 已刪除${RESET}"
      else
        echo -e "${YELLOW}鏡像 $image 刪除失敗或已被其他容器使用${RESET}" >&2
        sleep 1
      fi
    else
      echo -e "${RED}容器 $name 跳過刪除鏡像${RESET}" >&2
    fi
  done
}

docker_network_manager() {
  # --- 1. 通用排版輔助函式 ---
  display_width() {
    local str="$1"; local width=0; local i=0
    while [ $i -lt ${#str} ]; do
      local char="${str:$i:1}"
      if [[ $(printf "%d" "'$char") -gt 127 ]] 2>/dev/null; then
        width=$((width + 2))
      else 
        width=$((width + 1))
      fi
      i=$((i + 1))
    done
    echo $width
  }
  
  pad_left() {
    local text="$1"
    local max_width="$2"
    local current_width=$(display_width "$text")
    local padding=$((max_width - current_width))
    [[ $padding -lt 0 ]] && padding=0
    printf "%s%*s" "$text" $padding ""
  }

  echo
  echo -e "${CYAN}當前容器網路資訊：${RESET}"
  # 取得運行中的容器 ID
  local container_ids=$(docker ps -q)
  
  if [ -z "$container_ids" ]; then
    echo -e "${YELLOW}沒有正在運行的容器。${RESET}"
    return 0
  fi

  # --- 2. 資料收集與全域狀態檢查 ---
  # 格式定義: 容器名|網路名,IPv4,IPv4網關,IPv6,IPv6網關#網路名2...
  local inspect_format='{{.Name}}|{{range $k, $v := .NetworkSettings.Networks}}{{$k}},{{$v.IPAddress}},{{$v.Gateway}},{{$v.GlobalIPv6Address}},{{$v.IPv6Gateway}}#{{end}}'
  
  local raw_data
  raw_data=$(docker inspect --format "$inspect_format" $container_ids 2>/dev/null)

  local -a data_rows=()
  
  # 旗標：用來判斷是否需要顯示該欄位
  local has_any_ipv6=false
  local has_any_ipv6_gw=false

  # 解析數據
  while IFS='|' read -r name net_info; do
    name="${name:1}" # 去除開頭的 /
    
    # 處理無網路情況
    if [ -z "$net_info" ]; then
      # 為了保持格式一致，我們塞入空的佔位符
      data_rows+=("$name|host/none||||")
      continue
    fi

    # 分割多個網路 (以 # 分隔)
    local networks=$(echo "$net_info" | tr '#' '\n')
    
    while IFS=',' read -r net_name ip4 gw4 ip6 gw6; do
      [ -z "$net_name" ] && continue
      
      # 資料淨化：如果是 <no value> 或空，就設為空字串
      [[ "$ip4" == "invalid IP" ]] && ip4=""
      [[ "$gw4" == "invalid IP" ]] && gw4=""
      [[ "$ip6" == "invalid IP" ]] && ip6=""
      [[ "$gw6" == "invalid IP" ]] && gw6=""

      # 檢查是否偵測到 IPv6 資料 (只要有一個容器有，就開啟該欄位)
      [[ -n "$ip6" ]] && has_any_ipv6=true
      [[ -n "$gw6" ]] && has_any_ipv6_gw=true

      data_rows+=("$name|$net_name|$ip4|$gw4|$ip6|$gw6")
    done <<< "$networks"
  done <<< "$raw_data"

  # --- 3. 動態欄位配置 ---
  # 定義所有可能的標題與對應的資料索引 (0-5)
  local full_headers=("容器名" "網路" "IPv4 地址" "IPv4 網關" "IPv6 地址" "IPv6 網關")
  local -a active_indices=(0 1 2 3) # 預設顯示前四欄

  # 根據全域旗標決定是否加入 IPv6 欄位索引
  if $has_any_ipv6; then active_indices+=(4); fi
  if $has_any_ipv6_gw; then active_indices+=(5); fi

  # --- 4. 計算最大寬度 ---
  local -a max_widths=()
  
  # 初始化標題寬度 (只針對啟用的欄位)
  for idx in "${active_indices[@]}"; do
    max_widths[$idx]=$(display_width "${full_headers[$idx]}")
  done

  # 掃描資料更新最大寬度
  for row in "${data_rows[@]}"; do
    IFS='|' read -r c0 c1 c2 c3 c4 c5 <<< "$row"
    local cols=("$c0" "$c1" "$c2" "$c3" "$c4" "$c5")
    
    for idx in "${active_indices[@]}"; do
      local w=$(display_width "${cols[$idx]}")
      if [[ $w -gt ${max_widths[$idx]} ]]; then
        max_widths[$idx]=$w
      fi
    done
  done

  # --- 5. 渲染表格 ---
  
  # (A) 印出標題
  local header_line=""
  for i in "${!active_indices[@]}"; do
    local idx=${active_indices[$i]}
    header_line+=$(pad_left "${full_headers[$idx]}" "${max_widths[$idx]}")
    # 只要不是最後一個啟用的欄位，就加分隔線
    [[ $i -lt $((${#active_indices[@]} - 1)) ]] && header_line+=" | "
  done
  echo "$header_line"

  # (B) 印出分隔線
  local total_width=0
  for idx in "${active_indices[@]}"; do 
    total_width=$((total_width + max_widths[idx] + 3))
  done
  total_width=$((total_width - 3))
  printf '%.0s-' $(seq 1 $total_width) && printf "\n"

  # (C) 印出資料
  local last_name=""
  for row in "${data_rows[@]}"; do
    IFS='|' read -r c0 c1 c2 c3 c4 c5 <<< "$row"
    local cols=("$c0" "$c1" "$c2" "$c3" "$c4" "$c5")

    # 處理重複名稱隱藏
    local display_name="${cols[0]}"
    if [[ "${cols[0]}" == "$last_name" ]]; then
      cols[0]="" # 將顯示用的名稱清空
    else
      last_name="${cols[0]}"
    fi

    local line=""
    for i in "${!active_indices[@]}"; do
      local idx=${active_indices[$i]}
      line+=$(pad_left "${cols[$idx]}" "${max_widths[$idx]}")
      [[ $i -lt $((${#active_indices[@]} - 1)) ]] && line+=" | "
    done

    echo "$line"
  done

  # 額外列出所有現有網路
  echo
  local all_networks=$(docker network ls --format '{{.Name}}' | tr '\n' ' ')
  echo -e "${YELLOW}已存在的網路：${RESET} $all_networks"
  echo

  echo "網路管理功能："
  echo "1. 新增網路"
  echo "2. 刪除網路"
  echo "3. 將此網路的所有容器解除並分配到指定網路"
  echo "4. 加入網路"
  echo "5. 離開網路"
  echo "0. 返回"
  echo

  read -p "請選擇功能 [0-4]：" choice

  case "$choice" in
  1)
    echo "新增 Docker 網路"
    read -p "請輸入網路名稱：" netname
    read -p "請輸入 Subnet (例如 172.50.0.0/24，留空自動分配)：" subnet
    read -p "請輸入 Gateway (例如 172.50.0.1，留空自動分配)：" gateway
    cmd_array=("docker" "network" "create")
    if [ -n "$subnet" ]; then
      cmd_array+=("--subnet" "$subnet")
    fi
    if [ -n "$gateway" ]; then
      cmd_array+=("--gateway" "$gateway")
    fi
    cmd_array+=("$netname")

    echo "執行："
    printf "%q " "${cmd_array[@]}"
    echo 
    if "${cmd_array[@]}"; then
      echo -e "${GREEN}已成功建立網路 $netname${RESET}"
    else
      echo -e "${RED}建立網路 $netname 失敗！請檢查上述錯誤訊息。${RESET}"
    fi
    ;;
  2)
    echo "刪除 Docker 網路"

    # 列出所有網路
    mapfile -t network_list < <(docker network ls --format '{{.Name}}')
            
    if [ ${#network_list[@]} -eq 0 ]; then
      echo -e "${YELLOW}尚未建立任何網路。${RESET}"
      return 0
    fi
    for i in "${!network_list[@]}"; do
      printf "%3s） %s\n" $((i+1)) "${network_list[$i]}"
    done
    read -p "請輸入欲刪除的網路編號：" nindex
    netname="${network_list[$((nindex-1))]}"
    if [ -z "$netname" ]; then
      echo -e "${RED}無效的網路編號。${RESET}"
      return 1
    fi
    docker network rm "$netname"
    if [ $? -eq 0 ]; then
      echo "已刪除網路 $netname"
    else
      echo -e "${RED}刪除網路失敗，請檢查是否仍有容器連接該網路。${RESET}"
    fi
    ;;
  3)
    echo "遷移網路內所有容器"

    # 列出所有網路
    mapfile -t network_list < <(docker network ls --format '{{.Name}}')
    if [ ${#network_list[@]} -eq 0 ]; then
      echo -e "${YELLOW}尚未建立任何網路。${RESET}"
      return 0
    fi
    for i in "${!network_list[@]}"; do
      printf "%3s） %s\n" $((i+1)) "${network_list[$i]}"
    done

    read -p "請輸入欲遷移的網路編號：" oindex
    oldnet="${network_list[$((oindex-1))]}"

    if [ -z "$oldnet" ]; then
      echo -e "${RED}無效的網路編號。${RESET}"
      return 1
    fi
    read -p "請輸入新網路編號：" nindex
    newnet="${network_list[$((nindex-1))]}"
    if [ -z "$newnet" ]; then
      echo -e "${RED}無效的新網路編號。${RESET}"
      return 1
    fi
    if [[ "$oldnet" == "$newnet" ]]; then
      echo -e "${YELLOW}新舊網路相同，無需遷移。${RESET}"
      return 1
    fi
    # 列出舊網路內的所有容器
    containers=$(docker network inspect "$oldnet" -f '{{range .Containers}}{{.Name}} {{end}}')

    if [ -z "$containers" ]; then
      echo -e "網路 $oldnet 內沒有任何容器。"
      return 0
    fi
    for c in $containers; do
      echo "正在將容器 $c 從 $oldnet 移至 $newnet"
      docker network disconnect "$oldnet" "$c"
      docker network connect "$newnet" "$c"
    done
    echo -e "${GREEN}所有容器已遷移至 $newnet${RESET}"
    ;;
  4)
    echo "加入容器至網路"
            
    # 顯示容器列表
    mapfile -t container_list < <(docker ps --format '{{.Names}}')
    for i in "${!container_list[@]}"; do
      printf "%3s） %s\n" $((i+1)) "${container_list[$i]}"
    done
    read -p "請輸入容器編號：" cindex
    cname="${container_list[$((cindex-1))]}"
    if [ -z "$cname" ]; then
      echo -e "${RED}無效的容器編號。${RESET}"
      return 1
    fi
    # 顯示網路列表
    mapfile -t network_list < <(docker network ls --format '{{.Name}}')
    for i in "${!network_list[@]}"; do
      printf "%3s） %s\n" $((i+1)) "${network_list[$i]}"
    done
    read -p "請輸入要加入的網路編號：" nindex
    netname="${network_list[$((nindex-1))]}"
    if [ -z "$netname" ]; then
      echo -e "${RED}無效的網路編號。${RESET}"
      return 1
    fi
    # 檢查容器是否已在該網路
    is_connected=$(docker inspect -f "{{json .NetworkSettings.Networks}}" "$cname" | grep "\"$netname\"" || true)
    if [ -n "$is_connected" ]; then
      echo -e "${YELLOW}容器 $cname 已經在網路 $netname 中，無需加入。${RESET}"
    else
      docker network connect "$netname" "$cname"
      if [ $? -eq 0 ]; then
        echo -e "${GREEN}容器 $cname 已成功加入網路 $netname${RESET}"
      else
        echo -e "${RED}加入網路失敗，請檢查容器狀態或網路模式。${RESET}"
      fi
    fi
    ;;
  5)
    echo " 從網路中移除容器"
            
    # 顯示容器列表
    mapfile -t container_list < <(docker ps --format '{{.Names}}')
    for i in "${!container_list[@]}"; do
      printf "%3s） %s\n" $((i+1)) "${container_list[$i]}"
    done

    read -p "請輸入容器編號：" cindex
    cname="${container_list[$((cindex-1))]}"

    if [ -z "$cname" ]; then
      echo -e "${RED}無效的容器編號。${RESET}"
      return 1
    fi
    # 顯示此容器的網路
    echo "正在查詢容器 $cname 的網路..."
    mapfile -t attached_networks < <(docker inspect -f '{{range $k, $_ := .NetworkSettings.Networks}}{{println $k}}{{end}}' "$cname")

    if [ "${#attached_networks[@]}" -eq 0 ]; then
      echo -e "${YELLOW}該容器未連接任何自訂網路。${RESET}"
      return 1
    fi

    for i in "${!attached_networks[@]}"; do
      printf "%3s） %s\n" $((i+1)) "${attached_networks[$i]}"
    done
    read -p "請輸入要離開的網路編號：" nindex
    netname="${attached_networks[$((nindex-1))]}"

    if [ -z "$netname" ]; then
      echo -e "${RED} 無效的網路編號。${RESET}"
      return 1
    fi

    docker network disconnect "$netname" "$cname"
    if [ $? -eq 0 ]; then
      echo -e "${GREEN} 容器 $cname 已成功離開網路 $netname${RESET}"
    else
      echo -e "${RED} 離開網路失敗，請確認容器是否正在使用該網路。${RESET}"
    fi
    ;;
  0)
    echo "已返回"
    ;;
  *)
    echo -e "${RED}無效的選擇${RESET}"
    ;;
  esac
}

docker_show_logs() {
  echo
  echo -e "${CYAN}Docker 容器日誌讀取${RESET}"
  echo

  # 取得所有容器
  mapfile -t container_list < <(docker ps -a --format '{{.Names}}')

  if [ ${#container_list[@]} -eq 0 ]; then
    echo -e "${YELLOW}  沒有任何容器存在。${RESET}"
    return
  fi
  echo "請選擇要查看日誌的容器："
  for i in "${!container_list[@]}"; do
    printf "%3s） %s\n" $((i+1)) "${container_list[$i]}"
  done
  echo
  read -p "輸入容器編號：" cindex
  cname="${container_list[$((cindex-1))]}"

  if [ -z "$cname" ]; then
    echo -e "${RED} 無效的容器編號。${RESET}"
    return 1
  fi

  echo
  read -p "是否持續監聽最新日誌？(y/n)：" follow
  follow=${follow,,}

  if [[ "$follow" == "y" || "$follow" == "yes" ]]; then
    echo -e "${YELLOW} 持續監聽 $cname 日誌中（按 Ctrl+C 結束）...${RESET}"
    docker logs -f "$cname"
  else
    read -p "請輸入要顯示最後幾行日誌（預設 100）：" line_count
    line_count=${line_count:-100}
    echo -e "${YELLOW}顯示容器 $cname 的最後 $line_count 行日誌：${RESET}"
    echo "-----------------------------------------------"
    docker logs --tail "$line_count" "$cname"
  fi
}

docker_resource_manager() {
  # --- 通用排版輔助函式 ---
  display_width() {
    local str="$1"
    local width=0; local i=0
    while [ $i -lt ${#str} ]; do
      local char="${str:$i:1}"
      if [[ $(printf "%d" "'$char") -gt 127 ]] 2>/dev/null; then 
        ((width+=2))
      else
        ((width+=1))
      fi
      ((i++))
    done
    echo $width
  }
  pad_left() {
    local text="$1"
    local max_width="$2"
    local current_width=$(display_width "$text")
    local padding=$((max_width - current_width))
    printf "%s%*s" "$text" $padding ""
  }
  pad_right() { 
    local text="$1"
    local max_width="$2"
    local current_width=$(display_width "$text")
    local padding=$((max_width - current_width))
    printf "%*s%s" $padding "" "$text"
    
  }

  while true; do
    # --- 效能優化: 一次性批次獲取所有資訊 ---
    local all_containers_raw=$(docker ps -a --format "{{.Names}}|{{.ID}}")
    if [ -z "$all_containers_raw" ]; then
      echo -e "${GREEN} 沒有任何容器！${RESET}"
      return
    fi
    local all_ids=$(echo "$all_containers_raw" | cut -d'|' -f2 | tr '\n' ' ')

        # 【快取1】預處理 Inspect 資訊 (CPU/Mem 限制)
    declare -A cpu_limit_map; declare -A mem_limit_map
    # 【關鍵修正】: 一次性獲取所有 CPU 相關的欄位
    local inspect_data=$(docker inspect --format '{{.Name}}|{{.HostConfig.NanoCpus}}|{{.HostConfig.CpuPeriod}}|{{.HostConfig.CpuQuota}}|{{.HostConfig.Memory}}' $all_ids 2>/dev/null)
    
    while IFS='|' read -r name nano_cpus cpu_period cpu_quota mem; do
      local clean_name=$(echo "$name" | sed 's/^\///')
      
      # --- 更聰明的 CPU 限制判斷邏輯 ---
      local cpu_limit="無限制"
      if [[ -n "$nano_cpus" && "$nano_cpus" != "0" && "$nano_cpus" != "<no value>" ]]; then
        # 優先使用新的 NanoCpus
        cpu_limit=$(awk -v nano="$nano_cpus" 'BEGIN {printf "%.2f Cores", nano/1000000000}')
      elif [[ -n "$cpu_period" && "$cpu_period" != "0" && "$cpu_period" != "<no value>" && -n "$cpu_quota" && "$cpu_quota" -gt 0 ]]; then
        # 其次，檢查舊的 Period/Quota
        cpu_limit=$(awk -v period="$cpu_period" -v quota="$cpu_quota" 'BEGIN {printf "%.2f Cores", quota/period}')
      fi
      cpu_limit_map["$clean_name"]="$cpu_limit"

      # --- 記憶體限制邏輯保持不變 ---
      local mem_limit="無限制"
      if ! [[ -z "$mem" || "$mem" == "0" || "$mem" == "<no value>" ]]; then
        mem_limit=$(awk -v mem="$mem" 'BEGIN { if (mem >= 1073741824) printf "%.2fG", mem/1073741824; else printf "%.2fM", mem/1048576; }')
      fi
      mem_limit_map["$clean_name"]="$mem_limit"
    done <<< "$inspect_data"

    # 【快取2】預處理 Stats 資訊 (CPU/Mem 使用量)
    declare -A cpu_used_map; declare -A mem_used_map
    while IFS='|' read -r name cpu_perc mem_usage; do
      cpu_used_map["$name"]="$cpu_perc"
      # 使用純 Bash 處理字串，避免 awk
      local mem_val=${mem_usage%%/*}
      mem_used_map["$name"]="${mem_val// /}" # 移除可能存在的空格
    done <<< $(docker stats --no-stream --format "{{.Name}}|{{.CPUPerc}}|{{.MemUsage}}")

    # --- 階段一：在 100% 純淨的迴圈中收集數據 ---
    local headers=("編號" "容器名" "CPU (使用/限制)" "記憶體 (使用/限制)")
    local -a max_widths=(); for header in "${headers[@]}"; do max_widths+=($(display_width "$header")); done

    local container_info=(); local data_rows=(); local index=1
    while IFS='|' read -r name id; do
      container_info+=("$id|$name")

      # 從快取中極速讀取數據
      local cpu_limit=${cpu_limit_map["$name"]:-"無限制"}
      local mem_limit=${mem_limit_map["$name"]:-"無限制"}
      local cpu_used=${cpu_used_map["$name"]:-"N/A"}
      local mem_used=${mem_used_map["$name"]:-"N/A"}

      local cpu_str="$cpu_used / $cpu_limit"
      local mem_str="$mem_used / $mem_limit"

      data_rows+=("$index|$name|$cpu_str|$mem_str")

      local -a current_widths=($(display_width "$index") $(display_width "$name") $(display_width "$cpu_str") $(display_width "$mem_str"))
      for i in "${!max_widths[@]}"; do
        if [[ ${current_widths[$i]} -gt ${max_widths[$i]} ]]; then
          max_widths[$i]=${current_widths[$i]}
        fi
      done
      ((index++))
    done <<< "$all_containers_raw"

    # --- 階段二：格式化輸出 ---
    echo
    pad_left  "${headers[0]}" "${max_widths[0]}" && printf "  "
    pad_left  "${headers[1]}" "${max_widths[1]}" && printf "  "
    pad_right "${headers[2]}" "${max_widths[2]}" && printf "  "
    pad_right "${headers[3]}" "${max_widths[3]}" && printf "\n"

    total_width=0; for width in "${max_widths[@]}"; do total_width=$((total_width + width)); done
    total_width=$((total_width + (${#max_widths[@]} - 1) * 2)); printf '%.0s-' $(seq 1 $total_width); printf "\n"

    for row in "${data_rows[@]}"; do
      IFS='|' read -r r_index r_name r_cpu r_mem <<< "$row"
      pad_left  "$r_index" "${max_widths[0]}" && printf "  "
      pad_left  "$r_name"  "${max_widths[1]}" && printf "  "
      pad_right "$r_cpu"   "${max_widths[2]}" && printf "  "
      pad_right "$r_mem"   "${max_widths[3]}" && printf "\n"
    done

    # --- 後續操作 (邏輯不變) ---
    echo
    echo -e "${CYAN}1. 熱修改 CPU 限制${RESET}"
    echo -e "${CYAN}2. 熱修改 記憶體 限制${RESET}"
    echo -e "${CYAN}0. 返回${RESET}"
    echo
    read -p "請輸入選項: " choice
    case "$choice" in
    1)
      read -p "請輸入欲修改 CPU 限制的容器編號: " num
      if ! [[ "$num" =~ ^[0-9]+$ ]] || [ "$num" -lt 1 ] || [ "$num" -ge "$index" ]; then
        echo -e "${RED}無效編號${RESET}"; continue; fi
      IFS='|' read -r id name <<< "${container_info[$((num-1))]}"
      echo -e "${YELLOW}警告！如果已經設定配額的無法取消 這是docker硬性規定，若要取消請受凍重現容器，謝謝！${RESET}"
      read -p "請輸入新的 CPU 配額（例如 0.5）: " cpu_limit
      docker update --cpus="$cpu_limit" "$id" > /dev/null
      if [[ $? -eq 0 ]]; then echo -e "${GREEN}容器 '$name' CPU 限制已更新${RESET}"; else echo -e "${RED}更新失敗${RESET}"; fi
      ;;
    2)
      to_bytes() {
        local input=$(echo "$1" | tr '[:upper:]' '[:lower:]')
        local num="${input//[^0-9.]/}"
        local unit="${input//[0-9.]/}"
        if [ -z "$num" ]; then echo "0"; return; fi
        case "$unit" in
          g|gb) awk -v n="$num" 'BEGIN {printf "%.0f", n * 1024 * 1024 * 1024}' ;;
          m|mb) awk -v n="$num" 'BEGIN {printf "%.0f", n * 1024 * 1024}' ;;
          k|kb) awk -v n="$num" 'BEGIN {printf "%.0f", n * 1024}' ;;
          *)    echo "$num" ;; 
        esac
      }
      read -p "請輸入欲修改 記憶體 限制的容器編號: " num
      if ! [[ "$num" =~ ^[0-9]+$ ]] || [ "$num" -lt 1 ] || [ "$num" -ge "$index" ]; then
        echo -e "${RED}無效編號${RESET}"; continue; fi
      IFS='|' read -r id name <<< "${container_info[$((num-1))]}"
      echo -e "${YELLOW}警告！如果已經設定配額的無法取消 這是docker硬性規定，若要取消請受凍重現容器，謝謝！${RESET}"
      read -p "請輸入新的記憶體限制（如 512m, 1g）: " ram_input
      ram_bytes=$(to_bytes "$ram_input")
      buffer_bytes=$((10 * 1024 * 1024)) 
      total_bytes=$(awk -v r="$ram_bytes" -v b="$buffer_bytes" 'BEGIN {printf "%.0f", r + b}')
      if [ "$ram_input" == "0" ]; then
        docker update --memory=0 --memory-swap=-1 "$id" > /dev/null
      else
        docker update --memory="$ram_bytes" --memory-swap="$total_bytes" "$id" > /dev/null
      fi
      if [[ $? -eq 0 ]]; then
        echo -e "${GREEN}容器 '$name' 記憶體 限制已更新${RESET}"
      else
        echo -e "${RED}更新失敗${RESET}"
      fi
      ;;
    0) echo -e "${CYAN}返回上一層${RESET}"; break;;
    *) echo -e "${RED}無效選項${RESET}";;
    esac
    echo
  done
}

docker_volume_manager() {
  # --- 通用排版輔助函式 (已展開，提高可讀性) ---
  display_width() {
    local str="$1"
    local width=0
    local i=0
    while [ $i -lt ${#str} ]; do
      local char="${str:$i:1}"
      if [[ $(printf "%d" "'$char") -gt 127 ]] 2>/dev/null; then
        ((width+=2))
      else
        ((width+=1))
      fi
      ((i++))
    done
    echo $width
  }

  pad_left() {
    local text="$1"
    local max_width="$2"
    local current_width=$(display_width "$text")
    local padding=$((max_width - current_width))
    printf "%s%*s" "$text" "$padding" ""
  }

  # --- 效能優化：一次性批次獲取所有資訊 ---
  local all_containers_raw
  all_containers_raw=$(docker ps -a --format "{{.Names}}|{{.ID}}")

  local all_volumes_json
  all_volumes_json=$(docker volume inspect $(docker volume ls -q) 2>/dev/null)

  # 【快取1】預處理所有 Volumes 的資訊 (名稱 -> 路徑)
  declare -A volume_path_map
  if [[ -n "$all_volumes_json" ]]; then
    # 使用 jq 將 JSON 陣列轉換為多行，每行一個 JSON 物件
    while IFS= read -r vol_data; do
      local name=$(echo "$vol_data" | jq -r .Name)
      local mountpoint=$(echo "$vol_data" | jq -r .Mountpoint)
      volume_path_map["$name"]="$mountpoint"
    done <<< $(echo "$all_volumes_json" | jq -c '.[]')
  fi
  
  # 【快取2】處理容器的掛載資訊
  local bind_mount_rows=()
  local volume_mount_rows=()
  declare -A used_volumes
  
  if [[ -n "$all_containers_raw" ]]; then
    while IFS='|' read -r name id; do
      local clean_name=$(echo "$name" | sed 's/^\///')
      local mounts_json=$(docker inspect --format '{{json .Mounts}}' "$id")

      while IFS= read -r mount; do
        local type=$(echo "$mount" | jq -r .Type)
        if [[ "$type" == "bind" ]]; then
          local source=$(echo "$mount" | jq -r .Source)
          local destination=$(echo "$mount" | jq -r .Destination)
          bind_mount_rows+=("$clean_name|$source|$destination")
        elif [[ "$type" == "volume" ]]; then
          local volume_name=$(echo "$mount" | jq -r .Name)
          local path=${volume_path_map["$volume_name"]}
          volume_mount_rows+=("$clean_name|$path") # 只儲存路徑，不再儲存名稱
          used_volumes["$volume_name"]=1
        fi
      done <<< $(echo "$mounts_json" | jq -c '.[]')
    done <<< "$all_containers_raw"
  fi

  # --- 面板一：綁定掛載 (Bind Mounts) ---
  echo
  echo -e "${CYAN}綁定掛載 (Host Folders)：${RESET}"
  if [ ${#bind_mount_rows[@]} -eq 0 ]; then
    echo -e "${YELLOW}  沒有任何容器使用綁定掛載。${RESET}"
  else
    local headers=("容器" "主機路徑" "容器內路徑")
    local -a max_widths=(0 0 0)
    for h_idx in "${!headers[@]}"; do
      max_widths[$h_idx]=$(display_width "${headers[$h_idx]}")
    done

    for row in "${bind_mount_rows[@]}"; do
      IFS='|' read -r cname src dest <<< "$row"
      local -a widths=($(display_width "$cname") $(display_width "$src") $(display_width "$dest"))
      for i in 0 1 2; do
        if [[ ${widths[$i]} -gt ${max_widths[$i]} ]]; then
          max_widths[$i]=${widths[$i]}
        fi
      done
    done
    
    pad_left "${headers[0]}" "${max_widths[0]}"; printf "  "
    pad_left "${headers[1]}" "${max_widths[1]}"; printf "  "
    pad_left "${headers[2]}" "${max_widths[2]}"; printf "\n"
    
    total_width=0
    for w in "${max_widths[@]}"; do total_width=$((total_width + w)); done
    total_width=$((total_width + 4)); printf '%.0s-' $(seq 1 $total_width); printf "\n"
    
    for row in "${bind_mount_rows[@]}"; do
      IFS='|' read -r cname src dest <<< "$row"
      pad_left "$cname" "${max_widths[0]}"; printf "  "
      pad_left "$src"   "${max_widths[1]}"; printf "  "
      pad_left "$dest"  "${max_widths[2]}"; printf "\n"
    done
  fi

  echo
  total_width=$((total_width + 4)); printf '%.0s-' $(seq 1 $total_width); printf "\n"

  # --- 面板二：儲存卷 (Volumes) ---
  echo
  echo -e "${CYAN}儲存卷 (Managed by Docker)：${RESET}"
  if [ ${#volume_path_map[@]} -eq 0 ]; then
    echo -e "${YELLOW}  沒有任何儲存卷存在。${RESET}"
  else
    local headers=("容器" "宿主機路徑")
    local -a max_widths=(0 0)
    for h_idx in "${!headers[@]}"; do
      max_widths[$h_idx]=$(display_width "${headers[$h_idx]}")
    done

    for row in "${volume_mount_rows[@]}"; do
      IFS='|' read -r cname path <<< "$row"
      local -a widths=($(display_width "$cname") $(display_width "$path"))
      if [[ ${widths[0]} -gt ${max_widths[0]} ]]; then max_widths[0]=${widths[0]}; fi
      if [[ ${widths[1]} -gt ${max_widths[1]} ]]; then max_widths[1]=${widths[1]}; fi
    done

    local orphan_width=$(display_width "（未掛載）")
    if [[ $orphan_width -gt ${max_widths[0]} ]]; then max_widths[0]=$orphan_width; fi
    for vol_name in "${!volume_path_map[@]}"; do
      if [[ -z "${used_volumes[$vol_name]}" ]]; then
        local path=${volume_path_map["$vol_name"]}
        local path_width=$(display_width "$path")
        if [[ $path_width -gt ${max_widths[1]} ]]; then max_widths[1]=$path_width; fi
      fi
    done
    
    pad_left "${headers[0]}" "${max_widths[0]}"; printf "  "
    pad_left "${headers[1]}" "${max_widths[1]}"; printf "\n"

    total_width=0
    for w in "${max_widths[@]}"; do total_width=$((total_width + w)); done
    total_width=$((total_width + 2)); printf '%.0s-' $(seq 1 $total_width); printf "\n"
    
    for row in "${volume_mount_rows[@]}"; do
      IFS='|' read -r cname path <<< "$row"
      pad_left "$cname" "${max_widths[0]}"; printf "  "
      pad_left "$path"  "${max_widths[1]}"; printf "\n"
    done
    for vol_name in "${!volume_path_map[@]}"; do
      if [[ -z "${used_volumes[$vol_name]}" ]]; then
        local path=${volume_path_map["$vol_name"]}
        pad_left "（未掛載）" "${max_widths[0]}"; printf "  "
        pad_left "$path"      "${max_widths[1]}"; printf "\n"
      fi
    done
  fi

  # --- 後續管理功能 ---
  echo
  echo "存儲卷管理功能："
  echo "1. 添加卷"
  echo "2. 刪除卷"
  echo "0. 返回"
  echo
  read -p "請選擇功能 [0-2]：" choice
  case "$choice" in
  1)
    echo " 添加新儲存卷"
    read -p "請輸入儲存卷名稱：" volname
    if [ -n "$volname" ]; then
        docker volume create "$volname"
        echo -e "${GREEN} 存儲卷 $volname 已建立。${RESET}"
    else
        echo -e "${RED}名稱不能為空。${RESET}"
    fi
    ;;
    2)
    echo " 刪除儲存卷"
    
    # 步驟1：將所有 volume 名稱讀入一個陣列
    local volumes_array=()
    mapfile -t volumes_array < <(docker volume ls -q)

    # 檢查是否有任何 volume
    if [ ${#volumes_array[@]} -eq 0 ]; then
      echo -e "${YELLOW}  沒有任何可刪除的存儲卷。${RESET}"
    else
      echo "請選擇要刪除的存儲卷編號："
      
      # 步驟2：格式化並截斷顯示
      for i in "${!volumes_array[@]}"; do
        local vol_name="${volumes_array[$i]}"
        local display_name="$vol_name"
        # 如果名稱長度超過 60（通常是自動生成的），就截斷它
        if [ ${#display_name} -gt 60 ]; then
          display_name="${display_name:0:12}...${display_name: -4}" # 顯示前12位和後4位
        fi
        printf "  %2d) %s\n" "$((i + 1))" "$display_name"
      done
      
      # 步驟3：讓使用者輸入編號
      read -p "請輸入欲刪除的存儲卷編號 (輸入 0 取消)：" num

      # 步驟4：驗證輸入並映射回完整名稱
      if [[ "$num" =~ ^[0-9]+$ ]] && [ "$num" -gt 0 ] && [ "$num" -le "${#volumes_array[@]}" ]; then
        # 索引是編號減 1
        local volname_to_delete="${volumes_array[$((num - 1))]}"
        
        # 步驟5：執行刪除
        echo -e "${YELLOW}即將刪除：${volname_to_delete}${RESET}"
        read -p "請確認 (y/N): " confirm
        if [[ "$confirm" =~ ^[yY]$ ]]; then
            docker volume rm "$volname_to_delete"
            if [ $? -eq 0 ]; then
                echo -e "${GREEN}存儲卷 $volname_to_delete 已刪除。${RESET}"
            else
                # Docker 會返回具體的錯誤，直接顯示即可
                echo -e "${RED}刪除失敗。${RESET}" 
            fi
        else
            echo "操作已取消。"
        fi
      elif [[ "$num" == "0" ]]; then
        echo "操作已取消。"
      else
        echo -e "${RED}無效的編號。${RESET}"
      fi
    fi
    ;;
  0)
    echo "已返回"
    ;;
  *)
    echo -e "${RED}無效的選擇${RESET}"
    ;;
  esac
}

debug_container() {
  echo -e "${YELLOW}===== Docker 調試容器 =====${RESET}"

  containers=($(docker ps --format '{{.ID}} {{.Names}}'))
  count=${#containers[@]}

  if [ "$count" -eq 0 ]; then
    echo -e "${RED}沒有正在運行的容器。${RESET}"
    return 1
  fi

  echo "請選擇要進入的容器："
  for ((i=0; i<count; i+=2)); do
    index=$((i/2+1))
    echo "  [$index] ${containers[i+1]} (${containers[i]})"
  done

  read -p "輸入編號：" choice

  if ! [[ "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -lt 1 ] || [ "$choice" -gt $((count/2)) ]; then
    echo -e "${RED}無效的編號。${RESET}"
    return 1
  fi

  cid="${containers[$(( (choice-1)*2 ))]}"
  cname="${containers[$(( (choice-1)*2 + 1 ))]}"

  echo -e "${CYAN}嘗試使用 bash 進入容器：$cname${RESET}"
  if docker exec "$cid" which bash >/dev/null 2>&1; then
    docker exec -it "$cid" bash
    return 0
  fi

  echo -e "${YELLOW}bash 不存在，改用 sh 嘗試進入容器：$cname${RESET}"
  if docker exec "$cid" which sh >/dev/null 2>&1; then
    docker exec -it "$cid" sh
    return 0
  fi

  echo -e "${RED}無法進入容器 $cname：bash 和 sh 都無法使用。${RESET}"
  return 1
}

install_docker_app() {
  local app_name="$1"
  local ipv4=$(curl -s --connect-timeout 3 https://api4.ipify.org)
  local ipv6=$(curl -s -6 --connect-timeout 3 https://api6.ipify.org)
  Tips(){
  echo -e "${YELLOW}這是唯一的顯示機會！${RESET}"
    echo -e "${CYAN} 密碼/令牌不會儲存、不會記錄、不會再次出現。${RESET}"
    echo
    echo -e "${GRAY}我從不記錄日誌，也不保存密碼。${RESET}"
    echo -e "${GRAY}本腳本不產生日誌檔、不會留下任何痕跡。${RESET}"
    echo -e "${GRAY}你看過一次，就沒第二次。真的丟了，我也沒轍。${RESET}"
  }
  ips(){
    local host_port=$1
    local proto=${2:-http}
    if [ $proto == https ]; then
      [ -n "$ipv4" ] && echo -e "IPv4：${BLUE}https://${ipv4}:${host_port}${RESET}"
      [ -n "$ipv6" ] && echo -e "IPv6：${BLUE}https://[${ipv6}]:${host_port}${RESET}"
      return 0
    fi
    [ -n "$ipv4" ] && echo -e "IPv4：${BLUE}http://${ipv4}:${host_port}${RESET}"
    [ -n "$ipv6" ] && echo -e "IPv6：${BLUE}http://[${ipv6}]:${host_port}${RESET}"
  }
  echo -e "${CYAN} 安裝 $app_name${RESET}"
  local host_port
  if ! [[ "$app_name" == "zerotier" || "$app_name" == "cf_tunnel" ]]; then
    while true; do
      read -p "請輸入欲綁定的主機端口 (留空將從 10000-65535 中隨機選擇一個未被佔用的端口): " custom_port

      if [ -z "$custom_port" ]; then
        echo "🔄 正在尋找可用的隨機端口..."
        while true; do
          host_port=$(shuf -i 10000-65535 -n 1)
          if ! ss -tln | grep -q ":$host_port "; then
            echo -e "${GREEN} 找到可用端口: $host_port${RESET}"
            break
          fi
        done
        break
      else
        if [[ "$custom_port" =~ ^[0-9]+$ ]] && [ "$custom_port" -ge 1 ] && [ "$custom_port" -le 65535 ]; then
          if ss -tln | grep -q ":$custom_port "; then
            echo -e "${RED}端口 $custom_port 已被佔用，請重新輸入。${RESET}"
          else
            host_port=$custom_port
            echo -e "${GREEN} 端口 $host_port 可用。${RESET}"
            break
          fi
        else
          echo -e "${RED}無效的端口號，請輸入 1-65535 之間的數字。${RESET}"
        fi
      fi
    done
  fi
  mkdir -p /srv/docker
  case $app_name in
  bitwarden)
    if ! command -v site >/dev/null 2>&1; then
      echo "您好,您尚未安裝站點管理器,請先安裝"
      read "操作完成,請按任意鍵繼續..." -n1
      return 1
    fi
    read -p "請注意!bitwarden須強制https認證,需要綁定網址,是否繼續?(Y/n)" confirm
    confirm=${confirm,,}
    if ! [[ "$confirm" == y || "$confirm" == "" ]]; then
      echo "已取消安裝。"
    fi
    read -p "請輸入網址：" domain
    local admin_token=$(openssl rand -base64 48)
    mkdir -p /srv/docker/bitwarden
    docker run -d \
      --name bitwarden \
      --restart always \
      -v "/srv/docker/bitwarden:/data" \
      -p $host_port:80 \
      -e DOMAIN=https://$domain \
      -e LOGIN_RATELIMIT_MAX_BURST=10 \
      -e LOGIN_RATELIMIT_SECONDS=60 \
      -e ADMIN_RATELIMIT_MAX_BURST=10 \
      -e ADMIN_RATELIMIT_SECONDS=60 \
      -e ADMIN_SESSION_LIFETIME=20 \
      -e ADMIN_TOKEN=$admin_token \
      -e SENDS_ALLOWED=true \
      -e EMERGENCY_ACCESS_ALLOWED=true \
      -e WEB_VAULT_ENABLED=true \
      -e SIGNUPS_ALLOWED=true \
      vaultwarden/server:latest-alpine
    site setup $domain proxy 127.0.0.1 http $host_port || {
      echo "站點搭建失敗"
      return 1
    }
    echo "===== bitwarden 密碼管理器資訊 ====="
    echo "網址：https://$domain"
    echo "admin token： $admin_token"
    Tips
    read -p "操作完成，請按任意鍵繼續" -n1
    ;;
  portainer)
    mkdir -p /srv/docker/portainer
    docker run -d \
      -p $host_port:9443 \
      --name portainer \
      --restart=always \
      -v /var/run/docker.sock:/var/run/docker.sock \
      -v /srv/docker/portainer:/data \
      portainer/portainer-ce:alpine
    echo "訪問位置："
    ips $host_port https
    echo -e "${CYAN}已啟用 Portainer HTTPS 自簽連線（TLS 1.3 加密保護）${RESET}"
    echo -e "${YELLOW} 首次連線可能跳出「不受信任憑證」提示，請選擇信任即可${RESET}"
    echo -e "${GRAY} 傳輸已經使用頂級加密協議（TLS 1.3），安全性與 Let's Encrypt 相同${RESET}"
    read -p "操作完成，請按任意鍵繼續" -n1
    ;;
  uptime-kuma)
    mkdir -p /srv/docker/uptime-kuma
    docker run -d --restart=always -p $host_port:3001 -v /srv/docker/uptime-kuma:/app/data --name uptime-kuma louislam/uptime-kuma:latest
    echo "===== uptime kuma資訊 ====="
    echo "訪問位置："
    ips $host_port
    read -p "操作完成，請按任意鍵繼續" -n1
    ;;
  openlist)
    mkdir /srv/docker/openlist
    docker run --user $(id -u):$(id -g) -d --restart=always -v /srv/docker/openlist:/opt/openlist/data -p $host_port:5244 -e UMASK=022 --name="openlist" openlistteam/openlist:latest-lite-aria2
		echo "正在讀取密碼"
		for i in {1..10}; do
      local admin_pass=$(docker logs openlist 2>&1 | grep 'initial password is' | awk '{print $NF}')
      if [ -n "$admin_pass" ]; then
        break
      fi
      sleep 1
    done
    echo "===== openlist資訊 ====="
    echo "訪問位置："
    ips $host_port
    echo -e "${GREEN}管理員資訊：${RESET}"
    echo -e "帳號名：${CYAN}admin${RESET}"
    echo -e "密碼：${YELLOW}$admin_pass${RESET}"
    Tips
    read -p "操作完成，請按任意鍵繼續" -n1
    ;;
  cloudreve)
    mkdir -p /srv/docker/cloudreve
    cd /srv/docker/cloudreve
    mkdir {avatar,uploads}
    touch {conf.ini,cloudreve.db}
    docker run -d \
      --name cloudreve \
      --restart always \
      -p $host_port:5212 \
      -v /srv/downloads:/data \
      -v /srv/docker/cloudreve/uploads:/cloudreve/uploads \
      -v /srv/docker/cloudreve/conf.ini:/cloudreve/conf.ini \
      -v /srv/docker/cloudreve/cloudreve.db:/cloudreve/cloudreve.db \
      -v /srv/docker/cloudreve/avatar:/cloudreve/avatar \
      cloudreve/cloudreve:latest
    echo "===== cloudreve資訊 ====="
    echo "訪問位置："
    ips $host_port
    echo -e "${GREEN}管理員資訊：${RESET}${RESET}"
    echo -e "${YELLOW}帳號密碼第一次註冊即可是管理員${RESET}"
    echo -e "${CYAN}Cloudreve 已內建 Aria2，無需另外部署。${RESET}"
    echo -e "  🔑 Token：${GREEN}空白即可，無需填入${RESET}"
    read -p "操作完成，請按任意鍵繼續" -n1
    ;;
  zerotier)
    docker run -d \
      --restart always \
      --name zerotier --device=/dev/net/tun \
      --net=host \
      --cap-add=NET_ADMIN \
      --cap-add=SYS_ADMIN \
      -v /var/lib/zerotier-one:/var/lib/zerotier-one \
      zyclonite/zerotier
    read -p "請輸入網路id：" zt_id
    docker exec zerotier zerotier-cli join $zt_id
    ;;
  Aria2Ng)
    mkdir -p /srv/downloads
    mkdir -p /srv/docker/aria2
    local aria_rpc=$(openssl rand -hex 12)
    docker run -d \
      --name aria2 \
      --restart always \
      -p 6800:6800 \
      -e RPC_SECRET=$aria_rpc \
      -e RPC_PORT=6800 \
      -e DOWNLOAD_DIR=/data \
      -e PUID=0 \
      -e PGID=0 \
      -e UMASK_SET=022 \
      -e TZ=Asia/Shanghai \
      -v /srv/docker/aria2/config:/config \
      -v /srv/downloads:/data \
      ddsderek/aria2-pro
    docker run -d \
      --name Aria2Ng \
      --log-opt max-size=1m \
      --restart always \
      -p $host_port:6880 \
      p3terx/ariang
    echo "===== Aria2Ng資訊 ====="
    echo "訪問位置："
    ips $host_port
    echo "=====aria2填入 Aria2Ng資訊 =====" 
    local ip_6800=$(ips "6800")
    echo -e "${YELLOW}在 Aria2Ng 中填入如下格式：${RESET}"
    ips "6800"
    echo -e "${YELLOW}請選擇能從你 Aria2Ng 連線的 IP 地址！${RESET}"
    echo -e "Token: ${CYAN}$aria_rpc${RESET}"
    echo -e "${YELLOW} 如果瀏覽器無法連上 RPC，請檢查：${RESET}"
    echo "1. 是否開啟 6800 端口"
    echo "2. 是否被防火牆攔住"
    echo "3. Aria2Ng 中 RPC 協議需為 http，不支援 https"
    Tips
    echo -e "${GREEN}搞定就行，沒搞定就看上面說的再來找我，別直接怪我這腳本壞了 :)${RESET}"
    read -p "操作完成，請按任意鍵繼續" -n1
    ;;
    nextcloud)
      mkdir -p /srv/docker/nextcloud
      if ! command -v mysql >/dev/null 2>&1; then
        if ! command -v redis-server >/dev/null 2>&1; then
          docker run -d --name nextcloud \
            -p $host_port:80 \
            --restart always \
            -v /srv/docker/nextcloud:/var/www/html \
            --add-host=host.docker.internal:host-gateway
            nextcloud:stable
        else
          docker run -d --name nextcloud \
            -p $host_port:80 \
            --restart always \
            -v /srv/docker/nextcloud:/var/www/html \
            -e REDIS_HOST=host.docker.internal \
            --add-host=host.docker.internal:host-gateway \
            nextcloud:stable
           configure_redis_with_firewall_interface
        fi
      else
        check_dba
        local db_pass=$(dba mysql add nextcloud ncuser --force)
        if command -v redis-server >/dev/null 2>&1; then
          docker run -d --name nextcloud \
            -p $host_port:80 \
            --restart always \
            -v /srv/docker/nextcloud:/var/www/html \
            -e MYSQL_HOST=host.docker.internal \
            -e MYSQL_DATABASE=nextcloud \
            -e MYSQL_USER=ncuser \
            -e MYSQL_PASSWORD=$db_pass \
            -e REDIS_HOST=host.docker.internal \
            --add-host=host.docker.internal:host-gateway \
            nextcloud:stable
            configure_redis_with_firewall_interface
        else
          docker run -d --name nextcloud \
            -p $host_port:80 \
            --restart always \
            -v /srv/docker/nextcloud:/var/www/html \
            -e MYSQL_HOST=host.docker.internal \
            -e MYSQL_DATABASE=nextcloud \
            -e MYSQL_USER=ncuser \
            -e MYSQL_PASSWORD=$db_pass \
            --add-host=host.docker.internal:host-gateway \
            nextcloud:stable
        fi
      fi
      echo "===== Nextcloud資訊 ====="
      echo "訪問位置："
      ips $host_port
      ;;
    cloudflared)
      read -p "請輸入您的隧道Token：" cloudflared_token
      docker run -d --name cloudflared --network host --restart always cloudflare/cloudflared:latest tunnel --no-autoupdate run --token $cloudflared_token
      ;;
    tailscale)
      case $system in
      1|2)
        curl -fsSL https://tailscale.com/install.sh | sh
        tailscale up
        ;;
      *)
        echo "不支援的系統。"
        sleep 1
        return 1
        ;;
      esac
      echo -e "tailscale本地指令：${YELLOW}tailscale${RESET}"
      ;;
    beszel)
      mkdir -p /srv/docker/beszel
      docker run -d \
        --name beszel \
        --restart=always \
        -v /srv/docker/beszel:/beszel_data \
        -p $host_port:8090 \
        henrygd/beszel
      ;;
    adminer)
      docker run -d --name adminer -p $host_port:8080 --add-host=host.docker.internal:host-gateway adminer
      echo -e "進去之後要填主機名稱為：${YELLOW}host.docker.internal${RESET}"
      ;;
  esac
  echo -e "${GREEN}$app_name 已成功安裝！${RESET}"
}

install_docker_and_compose() {
  # 安裝 Docker
  if ! command -v docker &>/dev/null; then

    if [ "$system" -eq 1 ] || [ "$system" -eq 2 ]; then
      if [ -f /etc/fedora-release ]; then
        dnf config-manager addrepo --from-repofile https://download.docker.com/linux/fedora/docker-ce.repos
        dnf install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
        systemctl enable --now docker-compose-plugin
      elif [ -f /etc/centos-release ]; then
        dnf -y install dnf-plugins-core
        dnf config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
        dnf install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
        systemctl enable --now docker-compose-plugin
      elif [ -f /etc/redhat-release ]; then
        dnf -y install dnf-plugins-core
        dnf config-manager --add-repo https://download.docker.com/linux/rhel/docker-ce.repo
        dnf install -y \
          docker-ce \
          docker-ce-cli \
          containerd.io \
          docker-buildx-plugin \
          docker-compose-plugin
        systemctl enable --now docker
      else
        # 使用官方腳本安裝
        curl -fsSL https://get.docker.com | sh
      fi
    elif [ "$system" -eq 3 ]; then
      # Alpine Linux
      apk add docker
    fi
  fi
  # 檢查 Docker Compose (v1 或 v2 plugin) 是否已安裝
  if ! command -v docker-compose &>/dev/null && ! docker compose version &>/dev/null; then

    # 對於 Debian/Ubuntu/CentOS 系統，我們需要手動安裝
    if [ "$system" -eq 1 ] || [ "$system" -eq 2 ]; then
      # 使用 GitHub API 獲取最新的 release tag name
      local LATEST_COMPOSE_VERSION=$(curl -s https://api.github.com/repos/docker/compose/releases/latest | jq -r .tag_name)

      if [ -z "$LATEST_COMPOSE_VERSION" ] || [ "$LATEST_COMPOSE_VERSION" == "null" ]; then
        echo -e "${RED}無法獲取最新的 Docker Compose 版本號。請檢查您的網路連線或稍後再試。${RESET}" >&2
        sleep 3
        exit 1
      fi
      local DOCKER_CONFIG=${DOCKER_CONFIG:-/usr/local/lib/docker}
      mkdir -p "$DOCKER_CONFIG/cli-plugins"
      
      # 使用獲取到的最新版本號來下載
      if ! curl -SL "https://github.com/docker/compose/releases/download/${LATEST_COMPOSE_VERSION}/docker-compose-linux-$(uname -m)" -o "$DOCKER_CONFIG/cli-plugins/docker-compose" ; then
        echo -e "${RED}Docker Compose 下載失敗。${RESET}" >&2
        sleep 3
        exit 1
      fi

      chmod +x "$DOCKER_CONFIG/cli-plugins/docker-compose"

    elif [ "$system" -eq 3 ]; then
      # Alpine Linux 直接使用包管理器安裝
      apk add docker-cli-compose
    fi

    # 驗證安裝
    if ! docker compose version &>/dev/null; then
      echo -e "${RED}Docker Compose 安裝失敗，請手動檢查。${RESET}" >&2
      sleep 3
      exit 1
    fi
  fi

  # 啟用與開機自啟
  if [ "$system" -eq 1 ] || [ "$system" -eq 2 ]; then
    if ! systemctl is-enabled docker &>/dev/null; then
      systemctl enable docker
    fi
    if ! systemctl is-active docker &>/dev/null; then
      systemctl start docker
    fi
  elif [ "$system" -eq 3 ]; then
    if ! rc-update show | grep -q docker; then
      rc-update add docker default
    fi
    if ! service docker status | grep -q running; then
        service docker start
      fi
  fi
  sleep 2.5
}
uninstall_docker() {
  echo -e "${RED}警告：此操作將會徹底刪除 Docker Engine, Docker Compose，以及所有的容器、映像、儲存卷和網路。${RESET}"
  echo -e "${YELLOW}所有 Docker 資料將會永久遺失！${RESET}"
  read -p "您確定要繼續嗎？ [y/N]: " confirm
  
  # 如果使用者輸入的不是 y 或 Y，則中止操作
  if [[ ! "$confirm" =~ ^[yY]$ ]]; then
    echo "操作已取消。"
    return
  fi

  echo "開始卸載 Docker..."

  # 根據不同系統停止並移除 Docker
  if [ "$system" -eq 1 ] || [ "$system" -eq 2 ]; then
    # 停止並禁用 Systemd 服務
    echo "正在停止並禁用 Docker 服務..."
    systemctl stop docker.socket &>/dev/null
    systemctl stop docker &>/dev/null
    systemctl disable docker &>/dev/null

    # 使用對應的包管理器卸載
    echo "正在移除 Docker 相關套件..."
    if command -v apt-get &>/dev/null; then
      apt-get purge -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin docker-ce-rootless-extras
      apt-get autoremove -y --purge
    elif command -v dnf &>/dev/null; then
      dnf remove -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    elif command -v yum &>/dev/null; then
      yum remove -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    fi

  elif [ "$system" -eq 3 ]; then
    # 停止並禁用 OpenRC 服務
    echo "正在停止並禁用 Docker 服務..."
    service docker stop &>/dev/null
    rc-update del docker default &>/dev/null
    
    # 使用 apk 卸載
    echo "正在移除 Docker 相關套件..."
    apk del docker docker-cli-compose
  fi

  # 刪除所有殘留的 Docker 資料
  echo "正在刪除殘留的 Docker 資料 (映像, 容器, 儲存卷)..."
  rm -rf /var/lib/docker
  rm -rf /var/lib/containerd
  rm -rf /etc/docker
  # 手動刪除可能由腳本安裝的 compose plugin，以防萬一
  rm -f /usr/local/lib/docker/cli-plugins/docker-compose
  # 刪除 docker group
  groupdel docker &>/dev/null

  echo -e "${GREEN}Docker 已成功卸載。${RESET}"
  sleep 1
}
manage_docker_app() {
  clear
  local app_name="$1"
  local can_update="false"
  local app_desc=""
  local app_name2=""
  type=${type:-none}

  case "$app_name" in
  bitwarden)
    app_name2=$app_name
    can_update="true"
    app_desc="Bitwarden 是一款輕量級密碼管理工具，支援自行架設並提供瀏覽器擴充。(需要一個域名和你要安裝站點管理器)"
    ;;
  cloudreve)
    app_name2=$app_name
    can_update="true"
    app_desc="Cloudreve Cloudreve 是可多用戶的自建雲端硬碟平台，支援外掛儲存與分享連結。（aria2比較不會更新，所以我們這裡提供更新的是cloudreve本體）"
    ;;
  portainer)
    app_name2=$app_name
    can_update="true"
    app_desc="Portainer 提供 Web UI 管理 Docker 容器、映像、網路等功能。"
    ;;
      
  uptime-kuma)
    app_name2="Uptime Kuma"
    can_update="true"
    app_desc="Uptime Kuma 可監控網站與服務狀態，支援通知與圖表呈現。"
    ;;
  openlist)
    app_name2=$app_name
    can_update="true"
    app_desc="openlist 可將 Google Drive、OneDrive 等雲端硬碟掛載為可瀏覽的目錄。"
    ;;
  nextcloud)
    app_name2="Nextcloud"
    can_update="true"
    app_desc="Nextcloud：自架雲端硬碟，解決個人或團隊檔案同步與分享。支援多用戶權限管理、網頁介面、WebDAV，並可搭配 OnlyOffice 成為完整辦公套件。"
    ;;
  zerotier)
    app_name2=$app_name
    can_update="true"
    type=vpn
    app_desc="ZeroTier 可建立虛擬 VPN 網路，支援 NAT 穿透無需開放埠口。"
    ;;
  cloudflared)
    app_name2="Cloudflare tunnel"
    can_update="true"
    type=vpn
    app_desc="Cloudflare Tunnel 可將本地伺服器安全地暴露在網路上，無需開放防火牆或設置 DDNS。適合自架面板、Web 服務等使用情境，具備免費 SSL、全自動憑證管理及中轉防護。搭配 Cloudflare 帳號即可快速部署。"
    ;;
  Aria2Ng)
    app_name2=$app_name
    can_update="true"
    app_desc="Aria2Ng 是 Aria2 的圖形化網頁管理介面，輕量易用，並會自動部署內建的 Aria2 核心。"
    ;;
  tailscale)
    app_name2=$app_name
    can_update="false"
    type=vpn
    app_desc="一款基於 WireGuard 的 VPN 工具，讓多台設備自動安全連網，無需複雜設定，輕鬆打造私人內網。雖非容器應用，但可完美搭配多台 Docker 主機使用，${YELLOW}【屬於純本地安裝的輕量級工具】${RESET}。"
    ;;
  beszel)
    app_name2=Beszel
    can_update="true"
    app_desc="Beszel 是一款輕量級的伺服器監控平台，提供 Docker 容器統計、歷史數據追蹤和警報功能"
    ;;
  adminer)
    app_name2=adminer
    can_update="true"
    app_desc="Adminer：支援MySQL/MariaDB、PostgreSQL等多資料庫的輕量管理工具，可透過瀏覽器操作。"
    ;;
  *)
    echo -e "${RED}未知應用：$app_name${RESET}"
    return
    ;;
  esac
  if [ $app_name = tailscale ]; then
    local container_exists=$(command -v tailscale)
  else
    local container_exists=$(docker ps -a --format '{{.Names}}' | grep -w "^$app_name$")
  fi

  echo -e "${BOLD_CYAN} 管理 Docker 應用：$app_name2${RESET}"
  echo "-----------------------------"

  echo -e "${CYAN}狀態檢查：${RESET}"
  if [ -n "$container_exists" ]; then
    echo -e "${GREEN}已安裝${RESET}"
  else
    echo -e "${YELLOW}尚未安裝${RESET}"
  fi
  echo

  echo -e "${CYAN}應用介紹：${RESET}"
  [[ $app_name == tailscale ]] && echo -e "${YELLOW}Tailscale 不以 Docker 容器形式運行，但非常適合 Docker 用戶跨主機串聯使用${RESET}"
  echo -e "$app_desc"
  echo
  
  if [ -n "$container_exists" ]; then
    echo -e "${CYAN}訪問地址：${RESET}"

    # 只對需要網路訪問的應用獲取 IP 和 Port
    if ! [ $type = vpn ]; then
      local host_port=$(docker inspect -f '{{range $p, $conf := .NetworkSettings.Ports}}{{if $conf}}{{(index $conf 0).HostPort}}{{end}}{{end}}' "$app_name" 2>/dev/null)
      host_port="${host_port:-未知}"
      local ipv4=$(curl -s --connect-timeout 3 https://api4.ipify.org)
      local ipv6=$(curl -s -6 --connect-timeout 3 https://api6.ipify.org)

      # 使用 if/elif/else 結構來處理不同情況
      if [ "$app_name" == "portainer" ]; then
        [ -n "$ipv4" ] && echo -e "IPv4：${BLUE}https://${ipv4}:${host_port}${RESET}"
        [ -n "$ipv6" ] && echo -e "IPv6：${BLUE}https://[${ipv6}]:${host_port}${RESET}"
      else
        # 其他所有需要顯示 IP 的應用
        [ -n "$ipv4" ] && echo -e "IPv4：${BLUE}http://${ipv4}:${host_port}${RESET}"
        [ -n "$ipv6" ] && echo -e "IPv6：${BLUE}http://[${ipv6}]:${host_port}${RESET}"
      fi

      check_site_proxy_domain $host_port
      echo
    fi
  fi

  echo -e "${CYAN}操作選單：${RESET}"
  if [ -z "$container_exists" ]; then
    echo "1. 安裝"
  else
    [[ "$can_update" == "true" ]] && echo "2. 更新"
    echo "3. 移除"
    if ! [ $type = vpn ]; then
      echo "4. 配置域名訪問"
      echo "5. 移除現有的域名訪問"
    fi
  fi
  echo "0. 返回"
  echo

  echo -n -e "${YELLOW}請輸入欲執行的選項：${RESET}"
  read choice

  case "$choice" in
  1)
    if [ -n "$container_exists" ]; then
      echo -e "${YELLOW}已安裝，無需重複安裝。${RESET}"
      return
    fi
    install_docker_app "$app_name"
    ;;
  2)
    if [[ "$can_update" != "true" ]]; then
      echo -e "${RED}此應用不支援更新操作。${RESET}${RESET}"
      return
    fi
    if [ -z "$container_exists" ]; then
      echo -e "${RED}尚未安裝，無法更新。${RESET}"
      return
    fi
    update_docker_container "$app_name"
    ;;
  3)
    if [ -z "$container_exists" ]; then
      echo -e "${RED}尚未安裝，無法移除。${RESET}"
      return
    fi
    uninstall_docker_app "$app_name"
    ;;
  4)
    check_site
    read -p "請輸入域名:" domain
    if [ $app_name == portainer ]; then
      site setup $domain proxy 127.0.0.1 https $host_port || {
      echo "站點搭建失敗"
      return 1
      }
    else
      site setup $domain proxy 127.0.0.1 http $host_port || {
        echo "站點搭建失敗"
        return 1
      }
    fi
    if [ $app_name == nextcloud ]; then
      local count=$(docker exec -u www-data nextcloud php occ config:system:get trusted_domains | wc -l)
      docker exec -u www-data nextcloud php occ config:system:set trusted_domains $count --value="$domain"
    fi
    echo -e "${GREEN}站點搭建完成，網址：$domain${RESET}"
    read -p "操作完成，按任意鍵繼續" -n1
    ;;
  5)
    check_site
    if select_domain_from_proxy $host_port; then
      site del $SELECTED_DOMAIN || {
        echo "站點刪除失敗"
        return 1
      }
    fi
    if [ $app_name == nextcloud ]; then
      echo "請進入/srv/docker/nextcloud/config/config.php"
      echo "將trusted_domains您的域名$SELECTED_DOMAIN刪除並陣列索引連續"
      read -p "請按任意鍵修改..." -n1
      nano /srv/docker/nextcloud/config/config.php
    fi
    echo -e "${GREEN}站點刪除完成${RESET}"
    read -p "操作完成，按任意鍵繼續" -n1
    ;;
  0)
    return
    ;;
  *)
    echo -e "${RED}無效的選項。${RESET}"
    ;;
  esac
}

restart_docker_container() {
  echo "正在讀取所有容器..."
  local all_containers=$(docker ps -a --format "{{.Names}}")
  if [ -z "$all_containers" ]; then
    echo -e "${GREEN}系統中沒有任何容器！${RESET}"
      return
  fi

  local container_list=()
  local index=1

  echo "以下是所有容器："
  while IFS= read -r name; do
      container_list+=("$name")
      echo "$index） $name"
      index=$((index + 1))
  done <<< "$all_containers"
  echo "$index） all（全部）"
  echo
  read -p "請輸入要重啟的編號（可空白隔開多個）: " input_indexes
  if [ -z "$input_indexes" ]; then
    echo -e "${RED}沒有輸入任何編號${RESET}"
      return
  fi
  local all_selected=false
  local selected_indexes=()
  for i in $input_indexes; do
    if ! [[ "$i" =~ ^[0-9]+$ ]]; then
      echo -e "${RED}無效輸入：$i${RESET}"
      return
    fi
    if [ "$i" -eq "$index" ]; then
      all_selected=true
    elif [ "$i" -ge 1 ] && [ "$i" -lt "$index" ]; then
      selected_indexes+=("$i")
    else
      echo -e "${RED}編號 $i 不存在！${RESET}"
      return
    fi
  done
  if $all_selected && [ ${#selected_indexes[@]} -gt 0 ]; then
    echo -e "${RED}無法同時選擇編號與 all，請分開操作。${RESET}"
    return
  fi
  if $all_selected; then
    echo "正在重啟所有容器..."
    docker restart $(docker ps -a --format "{{.Names}}")
    echo -e "${GREEN}所有容器已重啟${RESET}"
  else
    for idx in "${selected_indexes[@]}"; do
      local name="${container_list[$((idx-1))]}"
      echo " 正在重啟容器：$name"
      docker restart "$name"
      if [[ $? -eq 0 ]]; then
        echo -e "${GREEN}容器 $name 已重啟${RESET}"
      else
        echo -e "${RED}容器 $name 重啟失敗${RESET}"
      fi
    done
  fi
}

show_docker_containers() {
  local target_page="$1"
  [ -z "$target_page" ] && target_page=1
  
  D_GREEN='\033[0;32m'

  if ! command -v docker &>/dev/null; then echo -e "${RED}Docker 未安裝或未運行。${RESET}"; return 1; fi

  display_width() {
    local str="$1"; local width=0; local i=0; local len=${#str}
    while [ $i -lt $len ]; do
      local char="${str:$i:1}"
      if [[ $(printf "%d" "'$char") -gt 127 ]] 2>/dev/null; then width=$((width + 2)); else width=$((width + 1)); fi
      i=$((i + 1))
    done
    echo $width
  }
  pad_str() {
    local text="$1"; local max="$2"; local align="$3"
    local w; w=$(display_width "$text")
    local pad=$((max - w)); [[ $pad -lt 0 ]] && pad=0
    local spaces; printf -v spaces "%*s" $pad ""
    if [[ "$align" == "right" ]]; then echo "${spaces}${text}"; else echo "${text}${spaces}"; fi
  }

  # --- 資料獲取 ---
  declare -A restart_map
  local all_ids=$(docker ps -a -q)
  
  if [ -z "$all_ids" ]; then 
    echo -e "${YELLOW}沒有任何容器存在。${RESET}"
    TOTAL_PAGES=1
    return 0
  fi

  while IFS='|' read -r id policy; do 
      restart_map["$id"]="$policy"
  done < <(docker inspect --format '{{printf "%.12s" .Id}}|{{.HostConfig.RestartPolicy.Name}}' $all_ids 2>/dev/null)

  local -a render_rows=() 
  local raw_ps_output=$(docker ps -a --format "{{.ID}}§{{.Names}}§{{.State}}§{{.Ports}}")

  # --- 解析迴圈 (修正去重邏輯) ---
  while IFS='§' read -r id name status ports_raw; do
    local status_zh
    case "$status" in 
      "running") status_zh="${D_GREEN}運行中${RESET}";; "exited") status_zh="${GRAY}已停止${RESET}";; 
      "paused") status_zh="${YELLOW}已暫停${RESET}";; "created") status_zh="${BLUE}已建立${RESET}";; 
      *) status_zh="$status";; 
    esac
    
    local policy_raw="${restart_map["$id"]}"
    local restart_zh
    case "$policy_raw" in 
      "no") restart_zh="不重啟";; "always") restart_zh="永遠重啟";; 
      "on-failure") restart_zh="錯誤時重啟";; "unless-stopped") restart_zh="除手動停止外";; 
      *) restart_zh="${policy_raw:- -}";; 
    esac

    local has_port=false
    # [關鍵修改 1] 宣告一個臨時關聯陣列，用來記錄這個容器已經處理過哪些端口組合
    declare -A seen_ports 

    if [[ -n "$ports_raw" ]]; then
      IFS=',' read -ra PORT_ARR <<< "$ports_raw"
      for p in "${PORT_ARR[@]}"; do
        p="${p#"${p%%[![:space:]]*}"}" # trim
        
        if [[ "$p" == *"->"* ]]; then
          local ip_ext="${p%%->*}"; local int_proto="${p##*->}"
          local ext_port="${ip_ext##*:}"; local int_port="${int_proto%%/*}"; local proto="${int_proto##*/}"
          local port_key="${ext_port}:${int_port}:${proto}"
          if [[ -z "${seen_ports[$port_key]}" ]]; then
            render_rows+=("$name|$status_zh|$ext_port|$int_port|$proto|$restart_zh")
          seen_ports["$port_key"]=1 # 標記為已處理
                has_port=true
          fi
        fi
      done
    fi
    unset seen_ports

    if [ "$has_port" = false ]; then render_rows+=("$name|$status_zh|-|-|-|$restart_zh"); fi
  done <<< "$raw_ps_output"

  # --- 分頁計算 ---
  local total_rows=${#render_rows[@]}
  local page_size=10
  TOTAL_PAGES=$(( (total_rows + page_size - 1) / page_size ))
  [[ $TOTAL_PAGES -eq 0 ]] && TOTAL_PAGES=1
  
  if [ "$target_page" -gt "$TOTAL_PAGES" ]; then target_page=$TOTAL_PAGES; fi
  if [ "$target_page" -lt 1 ]; then target_page=1; fi
  CURRENT_PAGE=$target_page 

  # --- 渲染準備 ---
  local start_index=$(( (target_page - 1) * page_size ))
  local end_index=$(( start_index + page_size - 1 ))
  if [ $end_index -ge $total_rows ]; then end_index=$(( total_rows - 1 )); fi

  local headers=("容器名" "狀態" "外埠" "內埠" "協議" "重啟策略")
  local -a col_widths=(0 0 0 0 0 0)
  for i in "${!headers[@]}"; do col_widths[$i]=$(display_width "${headers[$i]}"); done

  local -a page_data=()
  for ((i=start_index; i<=end_index; i++)); do page_data+=("${render_rows[$i]}"); done

  local last_name_check=""
  local -a display_rows=()
  for row_str in "${page_data[@]}"; do
      IFS='|' read -r n s e i p r <<< "$row_str"
      local d_n="$n"; local d_s="$s"; local d_r="$r"
      if [[ "$n" == "$last_name_check" ]]; then d_n=""; d_s=""; d_r=""; else last_name_check="$n"; fi
      
      local clean_s=$(echo -e "$d_s" | sed "s/\x1B\[[0-9;]*[a-zA-Z]//g")
      [ $(display_width "$d_n") -gt ${col_widths[0]} ] && col_widths[0]=$(display_width "$d_n")
      [ $(display_width "$clean_s") -gt ${col_widths[1]} ] && col_widths[1]=$(display_width "$clean_s")
      [ $(display_width "$e") -gt ${col_widths[2]} ] && col_widths[2]=$(display_width "$e")
      [ $(display_width "$i") -gt ${col_widths[3]} ] && col_widths[3]=$(display_width "$i")
      [ $(display_width "$p") -gt ${col_widths[4]} ] && col_widths[4]=$(display_width "$p")
      [ $(display_width "$d_r") -gt ${col_widths[5]} ] && col_widths[5]=$(display_width "$d_r")
      display_rows+=("$d_n|$d_s|$e|$i|$p|$d_r")
  done

  # --- 實際輸出 ---
  local header_line=""
  for idx in "${!headers[@]}"; do
      local align="left"; [[ "${headers[$idx]}" == *"埠"* ]] && align="right"
      header_line+=$(pad_str "${headers[$idx]}" "${col_widths[$idx]}" "$align")
      [[ $idx -lt 5 ]] && header_line+=" | "
  done
  echo -e "${BLUE}${header_line}${RESET}"
  
  for row_str in "${display_rows[@]}"; do
      IFS='|' read -r n s e i p r <<< "$row_str"
      local line=""
      line+=$(pad_str "$n" "${col_widths[0]}" "left") && line+=" | "
      local clean_s=$(echo -e "$s" | sed "s/\x1B\[[0-9;]*[a-zA-Z]//g")
      local s_pad=$(( ${col_widths[1]} - $(display_width "$clean_s") ))
      line+="${s}"; printf -v sp "%*s" $s_pad ""; line+="$sp | "
      line+=$(pad_str "$e" "${col_widths[2]}" "right") && line+=" | "
      line+=$(pad_str "$i" "${col_widths[3]}" "right") && line+=" | "
      line+=$(pad_str "$p" "${col_widths[4]}" "left") && line+=" | "
      line+=$(pad_str "$r" "${col_widths[5]}" "left")
      echo -e "$line"
  done
  echo -e "${GRAY}頁碼: $CURRENT_PAGE / $TOTAL_PAGES${RESET}"
}

start_docker_container() {
    echo "正在檢查已停止的容器..."

    # 取得所有已停止容器名稱
    local stopped_containers=$(docker ps -a --filter "status=exited" --format "{{.Names}}")

    if [ -z "$stopped_containers" ]; then
        echo -e "${GREEN} 沒有已停止的容器！${RESET}"
        return
    fi

    local container_list=()
    local index=1

    echo "以下是已停止的容器："
    while IFS= read -r name; do
        container_list+=("$name")
        echo "$index） $name"
        index=$((index + 1))
    done <<< "$stopped_containers"

    echo "$index） all（全部）"
    echo

    read -p "請輸入要啟動的編號（可空白隔開多個）：" input_indexes

    if [ -z "$input_indexes" ]; then
        echo -e "${RED}未輸入任何選項，操作中止。${RESET}"
        return
    fi

    # 判斷是否選到 all
    local all_selected=false
    local selected_indexes=()

    for i in $input_indexes; do
        if ! [[ "$i" =~ ^[0-9]+$ ]]; then
            echo -e "${RED}無效輸入：$i${RESET}"
            return
        fi

        if [ "$i" -eq "$index" ]; then
            all_selected=true
        elif [ "$i" -ge 1 ] && [ "$i" -lt "$index" ]; then
            selected_indexes+=("$i")
        else
            echo -e "${RED}編號 $i 不存在！${RESET}"
            return
        fi
    done

    # 判斷 all 是否單獨被選
    if $all_selected && [ ${#selected_indexes[@]} -gt 0 ]; then
        echo -e "${RED}無法同時選擇編號與 all，請分開操作。${RESET}"
        return
    fi

    if $all_selected; then
        echo " 正在啟動全部已停止的容器..."
        docker start $(docker ps -a --filter "status=exited" --format "{{.Names}}")
        echo -e "${GREEN}全部容器已啟動${RESET}"
    elif [ ${#selected_indexes[@]} -gt 0 ]; then
        for idx in "${selected_indexes[@]}"; do
            local selected_container="${container_list[$((idx-1))]}"
            echo "正在啟動容器：$selected_container"
            docker start "$selected_container"
            if [[ $? -eq 0 ]]; then
              echo -e "${GREEN}容器 $selected_container 已啟動${RESET}"
            else
              echo -e "${RED}容器 $selected_container 啟動失敗${RESET}"
            fi
        done
    else
      echo -e "${YELLOW}沒有選擇任何容器，操作中止。${RESET}"
    fi
}

select_domain_from_proxy() {
  local port=$1
  local domains
  mapfile -t domains < <(site api search proxy_domain "127.0.0.1:$port")

  if [ ${#domains[@]} -eq 0 ]; then
    echo -e "${YELLOW}無域名！${RESET}"
    return 1
  fi

  echo "請選擇一個域名（只能選一個）："
  for i in "${!domains[@]}"; do
    printf "%d) %s\n" $((i+1)) "${domains[i]}"
  done

  local choice
  while true; do
    read -rp "輸入數字選擇： " choice
    if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#domains[@]} )); then
      SELECTED_DOMAIN="${domains[choice-1]}"
      return 0
    else
      echo "無效選擇，請輸入 1 到 ${#domains[@]} 的數字。"
    fi
  done
}


stop_docker_container() {
    echo "正在檢查已啟動的容器..."

    local running_containers=$(docker ps --format "{{.Names}}")

    if [ -z "$running_containers" ]; then
        echo -e "${GREEN}沒有正在運行的容器！${RESET}"
        return
    fi

    local container_list=()
    local index=1

    echo "以下是正在運行的容器："
    while IFS= read -r name; do
        container_list+=("$name")
        echo "$index） $name"
        index=$((index + 1))
    done <<< "$running_containers"

    echo "$index） all（全部）"
    echo

    read -p "請輸入要停止的編號（可空白隔開多個）: " input_indexes

    if [ -z "$input_indexes" ]; then
        echo -e "${RED}未輸入任何選項，操作中止。${RESET}"
        return
    fi

    local all_selected=false
    local selected_indexes=()

    for i in $input_indexes; do
        if ! [[ "$i" =~ ^[0-9]+$ ]]; then
          echo -e "${RED}無效輸入：$i${RESET}"
            return
        fi

        if [ "$i" -eq "$index" ]; then
            all_selected=true
        elif [ "$i" -ge 1 ] && [ "$i" -lt "$index" ]; then
            selected_indexes+=("$i")
        else
          echo -e "${RED}編號 $i 不存在！${RESET}"
            return
        fi
    done

    # 不允許同時選 all + 編號
    if $all_selected && [ ${#selected_indexes[@]} -gt 0 ]; then
        echo -e "${RED}無法同時選擇編號與 all，請分開操作。${RESET}"
        return
    fi

    if $all_selected; then
        echo " 正在停止全部正在運行的容器..."
        docker stop $(docker ps --format "{{.Names}}")
        echo -e "${GREEN}全部容器已停止${RESET}"
    elif [ ${#selected_indexes[@]} -gt 0 ]; then
        for idx in "${selected_indexes[@]}"; do
            local selected_container="${container_list[$((idx-1))]}"
            echo " 正在停止容器：$selected_container"
            docker stop "$selected_container"
            if [[ $? -eq 0 ]]; then
              echo -e "${GREEN}容器 $selected_container 已停止${RESET}"
            else
              echo -e "${RED}容器 $selected_container 停止失敗${RESET}"
            fi
        done
    else
      echo -e "${YELLOW}沒有選擇任何容器，操作中止。${RESET}"
    fi
}

update_restart_policy() {
    echo " 熱修改容器重啟策略"

    local all_containers=$(docker ps -a --format "{{.Names}}")
    if [ -z "$all_containers" ]; then
        echo -e "${GREEN}系統中沒有任何容器！${RESET}"
        return
    fi

    local container_list=()
    local index=1

    echo "以下是所有容器："
    while IFS= read -r name; do
        container_list+=("$name")
        echo "$index） $name"
        index=$((index + 1))
    done <<< "$all_containers"

    echo
    read -p "請輸入要修改的容器編號（僅單選）: " choice

    if ! [[ "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -lt 1 ] || [ "$choice" -ge "$index" ]; then
        echo -e "${RED}無效編號${RESET}"
        return
    fi

    local container_name="${container_list[$((choice-1))]}"

    echo
    echo "請選擇新的重啟策略："
    echo "1）no              - 不重啟"
    echo "2）always          - 永遠重啟"
    echo "3）on-failure      - 錯誤時重啟"
    echo "4）unless-stopped  - 意外關閉會重啟"

    read -p "請輸入選項（1-4）: " restart_choice

    case "$restart_choice" in
        1) restart_mode="no" ;;
        2) restart_mode="always" ;;
        3) restart_mode="on-failure" ;;
        4) restart_mode="unless-stopped" ;;
        *) echo -e "${RED} 無效選擇${RESET}"; return ;;
    esac

    echo "正在更新 $container_name 的重啟策略為 $restart_mode..."
    docker update --restart=$restart_mode "$container_name"

    if [[ $? -eq 0 ]]; then
      echo -e "${GREEN} 容器 $container_name 重啟策略已修改為 $restart_mode${RESET}"
    else
      echo -e "${RED} 修改失敗${RESET}"
    fi
}

update_docker_container() {
    local container_name="$1"

    if ! docker inspect "$container_name" &>/dev/null; then
        echo -e "${RED}容器 $container_name 不存在，無法更新。${RESET}"
        return 1
    fi

    echo -e "${CYAN}正在分析 $container_name 參數...${RESET}"

    local image=$(docker inspect -f '{{.Config.Image}}' "$container_name")
    local old_image_id=$(docker inspect -f '{{.Image}}' "$container_name")

    echo -e "${CYAN}正在拉取鏡像 $image ...${RESET}"
    pull_output=$(docker pull "$image" 2>&1)
    pull_status=$?

    if [[ $pull_status -ne 0 ]]; then
        echo -e "${RED}拉取鏡像失敗：$pull_output${RESET}"
        sleep 1
        return 1
    fi

    if echo "$pull_output" | grep -qi "up to date"; then
        echo -e "${GREEN}$image 已是最新版本，無需更新容器。${RESET}"
        sleep 1
        return 0
    fi

    if echo "$pull_output" | grep -qi "Downloaded newer image"; then
        echo -e "${CYAN}已下載新版 $image，開始更新容器...${RESET}"
    fi

    declare -A seen_ports
    port_args=""

    while IFS= read -r line; do
      container_port=$(echo "$line" | awk '{print $1}' | cut -d'/' -f1)
      if [[ -n "${seen_ports[$container_port]}" ]]; then continue; fi
      seen_ports[$container_port]=1
      host_port=$(echo "$line" | awk '{print $NF}' | cut -d':' -f2)
      if [[ -n "$host_port" && -n "$container_port" ]]; then
        port_args="$port_args -p ${host_port}:${container_port}"
      fi
    done < <(docker port "$container_name")

    local volumes=$(docker inspect -f '{{range .Mounts}}-v {{.Source}}:{{.Destination}} {{end}}' "$container_name")
    local envs=$(docker inspect -f '{{range $index, $value := .Config.Env}}-e {{$value}} {{end}}' "$container_name")

    local restart=$(docker inspect -f '{{.HostConfig.RestartPolicy.Name}}' "$container_name")
    local restart_arg=""
    if [[ "$restart" != "no" && -n "$restart" ]]; then
        restart_arg="--restart=$restart"
    fi

    # network
    local network=$(docker inspect -f '{{range $k, $v := .NetworkSettings.Networks}}{{println $k}}{{end}}' "$container_name" | head -n1)
    local network_arg=""
    if [[ -n "$network" ]]; then
        network_arg="--network=$network"
    fi

    # extra hosts
    local extra_hosts=$(docker inspect -f '{{range .HostConfig.ExtraHosts}}--add-host={{.}} {{end}}' "$container_name")

    # user
    local user=$(docker inspect -f '{{.Config.User}}' "$container_name")
    local user_arg=""
    if [[ -n "$user" ]]; then
        user_arg="--user=$user"
    fi

    docker stop "$container_name"
    docker rm "$container_name"

    docker run -d --name "$container_name" \
      $restart_arg $network_arg $port_args $volumes $envs $extra_hosts $user_arg \
      "$image"
    echo -e "${GREEN}$container_name 已更新並重新啟動。${RESET}"
    local new_image_id=$(docker inspect -f '{{.Image}}' "$container_name")
    if [[ "$old_image_id" != "$new_image_id" ]]; then
      docker rmi "$old_image_id" 2>/dev/null || true
    fi
}
uninstall_docker_app(){
  local app_name="$1"
  echo -e "${YELLOW}即將移除容器 $app_name${RESET}"
  case $app_name in
  tailscale)
    case $system in
    1)
      tailscale logout
      apt-get remove tailscale -y
      ;;
    2)
      tailscale logout
      yum remove -y tailscale
      ;;
    esac
    rm -rf /var/lib/tailscale/tailscaled.State
    echo -e "已移除$app_name。${RESET}"
    sleep 1
    return 0
    ;;
  esac
  docker stop "$app_name"
  docker rm "$app_name"
  case $app_name in
  Aria2Ng)
    docker stop aria2
    docker rm aria2
    rm -rf /srv/docker/aria2
    ;;
  nextcloud)
    if command -v mysql >/dev/null 2>&1; then
      check_dba
      dba mysql del nextcloud
    fi
    ;;
  esac
  echo -e "已移除容器 $app_name。${RESET}"
  read -p "是否移除該容器存放資料夾?(Y/n)" confrim
  confrim=${confrim,,}
  if [[ $confrim == y || "$confrim" == "" ]]; then
    rm -rf /srv/docker/$app_name
  else
    echo "取消修改。"
  fi
  docker system prune -a -f
}

menu_docker_app(){
  while true; do
    clear
    echo " Docker 推薦容器"
    echo "------------------------"
    echo -e "${YELLOW}系統管理與監控${RESET}"
    echo "1. Portainer    （容器管理面板）"
    echo "2. Uptime Kuma （網站監控工具）"
    echo "3. Beszel（高性能機器監控工具）"
    echo "4. Adminer （輕量級數據庫管理工具）"
    echo -e "${YELLOW}隱私保護${RESET}"
      echo "5. Bitwarden    （密碼管理器）"
    echo -e "${YELLOW}雲端儲存與下載${RESET}"
    echo "6. OpenList     （Alist 開源版）"
    echo "7. Cloudreve    （支援離線下載）"
    echo "8. Aria2NG      （自動搭配 Aria2）"
    echo -e "9. Nextcloud （自架雲端硬碟）${YELLOW}【低配伺服器慎用】${RESET}"
    echo -e "${YELLOW}網路與穿透${RESET}"
    echo "10. ZeroTier     （虛擬 VPN 網路）"
    echo "11. Cloudflare tunnel （內網穿透）"
    echo "12. tailscale （虛擬VPN網路）【推薦】"
    echo
    echo "0. 退出"
    echo -en "\033[1;33m請選擇操作 [0-9]: \033[0m"
    read -r choice
    case $choice in
    1)
      manage_docker_app portainer
      ;;
    2)
      manage_docker_app uptime-kuma
      ;;
    3)
      manage_docker_app beszel
      ;;
    4)
      manage_docker_app adminer
      ;;
    5)
      manage_docker_app bitwarden
      ;;
    6)
      manage_docker_app openlist
      ;;
    7)
      manage_docker_app cloudreve
      ;;
    8)
      manage_docker_app Aria2Ng
      ;;
    9)
      manage_docker_app nextcloud
      ;;
    10)
      manage_docker_app zerotier
      ;;
    11)
      manage_docker_app cloudflared
      ;;
    12)
      manage_docker_app tailscale
      ;;
    0)
      break
      ;;
    *)
      echo "無效選擇"
      ;;
    esac
  done
}

toggle_docker_ipv6() {
  local daemon="/etc/docker/daemon.json"
  
  # 2. 確保 daemon.json 存在且是有效的 JSON
  if [ ! -f "$daemon" ]; then
    mkdir -p /etc/docker
    echo '{}' > "$daemon"
    echo "已建立空的 $daemon 文件。"
  elif ! jq empty "$daemon" &>/dev/null; then
    echo '{}' > "$daemon"
  fi

  # 3. 偵測當前狀態並執行相反操作
  # 我們使用 jq 來精確判斷 boolean 值，比 grep 更可靠
  if jq -e '.ipv6 == true' "$daemon" &>/dev/null; then
    # --- 當前已啟用 -> 執行禁用操作 ---
    echo "偵測到 Docker IPv6 已啟用，現在將其禁用..."
    
    # 備份並使用 jq 刪除 ipv6 和 fixed-cidr-v6 鍵
    cp "$daemon" "$daemon.bak_$(date +%s)"
    local tmp=$(mktemp)
    jq 'del(.ipv6, ."fixed-cidr-v6")' "$daemon" > "$tmp" && mv "$tmp" "$daemon"
    
    echo -e "${GREEN}成功從 $daemon 移除 IPv6 相關設定。${RESET}"

  else
    # --- 當前已禁用 -> 執行啟用操作 ---
    echo "偵測到 Docker IPv6 已禁用，現在將其啟用..."

    # 備份並使用 jq 添加 ipv6 和 fixed-cidr-v6 鍵
    cp "$daemon" "$daemon.bak_$(date +%s)"
    local tmp=$(mktemp)
    jq '. + {"ipv6": true, "fixed-cidr-v6": "2001:db8:1::/64"}' "$daemon" > "$tmp" && mv "$tmp" "$daemon"

    echo -e "${GREEN}成功在 $daemon 中啟用 IPv6。${RESET}"
    echo "注意：已同時設定預設的 \"fixed-cidr-v6\"，您可稍後手動修改。"
  fi

  # 4. 重啟 Docker 服務
  echo ""
  echo "正在重啟 Docker 服務以套用變更..."
  if service docker restart; then
    echo -e "${GREEN}Docker 服務已成功重啟。${RESET}"
  else
    echo -e "${RED}Docker 服務重啟失敗，請使用 'journalctl -u docker.service' 查看詳細日誌。${RESET}"
  fi
}


update_script() {
  local download_url="https://gitlab.com/gebu8f/sh/-/raw/main/docker/docker_mgr.sh"
  local temp_path="/tmp/docker_mgr.sh"
  local current_script="/usr/local/bin/d"
  local current_path="$0"

  echo "正在檢查更新..."
  wget -q "$download_url" -O "$temp_path"
  if [ $? -ne 0 ]; then
    echo -e "${RED} 無法下載最新版本，請檢查網路連線。${RESET}"
    return
  fi

  # 比較檔案差異
  if [ -f "$current_script" ]; then
    if diff "$current_script" "$temp_path" >/dev/null; then
      echo -e "${GREEN} 腳本已是最新版本，無需更新。${RESET}"
      rm -f "$temp_path"
      return
    fi
    echo " 檢測到新版本，正在更新..."
    cp "$temp_path" "$current_script" && chmod +x "$current_script"
    if [ $? -eq 0 ]; then
      echo -e "${GREEN} 更新成功！將自動重新啟動腳本以套用變更...${RESET}"
      sleep 1
      exec "$current_script"
    else
      echo -e "${RED} 更新失敗，請確認權限。${RESET}"
    fi
  else
    # 非 /usr/local/bin 執行時 fallback 為當前檔案路徑
    if diff "$current_path" "$temp_path" >/dev/null; then
      echo -e "${GREEN} 腳本已是最新版本，無需更新。${RESET}"
      rm -f "$temp_path"
      return
    fi
    echo " 檢測到新版本，正在更新..."
    cp "$temp_path" "$current_path" && chmod +x "$current_path"
    if [ $? -eq 0 ]; then
      echo -e "${GREEN} 更新成功！將自動重新啟動腳本以套用變更...${RESET}"
      sleep 1
      exec "$current_path"
    else
      echo -e "${RED} 更新失敗，請確認權限。${RESET}"
    fi
  fi

  rm -f "$temp_path"
}

show_menu(){
  echo -e "${CYAN}-------------------${RESET}"
  echo -e "${YELLOW}Docker 管理選單${RESET}"
  echo ""
  echo -e "${GREEN}1. 啟動容器     ${GREEN}2.${RESET} 刪除容器"
  echo ""
  echo -e "${GREEN}3.${RESET} 停止容器"
  echo ""
  echo -e "${GREEN}4.${RESET} 重啟容器     ${GREEN}5.${RESET} 修改容器重啟策略"
  echo ""
  echo -e "${GREEN}6.${RESET} Docker 網路管理    ${GREEN}7.${RESET} Docker 詳細佔用管理"
  echo ""
  echo -e "${GREEN}8.${RESET} 查看 Docker 存儲卷   ${GREEN}9.${RESET} 清除未使用的容器或網路"
  echo ""
  echo -e "${GREEN}10.${RESET} 推薦容器            ${GREEN}11.${RESET} Docker 容器日誌讀取"
  echo ""
  echo -e "${GREEN}12.${RESET} 調試 Docker 容器    ${GREEN}13.${RESET} Docker 換源工具 "
  echo ""
  echo -e "${GREEN}14.${RESET} 編輯daemon.json     ${GREEN}15.${RESET} 開啟/關閉ipv6"
  echo ""
  echo -e "${BLUE}r.${RESET} 解除安裝docker"
  echo ""
  echo -e "${BLUE}u.${RESET} 更新腳本             ${RED}0.${RESET} 離開"
  echo -e "${CYAN}-------------------${RESET}"
  echo -e "${GRAY}[←/→] 翻頁  [數字] 選擇選單${RESET}"
  echo -en "${YELLOW}請選擇操作 [1-15/ u r 0]: ${RESET}"
}

get_input_or_nav() {
  local input_buffer=""
    
  stty -echo 

  while true; do
    read -rsn1 key # 讀取一個字元
    if [[ "$key" == $'\e' ]]; then
      read -rsn2 -t 0.01 key_rest
      if [[ "$key_rest" == "[C" ]]; then
        stty echo
        echo "NAV_NEXT" # 這是給變數抓的結果
        return
      elif [[ "$key_rest" == "[D" ]]; then
        stty echo
        echo "NAV_PREV" # 這是給變數抓的結果
        return
      fi
        
      # 2. 處理 Enter 鍵
      elif [[ "$key" == "" ]]; then 
        stty echo
        echo "" >&2         # [關鍵修改] 換行顯示給眼睛看 (>&2)
        echo "$input_buffer" # 這是給變數抓的結果 (stdout)
        return
      # 3. 處理 Backspace (刪除鍵)
      elif [[ "$key" == $'\x7f' || "$key" == $'\b' ]]; then
        if [ ${#input_buffer} -gt 0 ]; then
          input_buffer="${input_buffer::-1}"
          echo -ne "\b \b" >&2 # [關鍵修改] 視覺刪除給眼睛看 (>&2)
        fi
      else
        input_buffer+="$key"
        echo -ne "$key" >&2 # [關鍵修改] 打字顯示給眼睛看 (>&2)
      fi
  done
  stty echo
}
case "$1" in
  --version|-V)
    echo "docker管理器版本 $version"
    exit 0
    ;;
esac

check_system
check_app
install_docker_and_compose

trap 'stty echo; exit' INT TERM

while true; do
  stty echo
  clear
  show_docker_containers "$CURRENT_PAGE"
  show_menu
  
  choice=$(get_input_or_nav)
  
  if [[ "$choice" == "NAV_NEXT" ]]; then
      if [ "$CURRENT_PAGE" -lt "$TOTAL_PAGES" ]; then CURRENT_PAGE=$((CURRENT_PAGE + 1)); fi
      continue
  elif [[ "$choice" == "NAV_PREV" ]]; then
      if [ "$CURRENT_PAGE" -gt 1 ]; then CURRENT_PAGE=$((CURRENT_PAGE - 1)); fi
      continue
  fi

  case $choice in 
  1)
    start_docker_container
    read -p "操作完成，請按任意鍵繼續..." -n1 
    ;;
  2)
    delete_docker_containers
    read -p "操作完成，請按任意鍵繼續..." -n1 
    ;;
  3)
    stop_docker_container
    read -p "操作完成，請按任意鍵繼續..." -n1 
    ;;
  4)
    restart_docker_container
    read -p "操作完成，請按任意鍵繼續..." -n1 
    ;;
  5)
    update_restart_policy
    read -p "操作完成，請按任意鍵繼續..." -n1 
    ;;
  6)
    docker_network_manager
    read -p "操作完成，請按任意鍵繼續..." -n1 
    ;;
  7)
    docker_resource_manager
    read -p "操作完成，請按任意鍵繼續..." -n1 
    ;;
  8)
    docker_volume_manager
    read -p "操作完成，請按任意鍵繼續..." -n1 
    ;;
  9)
    docker image prune -a -f
    docker network prune -f
    docker volume prune -f
    docker builder prune -f
    read -p "操作完成，請按任意鍵繼續..." -n1 
    ;;
  10)
    menu_docker_app
    read -p "�