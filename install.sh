#!/bin/bash
check_wget(){
  if ! command -v wget >/dev/null 2>&1; then
    if command -v apt >/dev/null 2>&1; then
      apt install wget -y
    elif command -v yum >/dev/null 2>&1; then
      yum install -y wget
    elif command -v apk >/dev/null 2>&1; then
      apk add wget
    fi
  fi
}
check_wget

install_path="/usr/local/bin/docker_mgr"
run_cmd="docker_mgr"

echo "正在下載腳本..."
wget -qO "$install_path" https://gitlab.com/gebu8f/sh/-/raw/main/docker/docker_mgr.sh || {
  echo "下載失敗，請檢查網址或網路狀態。"
  exit 1
}

chmod +x "$install_path"
echo
echo "腳本已成功安裝！"
echo "請輸入 '$run_cmd' 啟動面板。"

read -p "按任意鍵立即啟動..." -n1
echo
"$run_cmd"