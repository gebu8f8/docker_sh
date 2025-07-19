#!/bin/bash

# 定義顏色
GREEN="\033[1;32m"
BLUE="\033[1;34m"
YELLOW="\033[1;33m"
CYAN="\033[1;36m"
RED="\033[1;31m"
BOLD_CYAN="\033[1;36;1m"
GRAY='\033[0;90m'
RESET="\033[0m"

#版本
version="2.0.1"

if [ "$(id -u)" -ne 0 ]; then
  echo "此腳本需要root權限運行" 
  if command -v sudo >/dev/null 2>&1; then
    exec sudo "$0" "$@"
  else
    echo "無sudo指令"
  fi
fi

#檢查系統版本
check_system(){
  if command -v apt >/dev/null 2>&1; then
    system=1
  elif command -v yum >/dev/null 2>&1; then
    system=2
    if grep -q -Ei "release 7|release 8" /etc/redhat-release; then
      echo -e "${RED}⚠️ 不支援 CentOS 7 或 CentOS 8，請升級至 9 系列 (Rocky/Alma/CentOS Stream)${RESET}"
      exit 1
    fi
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

delete_docker_containers() {
    echo "🔍 正在讀取所有容器..."

    local all_containers=$(docker ps -a --format "{{.ID}}|{{.Names}}|{{.Status}}|{{.Image}}")

    if [ -z "$all_containers" ]; then
        echo "✅ 系統沒有任何容器！"
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

    echo
    echo "請選擇刪除方式："
    echo "1）編號選擇"
    echo "2）手動輸入容器名稱或 ID（可空白隔開多個）"
    read -p "請輸入選項（1或2）: " mode

    local selected_ids=()

    if [ "$mode" == "1" ]; then
        read -p "請輸入要刪除的容器編號（可空白隔開多個）: " input_indexes

        for i in $input_indexes; do
            if ! [[ "$i" =~ ^[0-9]+$ ]]; then
                echo "❌ 無效編號：$i"
                continue
            fi
            if [ "$i" -ge 1 ] && [ "$i" -lt "$index" ]; then
                IFS='|' read -r id name status image <<< "${containers_list[$((i-1))]}"
                selected_ids+=("$id|$name|$status|$image")
            else
                echo "❌ 編號 $i 不存在！"
            fi
        done

    elif [ "$mode" == "2" ]; then
        read -p "請輸入要刪除的容器名稱或 ID（可空白隔開多個）: " input_names

        for keyword in $input_names; do
            matched=$(docker ps -a --filter "id=$keyword" --format "{{.ID}}|{{.Names}}|{{.Status}}|{{.Image}}")
            if [ -z "$matched" ]; then
                matched=$(docker ps -a --filter "name=$keyword" --format "{{.ID}}|{{.Names}}|{{.Status}}|{{.Image}}")
            fi
            if [ -n "$matched" ]; then
                selected_ids+=("$matched")
            else
                echo "❌ 找不到容器：$keyword"
            fi
        done
    else
        echo "❌ 輸入錯誤，操作中止。"
        return
    fi

    if [ ${#selected_ids[@]} -eq 0 ]; then
        echo "⚠️  沒有選擇任何有效容器，操作中止。"
        return
    fi

    for info in "${selected_ids[@]}"; do
        IFS='|' read -r id name status image <<< "$info"

        echo "👉 正在處理容器：$name ($id)"

        # 若容器正在運行，先停止
        if [[ "$status" =~ ^Up ]]; then
            echo "🔧 容器正在運行，先停止..."
            docker stop "$id"
        fi

        # 刪除容器
        docker rm "$id"
        if [[ $? -eq 0 ]]; then
            echo "✅ 容器 $name 已刪除"

            # 詢問是否刪除鏡像
            read -p "是否同時刪除鏡像 $image？ (y/n) " delete_image
            if [[ "$delete_image" =~ ^[Yy]$ ]]; then
                docker rmi "$image"
                if [[ $? -eq 0 ]]; then
                    echo "✅ 鏡像 $image 已刪除"
                else
                    echo "⚠️  鏡像 $image 刪除失敗或已被其他容器使用"
                fi
            fi
        else
            echo "❌ 容器 $name 刪除失敗"
        fi
        echo
    done

    echo "✅ 操作完成"
}

docker_network_manager() {
    echo
    echo -e "${CYAN}當前容器網路資訊：${RESET}"

    # 先取得所有容器
    local containers=$(docker ps -q)

    if [ -z "$containers" ]; then
        echo "⚠️  沒有正在運行的容器。"
    else
        # 收集資料
        local data=()
        for id in $containers; do
            local name=$(docker inspect -f '{{.Name}}' "$id" | sed 's|/||')
            local networks=$(docker inspect -f '{{range $k, $v := .NetworkSettings.Networks}}{{printf "%s;%s;%s\n" $k $v.IPAddress $v.Gateway}}{{end}}' "$id")

            while IFS=';' read -r net ip gw; do
                data+=("$name|$net|$ip|$gw")
            done <<< "$networks"
        done

        # 印出表格
        printf "%-20s %-20s %-16s %-16s\n" "容器名" "網路" "IP地址" "網關"
        printf "%s\n" "-------------------------------------------------------------------------------------------"
        for row in "${data[@]}"; do
            IFS='|' read -r name net ip gw <<< "$row"
            printf "%-20s %-20s %-16s %-16s\n" "$name" "$net" "$ip" "$gw"
        done
    fi

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
            echo "🔧 新增 Docker 網路"
            read -p "請輸入網路名稱：" netname
            read -p "請輸入 Subnet (例如 172.50.0.0/24，留空自動分配)：" subnet
            read -p "請輸入 Gateway (例如 172.50.0.1，留空自動分配)：" gateway

            cmd="docker network create"
            if [ -n "$subnet" ]; then
                cmd="$cmd --subnet $subnet"
            fi
            if [ -n "$gateway" ]; then
                cmd="$cmd --gateway $gateway"
            fi
            cmd="$cmd $netname"

            echo "執行：$cmd"
            eval "$cmd"

            echo "✅ 已建立網路 $netname"
            ;;
        2)
            echo "🔧 刪除 Docker 網路"

            # 列出所有網路
            mapfile -t network_list < <(docker network ls --format '{{.Name}}')
            
            if [ ${#network_list[@]} -eq 0 ]; then
                echo "⚠️  尚未建立任何網路。"
                return 0
            fi

            for i in "${!network_list[@]}"; do
                printf "%3s） %s\n" $((i+1)) "${network_list[$i]}"
            done

            read -p "請輸入欲刪除的網路編號：" nindex
            netname="${network_list[$((nindex-1))]}"

            if [ -z "$netname" ]; then
                echo "❌ 無效的網路編號。"
                return 1
            fi

            docker network rm "$netname"
            if [ $? -eq 0 ]; then
                echo "✅ 已刪除網路 $netname"
            else
                echo "❌ 刪除網路失敗，請檢查是否仍有容器連接該網路。"
            fi
            ;;
        3)
            echo "🔧 遷移網路內所有容器"

            # 列出所有網路
            mapfile -t network_list < <(docker network ls --format '{{.Name}}')

            if [ ${#network_list[@]} -eq 0 ]; then
                echo "⚠️  尚未建立任何網路。"
                return 0
            fi

            for i in "${!network_list[@]}"; do
                printf "%3s） %s\n" $((i+1)) "${network_list[$i]}"
            done

            read -p "請輸入欲遷移的網路編號：" oindex
            oldnet="${network_list[$((oindex-1))]}"

            if [ -z "$oldnet" ]; then
                echo "❌ 無效的網路編號。"
                return 1
            fi

            read -p "請輸入新網路編號：" nindex
            newnet="${network_list[$((nindex-1))]}"

            if [ -z "$newnet" ]; then
                echo "❌ 無效的新網路編號。"
                return 1
            fi

            if [[ "$oldnet" == "$newnet" ]]; then
                echo "⚠️  新舊網路相同，無需遷移。"
                return 1
            fi

            # 列出舊網路內的所有容器
            containers=$(docker network inspect "$oldnet" -f '{{range .Containers}}{{.Name}} {{end}}')

            if [ -z "$containers" ]; then
                echo "⚠️  網路 $oldnet 內沒有任何容器。"
                return 0
            fi

            for c in $containers; do
                echo "➡️ 正在將容器 $c 從 $oldnet 移至 $newnet"
                docker network disconnect "$oldnet" "$c"
                docker network connect "$newnet" "$c"
            done

            echo "✅ 所有容器已遷移至 $newnet"
            ;;
        4)
            echo "🔧 加入容器至網路"
            
            # 顯示容器列表
            mapfile -t container_list < <(docker ps --format '{{.Names}}')
            for i in "${!container_list[@]}"; do
                printf "%3s） %s\n" $((i+1)) "${container_list[$i]}"
            done

            read -p "請輸入容器編號：" cindex
            cname="${container_list[$((cindex-1))]}"

            if [ -z "$cname" ]; then
                echo "❌ 無效的容器編號。"
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
                echo "❌ 無效的網路編號。"
                return 1
            fi

            # 檢查容器是否已在該網路
            is_connected=$(docker inspect -f "{{json .NetworkSettings.Networks}}" "$cname" | grep "\"$netname\"" || true)
            if [ -n "$is_connected" ]; then
                echo "⚠️  容器 $cname 已經在網路 $netname 中，無需加入。"
            else
                docker network connect "$netname" "$cname"
                if [ $? -eq 0 ]; then
                    echo "✅ 容器 $cname 已成功加入網路 $netname"
                else
                    echo "❌ 加入網路失敗，請檢查容器狀態或網路模式。"
                fi
            fi
            ;;
        5)
            echo "🔧 從網路中移除容器"
            
            # 顯示容器列表
            mapfile -t container_list < <(docker ps --format '{{.Names}}')
            for i in "${!container_list[@]}"; do
                printf "%3s） %s\n" $((i+1)) "${container_list[$i]}"
            done

            read -p "請輸入容器編號：" cindex
            cname="${container_list[$((cindex-1))]}"

            if [ -z "$cname" ]; then
                echo "❌ 無效的容器編號。"
                return 1
            fi

            # 顯示此容器的網路
            echo "🔍 正在查詢容器 $cname 的網路..."
            mapfile -t attached_networks < <(docker inspect -f '{{range $k, $_ := .NetworkSettings.Networks}}{{println $k}}{{end}}' "$cname")

            if [ "${#attached_networks[@]}" -eq 0 ]; then
                echo "⚠️  該容器未連接任何自訂網路。"
                return 1
            fi

            for i in "${!attached_networks[@]}"; do
                printf "%3s） %s\n" $((i+1)) "${attached_networks[$i]}"
            done

            read -p "請輸入要離開的網路編號：" nindex
            netname="${attached_networks[$((nindex-1))]}"

            if [ -z "$netname" ]; then
                echo "❌ 無效的網路編號。"
                return 1
            fi

            docker network disconnect "$netname" "$cname"
            if [ $? -eq 0 ]; then
                echo "✅ 容器 $cname 已成功離開網路 $netname"
            else
                echo "❌ 離開網路失敗，請確認容器是否正在使用該網路。"
            fi
            ;;
        0)
            echo "已返回"
            ;;
        *)
            echo "❌ 無效的選擇"
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
        echo "⚠️  沒有任何容器存在。"
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
        echo "❌ 無效的容器編號。"
        return 1
    fi

    echo
    read -p "是否持續監聽最新日誌？(y/n)：" follow
    follow=${follow,,}

    if [[ "$follow" == "y" || "$follow" == "yes" ]]; then
        echo -e "${YELLOW}📡 持續監聽 $cname 日誌中（按 Ctrl+C 結束）...${RESET}"
        docker logs -f "$cname"
    else
        read -p "請輸入要顯示最後幾行日誌（預設 100）：" line_count
        line_count=${line_count:-100}
        echo -e "${YELLOW}📜 顯示容器 $cname 的最後 $line_count 行日誌：${RESET}"
        echo "-----------------------------------------------"
        docker logs --tail "$line_count" "$cname"
    fi
}


docker_resource_manager() {
    while true; do
        echo -e "${CYAN}🔍 正在讀取容器資源使用狀態...${RESET}"

        local all_containers=$(docker ps -a --format "{{.Names}}|{{.ID}}")

        if [ -z "$all_containers" ]; then
            echo -e "${GREEN}✅ 沒有任何容器！${RESET}"
            return
        fi

        # 查詢 docker stats
        local stats_data=$(docker stats --no-stream --format "{{.Name}}|{{.CPUPerc}}|{{.MemUsage}}")

        local container_info=()
        local index=1

        echo
        printf "${BOLD_CYAN}%-4s %-20s %-20s %-25s %-10s${RESET}\n" "編號" "容器名" "CPU (使用/限制)" "記憶體 (使用/限制)" "硬碟"
        echo -e "${YELLOW}------------------------------------------------------------------------------------------------${RESET}"

        while IFS='|' read -r name id; do
            # 預設值
            cpu_used="N/A"
            cpu_limit="無限制"
            mem_used="N/A"
            mem_limit="無限制"

            # CPU / MEM 限制
            local cpus=$(docker inspect -f '{{.HostConfig.NanoCpus}}' "$id")
            local mem=$(docker inspect -f '{{.HostConfig.Memory}}' "$id")

            if [ "$cpus" -eq 0 ] 2>/dev/null; then
                cpu_limit="無限制"
            else
                cpu_limit=$(awk -v nano="$cpus" 'BEGIN {printf "%.2f cores", nano/1000000000}')
            fi

            if [ "$mem" -eq 0 ] 2>/dev/null; then
                mem_limit="無限制"
            else
                mem_limit=$(awk -v mem="$mem" 'BEGIN {
                    if (mem >= 1073741824) {
                        printf "%.2fGB", mem/1073741824
                    } else {
                        printf "%.2fMB", mem/1048576
                    }
                }')
            fi

            # 查 docker stats 裡對應資料
            local stat_line=$(echo "$stats_data" | grep "^$name|")
            if [ -n "$stat_line" ]; then
                IFS='|' read -r s_name s_cpu s_mem <<< "$stat_line"

                # CPU 使用
                cpu_used="$s_cpu"
                
                # MEM 使用
                # s_mem 格式例如 "128MiB / 512MiB"
                mem_used_part=$(echo "$s_mem" | awk -F'/' '{print $1}' | xargs)
                if [ -n "$mem_used_part" ]; then
                    mem_used="$mem_used_part"
                fi
            fi

            # 硬碟佔用
            local disk=$(docker ps -s --filter id="$id" --format "{{.Size}}" | awk '{print $1}')
            disk="${disk:-0B}"

            container_info+=("$id|$name")

            printf "${GREEN}%-4s${RESET} %-20s %-20s %-25s %-10s\n" \
                "$index" "$name" "$cpu_used / $cpu_limit" "$mem_used / $mem_limit" "$disk"

            index=$((index + 1))
        done <<< "$all_containers"

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
                    echo -e "${RED}❌ 無效編號${RESET}"
                    continue
                fi
                IFS='|' read -r id name <<< "${container_info[$((num-1))]}"
                read -p "請輸入新的 CPU 配額（例如 0.5 表示 0.5 cores；輸入 0 表示無限制）: " cpu_limit

                if [[ "$cpu_limit" == "0" ]]; then
                    docker update --cpus=0 "$id"
                else
                    docker update --cpus="$cpu_limit" "$id"
                fi

                if [[ $? -eq 0 ]]; then
                    echo -e "${GREEN}✅ 容器 $name CPU 限制已更新${RESET}"
                else
                    echo -e "${RED}❌ 更新失敗${RESET}"
                fi
                ;;
            2)
                read -p "請輸入欲修改 記憶體 限制的容器編號: " num
                if ! [[ "$num" =~ ^[0-9]+$ ]] || [ "$num" -lt 1 ] || [ "$num" -ge "$index" ]; then
                    echo -e "${RED}❌ 無效編號${RESET}"
                    continue
                fi
                IFS='|' read -r id name <<< "${container_info[$((num-1))]}"
                read -p "請輸入新的記憶體限制（如 512m、1g，輸入 0 表示無限制）: " mem_limit

                if [[ "$mem_limit" == "0" ]]; then
                    docker update --memory="" "$id"
                else
                    docker update --memory="$mem_limit" "$id"
                fi

                if [[ $? -eq 0 ]]; then
                    echo -e "${GREEN}✅ 容器 $name 記憶體 限制已更新${RESET}"
                else
                    echo -e "${RED}❌ 更新失敗${RESET}"
                fi
                ;;
            0)
                echo -e "${CYAN}返回上一層${RESET}"
                break
                ;;
            *)
                echo -e "${RED}❌ 無效選項${RESET}"
                ;;
        esac

        echo
    done
}
docker_volume_manager() {
    echo
    echo -e "${CYAN}當前 Docker 存儲卷使用情況（顯示宿主機路徑）：${RESET}"

    # 準備表格資料
    local data=()
    local volumes=$(docker volume ls -q)

    if [ -z "$volumes" ]; then
        echo "⚠️  尚無任何存儲卷。"
    else
        for vol in $volumes; do
            # 查所有容器掛載此卷
            local containers=$(docker ps -a -q)
            local found=false
            for cid in $containers; do
                # 看容器是否有掛此 volume，並取出 Source（宿主機路徑）
                local mount=$(docker inspect -f '{{range .Mounts}}{{if eq .Name "'"$vol"'"}}{{.Source}}{{end}}{{end}}' "$cid")
                if [ -n "$mount" ]; then
                    local cname=$(docker inspect -f '{{.Name}}' "$cid" | sed 's|/||')
                    data+=("$cname|$vol|$mount")
                    found=true
                fi
            done
            # 若沒被任何容器掛載，也顯示出空列
            if [ "$found" = false ]; then
                data+=("（未掛載）|$vol|")
            fi
        done

        # 印出表頭
        local col1="容器名"
        local col2="存儲卷名"
        local col3="宿主機路徑"

        # 計算補空格（每個中文字寬度視為2）
        printf "%-20s %-25s %-40s\n" \
            "$col1$(printf '%*s' $((20 - ${#col1} * 2)) '')" \
            "$col2$(printf '%*s' $((25 - ${#col2} * 2)) '')" \
            "$col3$(printf '%*s' $((40 - ${#col3} * 2)) '')"

        printf "%s\n" "-------------------------------------------------------------------------------------------------------------"

        for row in "${data[@]}"; do
            IFS='|' read -r cname vol path <<< "$row"
            printf "%-20s %-25s %-40s\n" "$cname" "$vol" "${path:-""}"
        done
    fi

    echo
    echo "存儲卷管理功能："
    echo "1. 添加卷"
    echo "2. 刪除卷"
    echo "0. 返回"
    echo

    read -p "請選擇功能 [0-2]：" choice

    case "$choice" in
        1)
            echo "🔧 添加新存儲卷"
            read -p "請輸入存儲卷名稱：" volname
            docker volume create "$volname"
            echo "✅ 存儲卷 $volname 已建立。"
            ;;
        2)
            echo "🔧 刪除存儲卷"
            docker volume ls --format '{{.Name}}' | nl
            read -p "請輸入欲刪除的存儲卷名稱：" volname
            docker volume rm "$volname"
            echo "✅ 存儲卷 $volname 已刪除。"
            ;;
        0)
            echo "已返回"
            ;;
        *)
            echo "❌ 無效的選擇"
            ;;
    esac
}

debug_container() {
  echo -e "${YELLOW}===== Docker 調試容器 =====${RESET}"

  containers=($(docker ps --format '{{.ID}} {{.Names}}'))
  count=${#containers[@]}

  if [ "$count" -eq 0 ]; then
    echo -e "${RED}❌ 沒有正在運行的容器。${RESET}"
    return 1
  fi

  echo "請選擇要進入的容器："
  for ((i=0; i<count; i+=2)); do
    index=$((i/2+1))
    echo "  [$index] ${containers[i+1]} (${containers[i]})"
  done

  read -p "輸入編號：" choice

  if ! [[ "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -lt 1 ] || [ "$choice" -gt $((count/2)) ]; then
    echo -e "${RED}⚠️ 無效的編號。${RESET}"
    return 1
  fi

  cid="${containers[$(( (choice-1)*2 ))]}"
  cname="${containers[$(( (choice-1)*2 + 1 ))]}"

  echo -e "${CYAN}🔍 嘗試使用 bash 進入容器：$cname${RESET}"
  if docker exec "$cid" which bash >/dev/null 2>&1; then
    docker exec -it "$cid" bash
    return 0
  fi

  echo -e "${YELLOW}❗ bash 不存在，改用 sh 嘗試進入容器：$cname${RESET}"
  if docker exec "$cid" which sh >/dev/null 2>&1; then
    docker exec -it "$cid" sh
    return 0
  fi

  echo -e "${RED}❌ 無法進入容器 $cname：bash 和 sh 都無法使用。${RESET}"
  return 1
}


install_docker_app() {
  local app_name="$1"
  local ipv4=$(curl -s --connect-timeout 3 https://api4.ipify.org)
  local ipv6=$(curl -s -6 --connect-timeout 3 https://api6.ipify.org)
  Tips(){
    echo -e "${RED}⚠️ 這是唯一的顯示機會！${RESET}"
    echo -e "${CYAN}📛 密碼/令牌不會儲存、不會記錄、不會再次出現。${RESET}"
    echo
    echo -e "${GRAY}我從不記錄日誌，也不保存密碼。${RESET}"
    echo -e "${GRAY}本腳本不產生日誌檔、不會留下任何痕跡。${RESET}"
    echo -e "${GRAY}你看過一次，就沒第二次。真的丟了，我也沒轍。${RESET}"
  }
  ips(){
    local host_port=$1
    local proto=${2:-http}
    if [ $proto == https ]; then
      [ -n "$ipv4" ] && echo -e "  🌐 IPv4：${BLUE}https://${ipv4}:${host_port}${RESET}"
      [ -n "$ipv6" ] && echo -e "  🌐 IPv6：${BLUE}https://[${ipv6}]:${host_port}${RESET}"
      return 0
    fi
    [ -n "$ipv4" ] && echo -e "  🌐 IPv4：${BLUE}http://${ipv4}:${host_port}${RESET}"
    [ -n "$ipv6" ] && echo -e "  🌐 IPv6：${BLUE}http://[${ipv6}]:${host_port}${RESET}"
  }
  echo -e "${CYAN}🔧 安裝 $app_name${RESET}"
  local host_port
  while true; do
    read -p "請輸入欲綁定的主機端口 (留空將從 10000-65535 中隨機選擇一個未被佔用的端口): " custom_port

    if [ -z "$custom_port" ]; then
        echo "🔄 正在尋找可用的隨機端口..."
        while true; do
            host_port=$(shuf -i 10000-65535 -n 1)
            if ! ss -tln | grep -q ":$host_port "; then
                echo "✅ 找到可用端口: $host_port"
                  break
            fi
        done
        break
    else
        if [[ "$custom_port" =~ ^[0-9]+$ ]] && [ "$custom_port" -ge 1 ] && [ "$custom_port" -le 65535 ]; then
            if ss -tln | grep -q ":$custom_port "; then
                  echo -e "${RED}❌ 端口 $custom_port 已被佔用，請重新輸入。${RESET}"
            else
                host_port=$custom_port
                echo "✅ 端口 $host_port 可用。"
                break
            fi
        else
            echo -e "${RED}❌ 無效的端口號，請輸入 1-65535 之間的數字。${RESET}"
        fi
    fi
  done
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
      vaultwarden/server:latest
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
      portainer/portainer-ce:latest 
    read -p "是否需要反向代理？（Y/n）" confirm
    confirm=${confirm,,}
    if [[ "$confirm" == y || "$confirm" == "" ]]; then
      if ! command -v site >/dev/null 2>&1; then
        echo "您好，您尚未安裝站點管理器。"
        read -p "操作完成，請按任意鍵繼續" -n1
        return 1
      fi
      read -p "請輸入域名：" domain
      if site setup "$domain" proxy 127.0.0.1 https "$host_port"; then
        echo "訪問位置：https://$domain"
      else
        echo "訪問位置："
        ips $host_port https
        echo -e "${CYAN}已啟用 Portainer HTTPS 自簽連線（TLS 1.3 加密保護）${RESET}"
        echo -e "${YELLOW}⚠️ 首次連線可能跳出「不受信任憑證」提示，請選擇信任即可${RESET}"
        echo -e "${GRAY}📢 傳輸已經使用頂級加密協議（TLS 1.3），安全性與 Let's Encrypt 相同${RESET}"
      fi
    else
      echo "訪問位置："
      ips $host_port https
      echo -e "${CYAN}已啟用 Portainer HTTPS 自簽連線（TLS 1.3 加密保護）${RESET}"
      echo -e "${YELLOW}⚠️ 首次連線可能跳出「不受信任憑證」提示，請選擇信任即可${RESET}"
      echo -e "${GRAY}📢 傳輸已經使用頂級加密協議（TLS 1.3），安全性與 Let's Encrypt 相同${RESET}"
    fi
    read -p "操作完成，請按任意鍵繼續" -n1
    ;;
  uptime-kuma)
    mkdir -p /srv/docker/uptime-kuma
    docker run -d --restart=always -p $host_port:3001 -v /srv/docker/uptime-kuma:/app/data --name uptime-kuma louislam/uptime-kuma:latest
    read -p "是否需要反向代理？（Y/n）" confirm
    confirm=${confirm,,}
    if [[ "$confirm" == y || "$confirm" == "" ]]; then
      if ! command -v site >/dev/null 2>&1; then
        echo "您好，您尚未安裝站點管理器。"
        read -p "操作完成，請按任意鍵繼續" -n1
        return 1
      fi
      read -p "請輸入域名：" domain
      if site setup "$domain" proxy 127.0.0.1 https "$host_port"; then
        echo "===== uptime kuma資訊 ====="
        echo "訪問位置：https://$domain"
      else
        echo "===== uptime kuma資訊 ====="
        echo "訪問位置："
        ips $host_port
      fi
    else
      echo "===== uptime kuma資訊 ====="
      echo "訪問位置："
      ips $host_port
    fi
    read -p "操作完成，請按任意鍵繼續" -n1
    ;;
  openlist)
    mkdir /srv/docker/openlist
    docker run -d \
			--restart=always \
			-v /srv/docker/openlist:/opt/openlist/data \
			-p $host_port:5244 \
			-e PUID=0 \
			-e PGID=0 \
			-e UMASK=022 \
			--name="openlist" \
			openlistteam/openlist:latest-lite-aria2 
		echo "正在讀取密碼"
		for i in {1..10}; do
      local admin_pass=$(docker logs openlist 2>&1 | grep 'initial password is' | awk '{print $NF}')
      if [ -n "$admin_pass" ]; then
        break
      fi
      sleep 1
    done
		read -p "是否需要反向代理？（Y/n）" confirm
    confirm=${confirm,,}
    if [[ "$confirm" == y || "$confirm" == "" ]]; then
      if ! command -v site >/dev/null 2>&1; then
        echo "您好，您尚未安裝站點管理器。"
        read -p "操作完成，請按任意鍵繼續" -n1
        return 1
      fi
      read -p "請輸入域名：" domain
      if site setup $domain proxy 127.0.0.1 http $host_port; then
        echo "===== openlist資訊 ====="
        echo "訪問位置：https://$domain"
      else
        echo "===== openlist資訊 ====="
        echo "訪問位置："
        ips $host_port
      fi
    else
      echo "===== openlist資訊 ====="
      echo "訪問位置："
      ips $host_port
    fi
    echo -e "${GREEN}✅ 管理員資訊：${RESET}"
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
    read -p "是否需要反向代理？（Y/n）" confirm
    confirm=${confirm,,}
    if [[ "$confirm" == y || "$confirm" == "" ]]; then
      if ! command -v site >/dev/null 2>&1; then
        echo "您好，您尚未安裝站點管理器。"
        read -p "操作完成，請按任意鍵繼續" -n1
        return 1
      fi
      read -p "請輸入域名：" domain
      if site setup $domain proxy 127.0.0.1 http $host_port; then
        echo "===== cloudreve資訊 ====="
        echo "訪問位置：https://$domain"
      else
        echo "===== cloudreve資訊 ====="
        echo "訪問位置："
        ips $host_port
      fi
    else
      echo "===== cloudreve資訊 ====="
      echo "訪問位置："
      ips $host_port
    fi
    echo -e "${GREEN}✅ 管理員資訊：${RESET}"
    echo -e "${YELLOW}帳號密碼第一次註冊即可是管理員${RESET}"
    echo -e "${CYAN}Cloudreve 已內建 Aria2，無需另外部署。${RESET}"
    echo -e "  🔑 Token：${GREEN}空白即可，無需填入${RESET}"
    read -p "操作完成，請按任意鍵繼續" -n1
    ;;
  zerotier)
    docker run -d \
      --restart always \
      --name zerotier-one --device=/dev/net/tun \
      --net=host \
      --cap-add=NET_ADMIN \
      --cap-add=SYS_ADMIN \
      -v /var/lib/zerotier-one:/var/lib/zerotier-one \
      zyclonite/zerotier
    read -p "請輸入網路id：" zt_id
    docker exec zerotier-one zerotier-cli join $zt_id
    ;;
  Aria2Ng)
    mkdir -p /srv/downloads
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
    echo -e "${YELLOW}這邊就不給反代了，因為Aria2 RPC位置會自動變成https，就不相容於我們的aria2 是http的${RESET}" 
    echo "===== Aria2Ng資訊 ====="
    echo "訪問位置："
    ips $host_port
    echo "=====aria2填入 Aria2Ng資訊 =====" 
    local ip_6800=$(ips "6800")
    echo -e "${YELLOW}在 Aria2Ng 中填入如下格式：${RESET}"
    ips "6800"
    echo -e "${YELLOW}請選擇能從你 Aria2Ng 連線的 IP 地址！${RESET}"
    echo -e "Token: ${CYAN}$aria_rpc${RESET}"
    echo -e "${YELLOW}⚠ 如果瀏覽器無法連上 RPC，請檢查：${RESET}"
    echo "1. 是否開啟 6800 端口"
    echo "2. 是否被防火牆攔住"
    echo "3. Aria2Ng 中 RPC 協議需為 http，不支援 https"
    Tips
    echo -e "${GREEN}搞定就行，沒搞定就看上面說的再來找我，別直接怪我這腳本壞了 :)${RESET}"
    read -p "操作完成，請按任意鍵繼續" -n1
    ;;
  esac
  echo -e "${GREEN}✅ $app_name 已成功安裝！${RESET}"
}

install_docker_and_compose() {
    echo "🔍 正在檢查 Docker 是否已安裝..."
    if ! command -v docker &>/dev/null; then
        echo "🚀 安裝 Docker 中..."

        if [ "$system" -eq 1 ]; then
            curl -fsSL https://get.docker.com | sh
        elif [ "$system" -eq 2 ]; then
            curl -fsSL https://get.docker.com | sh
        elif [ "$system" -eq 3 ]; then
            apk add docker
        fi

        echo "✅ Docker 安裝完成"
    else
        echo "✅ 已安裝 Docker"
    fi

    # 檢查 docker-compose 或 docker compose 都不存在才安裝
    if ! command -v docker-compose &>/dev/null && ! docker compose version &>/dev/null; then
        echo "🚀 安裝 Docker Compose Plugin 中..."

        if [ "$system" -eq 1 ] || [ "$system" -eq 2 ]; then
            DOCKER_CONFIG=${DOCKER_CONFIG:-/usr/local/lib/docker}
            mkdir -p "$DOCKER_CONFIG/cli-plugins"
            curl -SL https://github.com/docker/compose/releases/download/v2.24.5/docker-compose-linux-$(uname -m) -o "$DOCKER_CONFIG/cli-plugins/docker-compose"
            chmod +x "$DOCKER_CONFIG/cli-plugins/docker-compose"
        elif [ "$system" -eq 3 ]; then
            apk add docker-cli-compose
        fi

        echo "✅ Docker Compose 安裝完成"
    fi


    if [ "$system" -eq 1 ] || [ "$system" -eq 2 ]; then
        # 檢查是否已 enable
        if ! systemctl is-enabled docker &>/dev/null; then
            systemctl enable docker
            echo "✅ 已設定 Docker 開機自啟"
        fi

        # 檢查是否正在運行
        if ! systemctl is-active docker &>/dev/null; then
            systemctl start docker
            echo "✅ 已啟動 Docker 服務"
        fi

    elif [ "$system" -eq 3 ]; then
        # Alpine
        if ! rc-update show | grep -q docker; then
            rc-update add docker default
            echo "✅ 已設定 Docker 開機自啟"
        fi

        if ! service docker status | grep -q running; then
            service docker start
            echo "✅ 已啟動 Docker 服務"
        fi
    fi

}
manage_docker_app() {
  clear
  local app_name="$1"
  local can_update="false"
  local app_desc=""
  local app_name2=""

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
    zerotier)
      app_name2=$app_name
      can_update="true"
      app_desc="ZeroTier 可建立虛擬 VPN 網路，支援 NAT 穿透無需開放埠口。"
      ;;
    Aria2Ng)
      app_name2=$app_name
      can_update="true"
      app_desc="Aria2Ng 是 Aria2 的圖形化網頁管理介面，輕量易用，並會自動部署內建的 Aria2 核心。"
      ;;
    *)
      echo -e "${RED}❌ 未知應用：$app_name${RESET}"
      return
      ;;
  esac

  local container_exists=$(docker ps -a --format '{{.Names}}' | grep -w "^$app_name$")

  echo -e "${BOLD_CYAN}🔧 管理 Docker 應用：$app_name2${RESET}"
  echo "-----------------------------"

  echo -e "${CYAN}▶ 狀態檢查：${RESET}"
  if [ -n "$container_exists" ]; then
    echo -e "${GREEN}✅ 已安裝${RESET}"
  else
    echo -e "${YELLOW}⚠️ 尚未安裝${RESET}"
  fi
  echo

  echo -e "${CYAN}▶ 應用介紹：${RESET}"
  echo -e "$app_desc"
  echo

  if [ -n "$container_exists" ]; then
    echo -e "${CYAN}▶ 訪問地址：${RESET}"
    local host_port=$(docker inspect -f '{{range $p, $conf := .NetworkSettings.Ports}}{{if $conf}}{{(index $conf 0).HostPort}}{{end}}{{end}}' "$app_name" 2>/dev/null)
    host_port="${host_port:-未知}"

    ipv4=$(curl -s --connect-timeout 3 https://api4.ipify.org)
    ipv6=$(curl -s -6 --connect-timeout 3 https://api6.ipify.org)
    
    if [ $app_name == portainer ]; then
      [ -n "$ipv4" ] && echo -e "  🌐 IPv4：${BLUE}https://${ipv4}:${host_port}${RESET}"
      [ -n "$ipv6" ] && echo -e "  🌐 IPv6：${BLUE}https://[${ipv6}]:${host_port}${RESET}"
    else
      [ -n "$ipv4" ] && echo -e "  🌐 IPv4：${BLUE}http://${ipv4}:${host_port}${RESET}"
      [ -n "$ipv6" ] && echo -e "  🌐 IPv6：${BLUE}http://[${ipv6}]:${host_port}${RESET}"
      echo
    fi
  fi

  echo -e "${CYAN}▶ 操作選單：${RESET}"
  if [ -z "$container_exists" ]; then
    echo "  1. 安裝"
  else
    [[ "$can_update" == "true" ]] && echo "  2. 更新"
    echo "  3. 移除"
  fi
  echo

  echo -ne "${YELLOW}請輸入欲執行的選項：${RESET}"
  read choice

  case "$choice" in
    1)
      if [ -n "$container_exists" ]; then
        echo -e "${RED}⚠️ 已安裝，無需重複安裝。${RESET}"
        return
      fi
      install_docker_app "$app_name"
      ;;
    2)
      if [[ "$can_update" != "true" ]]; then
        echo -e "${RED}❌ 此應用不支援更新操作。${RESET}"
        return
      fi
      if [ -z "$container_exists" ]; then
        echo -e "${RED}❌ 尚未安裝，無法更新。${RESET}"
        return
      fi
      update_docker_container "$app_name"
      ;;
    3)
      if [ -z "$container_exists" ]; then
        echo -e "${RED}❌ 尚未安裝，無法移除。${RESET}"
        return
      fi
      uninstall_docker_app "$app_name"
      ;;
    *)
      echo -e "${RED}❌ 無效的選項。${RESET}"
      ;;
  esac
}
restart_docker_container() {
    echo "🔍 正在讀取所有容器..."

    local all_containers=$(docker ps -a --format "{{.Names}}")
    if [ -z "$all_containers" ]; then
        echo "✅ 系統中沒有任何容器！"
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
        echo "❌ 沒有輸入任何編號"
        return
    fi

    local all_selected=false
    local selected_indexes=()

    for i in $input_indexes; do
        if ! [[ "$i" =~ ^[0-9]+$ ]]; then
            echo "❌ 無效輸入：$i"
            return
        fi

        if [ "$i" -eq "$index" ]; then
            all_selected=true
        elif [ "$i" -ge 1 ] && [ "$i" -lt "$index" ]; then
            selected_indexes+=("$i")
        else
            echo "❌ 編號 $i 不存在！"
            return
        fi
    done

    if $all_selected && [ ${#selected_indexes[@]} -gt 0 ]; then
        echo "❌ 無法同時選擇編號與 all，請分開操作。"
        return
    fi

    if $all_selected; then
        echo "🚀 正在重啟所有容器..."
        docker restart $(docker ps -a --format "{{.Names}}")
        echo "✅ 所有容器已重啟"
    else
        for idx in "${selected_indexes[@]}"; do
            local name="${container_list[$((idx-1))]}"
            echo "🚀 正在重啟容器：$name"
            docker restart "$name"
            if [[ $? -eq 0 ]]; then
                echo "✅ 容器 $name 已重啟"
            else
                echo "❌ 容器 $name 重啟失敗"
            fi
        done
    fi
}
show_docker_containers() {
    local containers=$(docker ps -a -q)
    if [ -z "$containers" ]; then
        echo "⚠️  沒有任何容器存在。"
        return
    fi

    local data=()

    for id in $containers; do
        local name=$(docker inspect -f '{{.Name}}' "$id" | sed 's|/||')
        local image=$(docker inspect -f '{{.Config.Image}}' "$id")
        local size=$(docker ps -s --filter id="$id" --format "{{.Size}}" | sed 's/ (.*)//')
        local networks=$(docker inspect -f '{{range $k, $v := .NetworkSettings.Networks}}{{printf "%s " $k}}{{end}}' "$id" | sed 's/ *$//')
        local restart=$(docker inspect -f '{{.HostConfig.RestartPolicy.Name}}' "$id")
        local status=$(docker inspect -f '{{.State.Status}}' "$id")

        # 翻譯容器狀態
        case "$status" in
            "running") status_zh="運行中" ;;
            "exited")  status_zh="已停止" ;;
            "paused")  status_zh="已暫停" ;;
            *)         status_zh="$status" ;;
        esac

        # 翻譯 Restart 策略
        case "$restart" in
            "no") restart_zh="不重啟" ;;
            "always") restart_zh="永遠重啟" ;;
            "on-failure") restart_zh="錯誤時重啟" ;;
            "unless-stopped") restart_zh="意外關閉會重啟" ;;
            *) restart_zh="未知" ;;
        esac

        # 正確取得 Port 映射
        local ports=""
        local raw_ports=$(docker port "$id")

        if [ -z "$raw_ports" ]; then
            ports="無對外埠口"
        else
            while IFS= read -r line; do
                local port_proto=$(echo "$line" | awk -F' ' '{print $1}')
                local mapping=$(echo "$line" | awk -F'-> ' '{print $2}')
                if [ -z "$mapping" ]; then
                    ports+="${port_proto}（容器內部） "
                else
                    ports+="${mapping} -> ${port_proto} "
                fi
            done <<< "$raw_ports"

            ports=$(echo "$ports" | sed 's/ *$//')
        fi

        data+=("$name|$image|$status_zh|$size|$ports|$networks|$restart_zh")
    done

    # 宣告表頭字串
    local col1="容器名"
    local col2="鏡像名"
    local col3="狀態"
    local col4="硬碟空間"
    local col5="埠口映射"
    local col6="網路"
    local col7="重啟策略"

    # 印出標題列
    printf "%-20s %-30s %-10s %-12s %-30s %-15s %-20s\n" \
        "$col1$(printf '%*s' $((20 - ${#col1} * 2)) '')" \
        "$col2$(printf '%*s' $((30 - ${#col2} * 2)) '')" \
        "$col3$(printf '%*s' $((10 - ${#col3} * 2)) '')" \
        "$col4$(printf '%*s' $((12 - ${#col4} * 2)) '')" \
        "$col5$(printf '%*s' $((30 - ${#col5} * 2)) '')" \
        "$col6$(printf '%*s' $((15 - ${#col6} * 2)) '')" \
        "$col7$(printf '%*s' $((20 - ${#col7} * 2)) '')"

    printf "%s\n" "--------------------------------------------------------------------------------------------------------------------------------------------"

    for row in "${data[@]}"; do
        IFS='|' read -r name image status size ports networks restart_zh <<< "$row"

        if [ ${#image} -gt 29 ]; then
            image="${image:0:27}..."
        fi

        if [ ${#ports} -gt 29 ]; then
            ports="${ports:0:27}..."
        fi

        printf "%-20s %-30s %-10s %-12s %-30s %-15s %-20s\n" \
            "$name" "$image" "$status" "$size" "$ports" "$networks" "$restart_zh"
    done
}

start_docker_container() {
    echo "🔍 正在檢查已停止的容器..."

    # 取得所有已停止容器名稱
    local stopped_containers=$(docker ps -a --filter "status=exited" --format "{{.Names}}")

    if [ -z "$stopped_containers" ]; then
        echo "✅ 沒有已停止的容器！"
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
        echo "❌ 未輸入任何選項，操作中止。"
        return
    fi

    # 判斷是否選到 all
    local all_selected=false
    local selected_indexes=()

    for i in $input_indexes; do
        if ! [[ "$i" =~ ^[0-9]+$ ]]; then
            echo "❌ 無效輸入：$i"
            return
        fi

        if [ "$i" -eq "$index" ]; then
            all_selected=true
        elif [ "$i" -ge 1 ] && [ "$i" -lt "$index" ]; then
            selected_indexes+=("$i")
        else
            echo "❌ 編號 $i 不存在！"
            return
        fi
    done

    # 判斷 all 是否單獨被選
    if $all_selected && [ ${#selected_indexes[@]} -gt 0 ]; then
        echo "❌ 無法同時選擇編號與 all，請分開操作。"
        return
    fi

    if $all_selected; then
        echo "🚀 正在啟動全部已停止的容器..."
        docker start $(docker ps -a --filter "status=exited" --format "{{.Names}}")
        echo "✅ 全部容器已啟動"
    elif [ ${#selected_indexes[@]} -gt 0 ]; then
        for idx in "${selected_indexes[@]}"; do
            local selected_container="${container_list[$((idx-1))]}"
            echo "🚀 正在啟動容器：$selected_container"
            docker start "$selected_container"
            if [[ $? -eq 0 ]]; then
                echo "✅ 容器 $selected_container 已啟動"
            else
                echo "❌ 容器 $selected_container 啟動失敗"
            fi
        done
    else
        echo "⚠️  沒有選擇任何容器，操作中止。"
    fi
}


stop_docker_container() {
    echo "🔍 正在檢查已啟動的容器..."

    local running_containers=$(docker ps --format "{{.Names}}")

    if [ -z "$running_containers" ]; then
        echo "✅ 沒有正在運行的容器！"
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
        echo "❌ 未輸入任何選項，操作中止。"
        return
    fi

    local all_selected=false
    local selected_indexes=()

    for i in $input_indexes; do
        if ! [[ "$i" =~ ^[0-9]+$ ]]; then
            echo "❌ 無效輸入：$i"
            return
        fi

        if [ "$i" -eq "$index" ]; then
            all_selected=true
        elif [ "$i" -ge 1 ] && [ "$i" -lt "$index" ]; then
            selected_indexes+=("$i")
        else
            echo "❌ 編號 $i 不存在！"
            return
        fi
    done

    # 不允許同時選 all + 編號
    if $all_selected && [ ${#selected_indexes[@]} -gt 0 ]; then
        echo "❌ 無法同時選擇編號與 all，請分開操作。"
        return
    fi

    if $all_selected; then
        echo "🚀 正在停止全部正在運行的容器..."
        docker stop $(docker ps --format "{{.Names}}")
        echo "✅ 全部容器已停止"
    elif [ ${#selected_indexes[@]} -gt 0 ]; then
        for idx in "${selected_indexes[@]}"; do
            local selected_container="${container_list[$((idx-1))]}"
            echo "🚀 正在停止容器：$selected_container"
            docker stop "$selected_container"
            if [[ $? -eq 0 ]]; then
                echo "✅ 容器 $selected_container 已停止"
            else
                echo "❌ 容器 $selected_container 停止失敗"
            fi
        done
    else
        echo "⚠️  沒有選擇任何容器，操作中止。"
    fi
}

update_restart_policy() {
    echo "🔧 熱修改容器重啟策略"

    local all_containers=$(docker ps -a --format "{{.Names}}")
    if [ -z "$all_containers" ]; then
        echo "✅ 系統中沒有任何容器！"
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
        echo "❌ 無效編號"
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
        *) echo "❌ 無效選擇"; return ;;
    esac

    echo "🔄 正在更新 $container_name 的重啟策略為 $restart_mode..."
    docker update --restart=$restart_mode "$container_name"

    if [[ $? -eq 0 ]]; then
        echo "✅ 容器 $container_name 重啟策略已修改為 $restart_mode"
    else
        echo "❌ 修改失敗"
    fi
}

update_docker_container() {
    local container_name="$1"

    # 檢查容器是否存在
    if ! docker inspect "$container_name" &>/dev/null; then
        echo -e "${RED}❌ 容器 $container_name 不存在，無法更新。${RESET}"
        return 1
    fi

    echo -e "${CYAN}🔍 正在分析 $container_name 參數...${RESET}"

    # 取得 image 名稱
    local old_image=$(docker inspect -f '{{.Config.Image}}' "$container_name")

    # 自動改 tag 為 latest
    local new_image=""
    if [[ "$old_image" == *":"* ]]; then
        new_image=$(echo "$old_image" | sed -E 's/:(.*)$/\:latest/')
    else
        new_image="${old_image}:latest"
    fi

    echo "原本 image：$old_image"
    echo "更新後 image：$new_image"

    # pull 最新版本
    docker pull "$new_image"

    # 提取 container 的啟動參數
    local ports=$(docker inspect -f '{{range .HostConfig.PortBindings}}{{println (index . 0).HostPort}}{{end}}' "$container_name")
    local port_args=""
    for p in $ports; do
        # 注意：這裡假設 container 對外都是對應 80 port，可視需要修改
        port_args="$port_args -p ${p}:80"
    done

    local volumes=$(docker inspect -f '{{range .Mounts}}-v {{.Source}}:{{.Destination}} {{end}}' "$container_name")

    local envs=$(docker inspect -f '{{range $index, $value := .Config.Env}}-e {{$value}} {{end}}' "$container_name")

    local restart=$(docker inspect -f '{{.HostConfig.RestartPolicy.Name}}' "$container_name")
    local restart_arg=""
    if [[ "$restart" != "no" && -n "$restart" ]]; then
        restart_arg="--restart=$restart"
    fi

    echo "提取到參數："
    echo "port_args: $port_args"
    echo "volumes: $volumes"
    echo "envs: $envs"
    echo "restart_arg: $restart_arg"

    # 停止並刪除原容器
    docker stop "$container_name"
    docker rm "$container_name"

    # 使用新 image 重建 container
    docker run -d --name "$container_name" $restart_arg $port_args $volumes $envs "$new_image"

    echo -e "${GREEN}✅ $container_name 已更新並重新啟動。${RESET}"
}
uninstall_docker_app(){
  local app_name="$1"
  echo -e "${YELLOW}⚠️ 即將移除容器 $app_name${RESET}"
  docker stop "$app_name"
  docker rm "$app_name"
  echo -e "${GREEN}✅ 已移除容器 $app_name。${RESET}"
  read -p "是否移除該容器存放資料夾?(Y/n)" confrim
  confrim=${confrim,,}
  if [[ $confrim == y || "$confirm" == "" ]]; then
    rm -rf /srv/docker/$app_name
  else
    echo "取消修改。"
  fi
  docker system prune -a -f
  case $app_name in
  bitwarden)
    read -p "請輸入您部署的bitwarden域名：" domain
    site del "$domain"
    ;;
  esac
}

menu_docker_app(){
    while true; do
      echo "🚀 Docker 推薦容器"
      echo "------------------------"
      echo -e "${YELLOW}🛠 系統管理與監控${RESET}"
      echo "  1. Portainer    （容器管理面板）"
      echo "  2. Uptime Kuma （網站監控工具）"
      echo -e "${YELLOW}🔐 隱私保護${RESET}"
      echo "  3. Bitwarden    （密碼管理器）"
      echo -e "${YELLOW}☁️ 雲端儲存與下載${RESET}"
      echo "  4. OpenList     （Alist 開源版）"
      echo "  5. Cloudreve    （支援離線下載）"
      echo "  6. Aria2NG      （自動搭配 Aria2）"
      echo -e "${YELLOW}🌐 網路與穿透${RESET}"
      echo "  7. ZeroTier     （虛擬 VPN 網路）"
      echo
      echo "  0. 退出"
      echo -n -e "\033[1;33m請選擇操作 [0-6]: \033[0m"
      read -r choice
      case $choice in
      1)
        manage_docker_app portainer
        ;;
      2)
        manage_docker_app uptime-kuma
        ;;
      3)
        manage_docker_app bitwarden
        ;;
      4)
        manage_docker_app openlist
        ;;
      5)
        manage_docker_app cloudreve
        ;;
      6)
        manage_docker_app Aria2Ng
        ;;
      7)
        manage_docker_app zerotier
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

update_script() {
  local download_url="https://raw.githubusercontent.com/gebu8f8/docker_sh/refs/heads/main/docker_mgr.sh"
  local temp_path="/tmp/docker_mgr.sh"
  local current_script="/usr/local/bin/docker_mgr"
  local current_path="$0"

  echo "🔍 正在檢查更新..."
  wget -q "$download_url" -O "$temp_path"
  if [ $? -ne 0 ]; then
    echo "❌ 無法下載最新版本，請檢查網路連線。"
    return
  fi

  # 比較檔案差異
  if [ -f "$current_script" ]; then
    if diff "$current_script" "$temp_path" >/dev/null; then
      echo "✅ 腳本已是最新版本，無需更新。"
      rm -f "$temp_path"
      return
    fi
    echo "📦 檢測到新版本，正在更新..."
    cp "$temp_path" "$current_script" && chmod +x "$current_script"
    if [ $? -eq 0 ]; then
      echo "✅ 更新成功！將自動重新啟動腳本以套用變更..."
      sleep 1
      exec "$current_script"
    else
      echo "❌ 更新失敗，請確認權限。"
    fi
  else
    # 非 /usr/local/bin 執行時 fallback 為當前檔案路徑
    if diff "$current_path" "$temp_path" >/dev/null; then
      echo "✅ 腳本已是最新版本，無需更新。"
      rm -f "$temp_path"
      return
    fi
    echo "📦 檢測到新版本，正在更新..."
    cp "$temp_path" "$current_path" && chmod +x "$current_path"
    if [ $? -eq 0 ]; then
      echo "✅ 更新成功！將自動重新啟動腳本以套用變更..."
      sleep 1
      exec "$current_path"
    else
      echo "❌ 更新失敗，請確認權限。"
    fi
  fi

  rm -f "$temp_path"
}

show_menu(){
  show_docker_containers
  echo -e "${CYAN}-------------------${RESET}"
  echo -e "${YELLOW}Docker 管理選單${RESET}"
  echo ""

  echo -e "${GREEN}1.${RESET} 啟動容器     ${GREEN}2.${RESET} 刪除容器"
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
  echo -e "${GREEN}12.${RESET} 調試 Docker 容器"
  echo ""
  echo -e "${BLUE}u.${RESET} 更新腳本             ${RED}0.${RESET} 離開"
  echo -e "${CYAN}-------------------${RESET}"
  echo -en "${YELLOW}請選擇操作 [1-12 / u 0]: ${RESET}"
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

while true; do
  clear
  show_menu
  read -r choice
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
    docker system prune -a -f
    read -p "操作完成，請按任意鍵繼續..." -n1 
    ;;
  10)
    menu_docker_app
    read -p "操作完成，請按任意鍵繼續..." -n1 
    ;;
  11)
    docker_show_logs
    read -p "操作完成，請按任意鍵繼續..." -n1 
    ;;
  12)
    debug_container
    read -p "操作完成，請按任意鍵繼續..." -n1 
    ;;
  0)
    echo "感謝使用。"
    exit 0
    ;;
  u)
    update_script
    ;;
  *)
    echo "無效的選擇"
    ;;
  esac
done
