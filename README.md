# Docker 管理器

一個針對 Linux 系統的 Bash Shell 腳本，幫助你更輕鬆管理 Docker 容器、網路、存儲卷、資源限制及常見操作。

---

## ✨ 功能特色

✅ **容器管理**
- 顯示容器清單（名稱、鏡像、硬碟空間、網路、重啟策略、狀態、端口）
- 啟動、停止、刪除、重啟容器
- 熱修改容器的 CPU / 記憶體限制
- 讀取容器日誌

✅ **網路管理**
- 查看容器網路詳情（容器名、網路名稱、IP、Gateway）
- 建立 / 刪除 Docker 網路
- 將容器加入或移出指定網路
- 批次遷移網路內所有容器

✅ **存儲卷管理**
- 查看所有存儲卷以及對應的容器和主機路徑
- 新增 / 刪除存儲卷

✅ **自動化安裝**
- 一鍵安裝 Docker 與 Docker Compose
- 檢測並跳過已安裝項目

✅ **通用介面**
- 支援編號操作，適合懶人快速選擇

---

## 📦 系統需求

- Linux 系統 (Debian / Ubuntu / CentOS / Alpine)
- Docker (若未安裝，腳本可自動安裝)

---

## 🚀 安裝方式
```
bash <(curl -sL https://raw.githubusercontent.com/gebu8f8/docker_sh/refs/heads/main/install.sh)
```
備註：本README是由ai自動生成，我有改一些不太好的地方
