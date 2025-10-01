#!/usr/bin/env bash

#====================================================
# xray版本大于1.8.0
#====================================================

export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
stty erase ^?

cd "$(
  cd "$(dirname "$0")" || exit
  pwd
)" || exit

# 字体颜色配置
Green="\033[32m"
Red="\033[31m"
Yellow="\033[33m"
Blue="\033[36m"
Font="\033[0m"
GreenBG="\033[42;37m"
RedBG="\033[41;37m"
OK="${Green}[OK]${Font}"
ERROR="${Red}[ERROR]${Font}"

# 变量
shell_version="0.0.1"
github_branch="test"
xray_conf_dir="/usr/local/etc/xray"
website_dir="/www/xray_web/"
xray_access_log="/var/log/xray/access.log"
xray_error_log="/var/log/xray/error.log"
cert_dir="/usr/local/etc/xray"
domain_tmp_dir="/usr/local/etc/xray"
cert_group="nobody"
random_num=$((RANDOM % 12 + 4))

function print_ok() {
  echo -e "${OK} ${Blue} $1 ${Font}"
}

function print_error() {
  echo -e "${ERROR} ${RedBG} $1 ${Font}"
}

function is_root() {
  if [[ 0 == "$UID" ]]; then
    print_ok "当前用户是 root 用户，开始安装流程"
  else
    print_error "当前用户不是 root 用户，请切换到 root 用户后重新执行脚本"
    exit 1
  fi
}

judge() {
  if [[ 0 -eq $? ]]; then
    print_ok "$1 完成"
    sleep 1
  else
    print_error "$1 失败"
    exit 1
  fi
}

function system_check() {
  source '/etc/os-release'

  # 关闭各类防火墙
  systemctl stop firewalld
  systemctl disable firewalld
  systemctl stop nftables
  systemctl disable nftables
  systemctl stop ufw
  systemctl disable ufw
}

function dependency_install() {
  ${INS} lsof tar
  judge "安装 lsof tar"

  ${INS} unzip
  judge "安装 unzip"

  ${INS} curl
  judge "安装 curl"

  ${INS} systemd
  judge "安装/升级 systemd"

  if [[ "${ID}" == "centos" ]]; then
    ${INS} pcre pcre-devel zlib-devel epel-release openssl openssl-devel
  elif [[ "${ID}" == "ol" ]]; then
    ${INS} pcre pcre-devel zlib-devel openssl openssl-devel
    yum-config-manager --enable ol7_developer_EPEL >/dev/null 2>&1
    yum-config-manager --enable ol8_developer_EPEL >/dev/null 2>&1
  else
    ${INS} libpcre3 libpcre3-dev zlib1g-dev openssl libssl-dev
  fi

  ${INS} jq

  if ! command -v jq; then
    wget -P /usr/bin https://raw.githubusercontent.com/susudos/xray_reality_onekey/${github_branch}/binary/jq && chmod +x /usr/bin/jq
    judge "安装 jq"
  fi

  # 防止部分系统xray的默认bin目录缺失
  mkdir /usr/local/bin >/dev/null 2>&1
}

function basic_optimization() {
  sed -i '/^\*\ *soft\ *nofile\ *[[:digit:]]*/d' /etc/security/limits.conf
  sed -i '/^\*\ *hard\ *nofile\ *[[:digit:]]*/d' /etc/security/limits.conf
  echo '* soft nofile 65536' >>/etc/security/limits.conf
  echo '* hard nofile 65536' >>/etc/security/limits.conf

  if [[ "${ID}" == "centos" || "${ID}" == "ol" ]]; then
    sed -i 's/^SELINUX=.*/SELINUX=disabled/' /etc/selinux/config
    setenforce 0
  fi
}

function port_exist_check() {
  if [[ 0 -eq $(lsof -i:"$1" | grep -i -c "listen") ]]; then
    print_ok "$1 端口未被占用"
    sleep 1
  else
    print_error "检测到 $1 端口被占用，以下为 $1 端口占用信息"
    lsof -i:"$1"
    print_error "5s 后将尝试自动 kill 占用进程"
    sleep 5
    lsof -i:"$1" | awk '{print $2}' | grep -v "PID" | xargs kill -9
    print_ok "kill 完成"
    sleep 1
  fi
}

function update_sh() {
  ol_version=$(curl -L -s https://raw.githubusercontent.com/susudos/xray_reality_onekey/${github_branch}/install_reality.sh | grep "shell_version=" | head -1 | awk -F '=|"' '{print $3}')
  if [[ "$shell_version" != "$(echo -e "$shell_version\n$ol_version" | sort -rV | head -1)" ]]; then
    print_ok "存在新版本，是否更新 [Y/N]?"
    read -r update_confirm
    case $update_confirm in
    [yY][eE][sS] | [yY])
      wget -N --no-check-certificate https://raw.githubusercontent.com/susudos/xray_reality_onekey/${github_branch}/install_reality.sh
      print_ok "更新完成"
      print_ok "您可以通过 bash $0 执行本程序"
      exit 0
      ;;
    *) ;;
    esac
  else
    print_ok "当前版本为最新版本"
    print_ok "您可以通过 bash $0 执行本程序"
  fi
}

function xray_tmp_config_file_check_and_use() {
  if [[ -s ${xray_conf_dir}/config_temp.json ]]; then
    mv -f ${xray_conf_dir}/config_temp.json ${xray_conf_dir}/reality_config.json
  else
    print_error "xray 配置文件修改异常"
  fi
}

modify_privateKey() {
  # 确保 KEY 存在
  [[ -s "${xray_conf_dir}/KEY" ]] || { print_error "未找到 ${xray_conf_dir}/KEY"; exit 1; }

  # 兼容多种写法：PrivateKey: / Private key:（大小写、空格、回车）
  local PRIVATE_KEY
  PRIVATE_KEY=$(
    awk -F': *' '
      BEGIN{IGNORECASE=1}
      /^[[:space:]]*Private[[:space:]]*Key[[:space:]]*:/ {gsub(/\r/,""); print $2; exit}
      /^[[:space:]]*PrivateKey[[:space:]]*:/          {gsub(/\r/,""); print $2; exit}
    ' "${xray_conf_dir}/KEY" | sed "s/[^A-Za-z0-9_-]//g"
  )

  if [[ -z "${PRIVATE_KEY}" ]]; then
    print_error "未能从 KEY 中解析出 PrivateKey（请检查 ${xray_conf_dir}/KEY 格式）"
    exit 1
  fi

  # 写入模板配置
  jq --arg pk "$PRIVATE_KEY" \
     '.inbounds[0].streamSettings.realitySettings.privateKey = $pk' \
     "${xray_conf_dir}/reality_config.json" > "${xray_conf_dir}/config_temp.json"

  if [[ -s "${xray_conf_dir}/config_temp.json" ]]; then
    mv -f "${xray_conf_dir}/config_temp.json" "${xray_conf_dir}/reality_config.json"
    print_ok "Xray TCP privateKey 修改完成"
  else
    print_error "私钥写入后临时配置为空，放弃覆盖"
    exit 1
  fi
}

function modify_shortIds() {
  newShortIds=$(xray uuid | awk -F"-" '{print $NF}')
  jq --arg newShortIds "$newShortIds" '.inbounds[0].streamSettings.realitySettings.shortIds[0] = $newShortIds' /usr/local/etc/xray/reality_config.json > /usr/local/etc/xray/config_temp.json
  xray_tmp_config_file_check_and_use
  judge "Xray TCP shortIds 修改"
}

function modify_UUID() {
  read -rp "请输入新的 UUID（留空则自动生成）:" UUID
  if [[ -z "$UUID" ]]; then
    UUID=$(xray uuid)
  fi
  jq --arg newId "$UUID" '.inbounds[0].settings.clients[0].id = $newId' /usr/local/etc/xray/reality_config.json > /usr/local/etc/xray/config_temp.json
  xray_tmp_config_file_check_and_use
  judge "Xray TCP UUID 修改"
}

function modify_port() {
  read -rp "请输入端口号(默认：25025)：" PORT
  [ -z "$PORT" ] && PORT="25025"
  if [[ $PORT -le 0 ]] || [[ $PORT -gt 65535 ]]; then
    print_error "请输入 0-65535 之间的值"
    exit 1
  fi
  port_exist_check $PORT

  jq --argjson newPort "$PORT" '.inbounds[0].port = $newPort' /usr/local/etc/xray/reality_config.json > /usr/local/etc/xray/config_temp.json
  xray_tmp_config_file_check_and_use
  judge "Xray 端口 修改"
}

function configure_xray() {
  cd /usr/local/etc/xray && rm -f reality_config.json && wget -O reality_config.json https://raw.githubusercontent.com/susudos/xray_reality_onekey/${github_branch}/config/reality_config.json  
  modify_UUID
  modify_port
  modify_shortIds
  modify_privateKey
}

function xray_install() {
  print_ok "安装 Xray"
  bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install -u root
  echo "$(xray x25519)" >/usr/local/etc/xray/KEY

  PRIVATE_KEY=$(grep 'Private key:' /usr/local/etc/xray/KEY | cut -d ' ' -f 3)
  PUBLIC_KEY=$(grep 'Public key:' /usr/local/etc/xray/KEY | cut -d ' ' -f 3)
  
  judge "Xray 安装"
}

function xray_uninstall() {
  curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh | bash -s -- remove --purge
  rm -rf /usr/local/etc/xray
  print_ok "卸载完成"
  exit 0
}

function restart_all() {
  systemctl stop xray && systemctl start xray 
  judge "Xray 启动"
}

function vless_reality_information() {
  echo -e "${Red} Xray 配置信息 ${Font}"  
  local_ipv4=$(curl -s4m8 http://ip.gs)
  cat /usr/local/etc/xray/KEY
  echo
  jq --arg address "$local_ipv4" '.inbounds[0] | {address: $address, port, "id": .settings.clients[0].id, serverNames: .streamSettings.realitySettings.serverNames, privateKey: .streamSettings.realitySettings.privateKey, shortIds: .streamSettings.realitySettings.shortIds}' /usr/local/etc/xray/reality_config.json

  print_ok "-------------------------------------------------"
  echo

  PUBLIC_KEY=$(grep 'Public key:' /usr/local/etc/xray/KEY | cut -d ' ' -f 3)
  config_info=$(jq --arg address "$local_ipv4" --arg PUBLIC_KEY "$PUBLIC_KEY" '.inbounds[0] | {address: $address, port, id: .settings.clients[0].id, serverNames: .streamSettings.realitySettings.serverNames, privateKey: $PUBLIC_KEY, shortIds: .streamSettings.realitySettings.shortIds}' /usr/local/etc/xray/reality_config.json)

  vless_url="vless://$(echo "$config_info" | jq -r '.id')@$(echo "$config_info" | jq -r '.address'):$(echo "$config_info" | jq -r '.port')?encryption=none&flow=xtls-rprx-vision&security=reality&sni=$(echo "$config_info" | jq -r '.serverNames[1]')&fp=chrome&pbk=$(echo "$config_info" | jq -r '.privateKey')&sid=$(echo "$config_info" | jq -r '.shortIds[0]')&spx=%2F&type=tcp&headerType=none#VLESS_TCP_REALITY"

  echo "$vless_url"
  echo
}

function basic_information() {
  print_ok "VLESS+TCP+REALITY 安装成功"
  vless_reality_information
}

function show_access_log() {
  [ -f ${xray_access_log} ] && tail -f ${xray_access_log} || echo -e "${RedBG}log 文件不存在${Font}"
}

function show_error_log() {
  [ -f ${xray_error_log} ] && tail -f ${xray_error_log} || echo -e "${RedBG}log 文件不存在${Font}"
}

function bbr_boost_sh() {
  [ -f "tcp.sh" ] && rm -rf ./tcp.sh
  wget -N --no-check-certificate "https://raw.githubusercontent.com/ylx2016/Linux-NetSpeed/master/tcp.sh" && chmod +x tcp.sh && ./tcp.sh
}

function install_xray() {
  is_root
  port_exist_check 25025
  xray_install
  configure_xray
  restart_all
  basic_information
}

function configure_xray_service_dir() {
    # 定义要使用的配置目录
    local CONFIG_DIR="/usr/local/etc/xray/"

    # 定义服务文件路径
    local SERVICE_FILE="/etc/systemd/system/xray.service"

    # 停止并禁用 xray 服务
    echo "停止 xray 服务..."
    sudo systemctl stop xray || { echo "停止 xray 服务失败。"; exit 1; }
    sudo systemctl disable xray || { echo "禁用 xray 服务失败。"; exit 1; }

    # 使用 sed 修改 ExecStart 行，将其更改为使用 -confdir 参数
    echo "修改 xray.service 配置为文件夹路径..."
    sudo sed -i "s|^ExecStart=.*|ExecStart=/usr/local/bin/xray run -confdir $CONFIG_DIR|g" "$SERVICE_FILE" || { echo "修改 ExecStart 失败。"; exit 1; }

    # 重新加载 systemd 守护进程
    sudo systemctl daemon-reload || { echo "重新加载 systemd 守护进程失败。"; exit 1; }

    # 启用并启动 xray 服务
    echo "启用并启动 xray 服务..."
    sudo systemctl enable xray || { echo "启用 xray 服务失败。"; exit 1; }
    sudo systemctl start xray || { echo "启动 xray 服务失败。"; exit 1; }

    echo "xray.service 已成功配置为从目录 $CONFIG_DIR 加载配置文件。"
}

function menu() {
  update_sh
  echo -e "\t Xray 安装管理脚本 ${Red}[${shell_version}]${Font}"

  echo -e "当前已安装版本：${shell_mode}"
  echo -e "—————————————— 安装向导 ——————————————"""
  echo -e "${Green}0.${Font}  升级 脚本"
  echo -e "${Green}1.${Font}  安装 Xray (VLESS + TCP + REALITY)"
  echo -e "—————————————— 配置变更 ——————————————"
  echo -e "${Green}11.${Font} 变更 UUID"
  echo -e "${Green}12.${Font} 变更 连接端口"
  echo -e "—————————————— 查看信息 ——————————————"
  echo -e "${Green}21.${Font} 查看 实时访问日志"
  echo -e "${Green}22.${Font} 查看 实时错误日志"
  echo -e "${Green}23.${Font} 查看 Xray 配置链接"
  echo -e "${Green}24.${Font} 修改配置为文件夹路径"
  echo -e "—————————————— 其他选项 ——————————————"
  echo -e "${Green}31.${Font} 安装 4 合 1 BBR、锐速安装脚本"
  echo -e "${Green}32.${Font} 更新 Xray-core"
  echo -e "${Green}33.${Font} 卸载 Xray"
  echo -e "${Green}40.${Font} 退出"
  read -rp "请输入数字：" menu_num
  case $menu_num in
  0)
    update_sh
    ;;
  1)
    install_xray
    configure_xray_service_dir
    ;;
  11)
    modify_UUID
    restart_all
    ;;
  12)
    modify_port
    restart_all
    ;;
  21)
    tail -f $xray_access_log
    ;;
  22)
    tail -f $xray_error_log
    ;;
  23)
    if [[ -f $xray_conf_dir/reality_config.json ]]; then
      basic_information
    else
      print_error "xray 配置文件不存在"
    fi
    ;;
  24)
    configure_xray_service_dir
    ;;
  31)
    bbr_boost_sh
    ;;
  32)
    bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" - install
    restart_all
    ;;
  33)
    source '/etc/os-release'
    xray_uninstall
    ;;
  40)
    exit 0
    ;;
  *)
    print_error "请输入正确的数字"
    ;;
  esac
}

menu "$@"
