#!/bin/bash

# ---
# 0. 系统检查：仅支持 Debian / Ubuntu
# ---
check_system() {
    if [ ! -f /etc/os-release ]; then
        echo "❌ 错误：无法检测操作系统（未找到 /etc/os-release）。"
        echo "本脚本仅支持 Debian 或 Ubuntu 系统。"
        exit 1
    fi

    . /etc/os-release

    case "$ID" in
        debian|ubuntu)
            echo "✅ 检测到系统: $PRETTY_NAME，继续执行。"
            ;;
        *)
            echo "❌ 错误：不支持的操作系统: $PRETTY_NAME ($ID)"
            echo "本脚本仅支持 Debian 或 Ubuntu 系统，请在支持的系统上运行。"
            exit 1
            ;;
    esac
}

# 全局变量记录初始 IPv4 状态
ORIGINAL_HAS_IPV4=false
ORIGINAL_HAS_IPV6=false

check_ipv4_status() {
    echo "---"
    echo "正在检测初始系统 IPv4 状态..."
    if curl -4 -s --connect-timeout 2 https://www.google.com >/dev/null 2>&1 || \
       curl -4 -s --connect-timeout 2 https://1.1.1.1 >/dev/null 2>&1; then
        echo "✅ 检测到系统已有原生 IPv4 出口。"
        ORIGINAL_HAS_IPV4=true
    else
        echo "⚠️ 未检测到系统原生 IPv4 出口。"
        ORIGINAL_HAS_IPV4=false
    fi
}

check_ipv6_status() {
    echo "---"
    echo "正在检测初始系统 IPv6 状态..."
    if curl -6 -s --connect-timeout 2 https://www.google.com >/dev/null 2>&1 || \
       curl -6 -s --connect-timeout 2 https://2606:4700:4700::1111 >/dev/null 2>&1; then
        echo "✅ 检测到系统已有原生 IPv6 出口。"
        ORIGINAL_HAS_IPV6=true
    else
        echo "⚠️ 未检测到系统原生 IPv6 出口。"
        ORIGINAL_HAS_IPV6=false
    fi
}

fq_dir="$HOME/gfw"
packages="ca-certificates curl dnsutils openssl wireguard certbot python3-certbot-dns-cloudflare jq cron nginx-full tmux qrencode vim less iptables-persistent"
cert_dir="$fq_dir/cf_cert"
domain_file="$cert_dir/domain.txt"
sing_box_dir="$fq_dir/sing-box"
sing_box_key_file="$sing_box_dir/sing-box.key"
cf_ini="$cert_dir/cf.ini"
cf_api_base="https://api.cloudflare.com/client/v4"
certbot_dns_propagation_seconds=120
cert_renew_timezone="Asia/Singapore"
cert_renew_hour=4
cert_renew_window_days=7
cert_renew_cron_file="/etc/cron.d/fq-cert-renew"
cert_renew_log="/var/log/fq-cert-renew.log"
fq_script_path="${BASH_SOURCE[0]}"
fq_script_dir=$(cd "$(dirname "$fq_script_path")" >/dev/null 2>&1 && pwd -P)
if [ -n "$fq_script_dir" ]; then
    fq_script_path="$fq_script_dir/$(basename "$fq_script_path")"
fi

get_state_value() {
    local key="$1"
    local file="$2"
    [ -f "$file" ] || return 0
    awk -F: -v key="$key" '$1 == key { value = substr($0, index($0, ":") + 1); sub(/^[[:space:]]+/, "", value); print value; exit }' "$file"
}

set_state_value() {
    local key="$1"
    local value="$2"
    local file="$3"
    local tmp_file

    mkdir -p "$(dirname "$file")"
    tmp_file=$(mktemp)
    if [ -f "$file" ]; then
        grep -v "^${key}:" "$file" > "$tmp_file" || true
    fi
    printf '%s:%s\n' "$key" "$value" >> "$tmp_file"
    mv "$tmp_file" "$file"
    chmod 600 "$file"
}

remove_state_keys() {
    local file="$1"
    local tmp_file
    shift

    [ -f "$file" ] || return 0
    [ "$#" -gt 0 ] || return 0

    tmp_file=$(mktemp)
    awk -F: -v keys="$*" '
        BEGIN {
            split(keys, key_list, " ")
            for (i in key_list) {
                drop[key_list[i]] = 1
            }
        }
        !($1 in drop)
    ' "$file" > "$tmp_file"
    mv "$tmp_file" "$file"
    chmod 600 "$file"
}

derive_root_domain() {
    local subdomain="$1"

    echo "$subdomain" | awk -F. '{if (NF>2) { if ($0 ~ /\.(com\.cn|net\.cn|org\.cn|gov\.cn|edu\.cn|ac\.cn|eu\.org|co\.uk|org\.uk|me\.uk)$/) {print $(NF-2)"."$(NF-1)"."$NF} else {print $(NF-1)"."$NF} } else {print $0}}'
}

log_cert_renew() {
    printf '[%s] %s\n' "$(TZ="$cert_renew_timezone" date '+%F %T %Z')" "$*"
}

get_cert_checksum() {
    local cert_path="$1"

    sudo sha256sum "$cert_path" 2>/dev/null | awk '{print $1}'
}

ensure_cron_service() {
    if command -v systemctl >/dev/null 2>&1; then
        if ! systemctl list-unit-files cron.service 2>/dev/null | grep -q '^cron\.service'; then
            echo "正在安装 cron..."
            sudo apt-get update
            sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y cron
        fi
        if ! sudo systemctl enable --now cron >/dev/null 2>&1; then
            echo "⚠️ cron 服务启动失败，请手动检查 systemctl status cron。"
            return 1
        fi
    elif command -v service >/dev/null 2>&1; then
        sudo service cron start >/dev/null 2>&1 || {
            echo "⚠️ cron 服务启动失败，请手动检查 service cron status。"
            return 1
        }
    fi
}

restart_cert_dependent_services() {
    local service=""
    local failed=false

    for service in nginx sing-box; do
        if sudo systemctl is-active --quiet "$service" 2>/dev/null; then
            log_cert_renew "证书已更新，正在重启 $service..."
            if sudo systemctl restart "$service"; then
                log_cert_renew "$service 重启成功。"
            else
                log_cert_renew "ERROR: $service 重启失败，请检查 systemctl status $service。"
                failed=true
            fi
        else
            log_cert_renew "$service 未处于运行状态，跳过重启。"
        fi
    done

    [ "$failed" = "false" ]
}

handle_successful_cert_update() {
    local domain="$1"
    local cert_checksum_before="$2"
    local cert_path="/etc/letsencrypt/live/$domain/fullchain.pem"
    local cert_checksum_after=""

    configure_cert_renewal_cron "$domain" || return 1

    cert_checksum_after=$(get_cert_checksum "$cert_path")
    if [ -n "$cert_checksum_after" ] && [ "$cert_checksum_after" != "$cert_checksum_before" ]; then
        echo "✅ 检测到证书文件已更新，检查是否需要重启 nginx 和 sing-box..."
        restart_cert_dependent_services || return 1
    else
        echo "✅ 证书文件未变化，无需重启 nginx 或 sing-box。"
    fi
}

configure_cert_renewal_cron() {
    local domain="$1"
    local tmp_file=""
    local escaped_script_path=""
    local escaped_domain=""

    if [ -z "$domain" ]; then
        echo "❌ 无法配置证书续期 crontab：域名为空。"
        return 1
    fi
    if [ ! -f "$fq_script_path" ]; then
        echo "❌ 无法配置证书续期 crontab：未找到脚本 $fq_script_path。"
        return 1
    fi

    ensure_cron_service || return 1
    sudo touch "$cert_renew_log"
    sudo chmod 640 "$cert_renew_log"

    printf -v escaped_script_path '%q' "$fq_script_path"
    printf -v escaped_domain '%q' "$domain"
    tmp_file=$(mktemp)
    cat > "$tmp_file" <<EOF
# FQ certificate renewal. Managed by $fq_script_path
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
TZ=$cert_renew_timezone
# Cron timezone support differs by implementation, so guard execution by Singapore hour.
0 * * * * root if [ "\$(TZ=$cert_renew_timezone date +\\%H)" = "$(printf '%02d' "$cert_renew_hour")" ]; then /bin/bash $escaped_script_path --renew-cert-if-needed $escaped_domain; fi >> $cert_renew_log 2>&1
EOF
    sudo install -m 644 "$tmp_file" "$cert_renew_cron_file"
    rm -f "$tmp_file"

    echo "✅ 已配置证书自动续期 crontab: $cert_renew_cron_file"
    echo "   执行时间: 每天 $cert_renew_timezone 04:00；脚本仅在证书剩余 <= ${cert_renew_window_days} 天时续期。"
    echo "   日志文件: $cert_renew_log"
}

renew_cert_if_needed() {
    local subdomain="$1"
    local domain=""
    local cert_path=""
    local cert_checksum_before=""
    local cert_checksum_after=""
    local expires_text=""
    local expires_epoch=""
    local now_epoch=""
    local days_left=""
    local should_renew=false
    local reason=""

    log_cert_renew "开始检查证书续期。"

    if [ -z "$subdomain" ] && [ -f "$domain_file" ]; then
        subdomain=$(head -n 1 "$domain_file")
    fi
    if [ -z "$subdomain" ]; then
        log_cert_renew "ERROR: 未找到子域名，无法判断需要续期的证书。"
        return 1
    fi

    domain=$(derive_root_domain "$subdomain")
    cert_path="/etc/letsencrypt/live/$domain/fullchain.pem"
    if ! sudo test -f "$cert_path"; then
        log_cert_renew "ERROR: 未找到证书文件 $cert_path。"
        return 1
    fi

    expires_text=$(sudo openssl x509 -in "$cert_path" -noout -enddate 2>/dev/null | sed 's/^notAfter=//')
    expires_epoch=$(date -d "$expires_text" +%s 2>/dev/null)
    now_epoch=$(date +%s)
    if [ -z "$expires_epoch" ]; then
        log_cert_renew "ERROR: 无法解析证书到期时间: $expires_text。"
        return 1
    fi

    days_left=$(( (expires_epoch - now_epoch + 86399) / 86400 ))
    log_cert_renew "证书: $domain；到期时间: $expires_text；剩余天数: $days_left。"

    if [ "$days_left" -le "$cert_renew_window_days" ]; then
        should_renew=true
        reason="证书剩余天数 <= ${cert_renew_window_days}"
    fi

    if [ "$should_renew" != "true" ]; then
        log_cert_renew "无需续期：证书剩余天数大于 ${cert_renew_window_days}。"
        return 0
    fi

    cert_checksum_before=$(get_cert_checksum "$cert_path")
    log_cert_renew "触发 certbot renew，原因：$reason。"
    if ! sudo env PYTHONWARNINGS=ignore::PendingDeprecationWarning certbot renew \
        --cert-name "$domain" \
        --non-interactive; then
        log_cert_renew "ERROR: certbot renew 执行失败。"
        return 1
    fi

    cert_checksum_after=$(get_cert_checksum "$cert_path")
    if [ -n "$cert_checksum_after" ] && [ "$cert_checksum_after" != "$cert_checksum_before" ]; then
        log_cert_renew "证书文件已更新。"
        restart_cert_dependent_services || return 1
    else
        log_cert_renew "certbot 执行完成，证书文件未变化，无需重启服务。"
    fi
}

prepare_sing_box_domains() {
    local subdomain="$1"
    local anytls_domain
    local hy2_domain
    local expected_anytls_domain
    local expected_hy2_domain

    if [ -z "$subdomain" ]; then
        echo "❌ 无法生成 sing-box 域名：子域名为空。"
        return 1
    fi

    expected_anytls_domain="a6-${subdomain}"
    expected_hy2_domain="h2-${subdomain}"
    anytls_domain=$(get_state_value "anytls_domain" "$sing_box_key_file")
    hy2_domain=$(get_state_value "hy2_domain" "$sing_box_key_file")

    if [ "$anytls_domain" != "$expected_anytls_domain" ]; then
        anytls_domain="$expected_anytls_domain"
        set_state_value "anytls_domain" "$anytls_domain" "$sing_box_key_file"
    fi
    if [ "$hy2_domain" != "$expected_hy2_domain" ]; then
        hy2_domain="$expected_hy2_domain"
        set_state_value "hy2_domain" "$hy2_domain" "$sing_box_key_file"
    fi
    set_state_value "subdomain" "$subdomain" "$sing_box_key_file"

    echo "AnyTLS 域名: $anytls_domain"
    echo "Hysteria2 域名: $hy2_domain"
}

get_cloudflare_token() {
    local cf_token=""

    mkdir -p "$cert_dir"
    if [ -f "$cf_ini" ]; then
        chmod 600 "$cf_ini"
        cf_token=$(sed -n 's/^[[:space:]]*dns_cloudflare_api_token[[:space:]]*=[[:space:]]*//p' "$cf_ini" | head -n 1)
    fi

    if [ -z "$cf_token" ]; then
        echo "Cloudflare Token 需要目标 Zone 的 Zone Read 和 DNS Edit 权限。" >&2
        read -r -s -p "请粘贴 Cloudflare API Token: " cf_token
        echo >&2
        if [ -z "$cf_token" ]; then
            echo "❌ Cloudflare API Token 不能为空。" >&2
            return 1
        fi
        printf 'dns_cloudflare_api_token = %s\n' "$cf_token" > "$cf_ini"
        chmod 600 "$cf_ini"
        echo "✅ API Token 已保存到 $cf_ini。" >&2
    else
        echo "✅ 从 $cf_ini 读取 Cloudflare API Token。" >&2
    fi

    printf '%s' "$cf_token"
}

cloudflare_api() {
    local method="$1"
    local endpoint="$2"
    local cf_token="$3"
    local payload="${4:-}"

    if [ -n "$payload" ]; then
        curl -sS --connect-timeout 10 --max-time 30 -X "$method" \
            -H "Authorization: Bearer $cf_token" \
            -H "Content-Type: application/json" \
            --data "$payload" \
            "$cf_api_base$endpoint"
    else
        curl -sS --connect-timeout 10 --max-time 30 -X "$method" \
            -H "Authorization: Bearer $cf_token" \
            -H "Content-Type: application/json" \
            "$cf_api_base$endpoint"
    fi
}

check_cloudflare_response() {
    local response="$1"
    local action="$2"

    if ! printf '%s' "$response" | jq -e '.success == true' >/dev/null 2>&1; then
        echo "❌ Cloudflare API 操作失败: $action"
        printf '%s' "$response" | jq -r '.errors[]? | "  [\(.code)] \(.message)"' 2>/dev/null
        return 1
    fi
}

upsert_cloudflare_dns_record() {
    local zone_id="$1"
    local record_type="$2"
    local record_name="$3"
    local record_content="$4"
    local cf_token="$5"
    local response=""
    local record_ids=""
    local record_id=""
    local payload=""
    local action=""
    local is_first=true

    response=$(cloudflare_api GET "/zones/$zone_id/dns_records?type=$record_type&name=$record_name&match=all" "$cf_token") || return 1
    check_cloudflare_response "$response" "查询 $record_type $record_name" || return 1
    record_ids=$(printf '%s' "$response" | jq -r '.result[]?.id')
    payload=$(jq -nc \
        --arg type "$record_type" \
        --arg name "$record_name" \
        --arg content "$record_content" \
        '{type:$type,name:$name,content:$content,ttl:1,proxied:false}')

    if [ -n "$record_ids" ]; then
        while IFS= read -r record_id; do
            [ -n "$record_id" ] || continue
            if [ "$is_first" = "true" ]; then
                response=$(cloudflare_api PUT "/zones/$zone_id/dns_records/$record_id" "$cf_token" "$payload") || return 1
                check_cloudflare_response "$response" "更新 $record_type $record_name" || return 1
                is_first=false
            else
                response=$(cloudflare_api DELETE "/zones/$zone_id/dns_records/$record_id" "$cf_token") || return 1
                check_cloudflare_response "$response" "删除重复的 $record_type $record_name" || return 1
            fi
        done <<< "$record_ids"
        action="更新"
    else
        response=$(cloudflare_api POST "/zones/$zone_id/dns_records" "$cf_token" "$payload") || return 1
        check_cloudflare_response "$response" "创建 $record_type $record_name" || return 1
        action="创建"
    fi

    echo "✅ 已${action} $record_type $record_name -> ${record_content}（仅 DNS）"
}

delete_cloudflare_dns_records() {
    local zone_id="$1"
    local record_type="$2"
    local record_name="$3"
    local cf_token="$4"
    local response=""
    local record_ids=""
    local record_id=""

    response=$(cloudflare_api GET "/zones/$zone_id/dns_records?type=$record_type&name=$record_name&match=all" "$cf_token") || return 1
    check_cloudflare_response "$response" "查询 $record_type $record_name" || return 1
    record_ids=$(printf '%s' "$response" | jq -r '.result[]?.id')
    [ -n "$record_ids" ] || return 0

    while IFS= read -r record_id; do
        [ -n "$record_id" ] || continue
        response=$(cloudflare_api DELETE "/zones/$zone_id/dns_records/$record_id" "$cf_token") || return 1
        check_cloudflare_response "$response" "删除 $record_type $record_name" || return 1
    done <<< "$record_ids"
    echo "✅ 已删除无对应公网地址的 $record_type $record_name"
}

configure_cloudflare_dns() {
    local domain="$1"
    local subdomain="$2"
    local ip_v4="$3"
    local ip_v6="$4"
    local cf_token=""
    local response=""
    local zone_id=""
    local anytls_domain=""
    local hy2_domain=""
    local record_name=""

    if [ -z "$ip_v4" ] && [ -z "$ip_v6" ]; then
        echo "❌ 未获取到原生公网 IPv4 或 IPv6，拒绝修改 Cloudflare DNS。"
        return 1
    fi

    prepare_sing_box_domains "$subdomain" || return 1
    anytls_domain=$(get_state_value "anytls_domain" "$sing_box_key_file")
    hy2_domain=$(get_state_value "hy2_domain" "$sing_box_key_file")
    cf_token=$(get_cloudflare_token) || return 1

    echo "正在查找 Cloudflare Zone: $domain"
    response=$(cloudflare_api GET "/zones?name=$domain&status=active&per_page=1" "$cf_token") || return 1
    check_cloudflare_response "$response" "查询 Zone $domain" || return 1
    zone_id=$(printf '%s' "$response" | jq -r '.result[0].id // empty')
    if [ -z "$zone_id" ]; then
        echo "❌ 未找到 Cloudflare Zone: $domain。请检查 Token 的 Zone Read 权限和域名范围。"
        return 1
    fi

    echo "---"
    echo "正在通过 Cloudflare API 配置 DNS..."
    for record_name in "$subdomain" "$anytls_domain" "$hy2_domain"; do
        if [ -n "$ip_v4" ]; then
            upsert_cloudflare_dns_record "$zone_id" A "$record_name" "$ip_v4" "$cf_token" || return 1
        else
            delete_cloudflare_dns_records "$zone_id" A "$record_name" "$cf_token" || return 1
        fi
        if [ -n "$ip_v6" ]; then
            upsert_cloudflare_dns_record "$zone_id" AAAA "$record_name" "$ip_v6" "$cf_token" || return 1
        else
            delete_cloudflare_dns_records "$zone_id" AAAA "$record_name" "$cf_token" || return 1
        fi
    done
}

generate_connection_qr() {
    local label="$1"
    local link="$2"
    local output_file="$3"

    [ -n "$link" ] || return 0
    if ! command -v qrencode >/dev/null 2>&1; then
        echo "⚠️ 未找到 qrencode，跳过 $label 二维码。"
        return 0
    fi

    echo "---"
    echo "$label 二维码:"
    printf '%s' "$link" | qrencode -t UTF8 -m 2
    if printf '%s' "$link" | qrencode -o "$output_file" -s 8 -m 2; then
        chmod 600 "$output_file"
        echo "二维码文件: $output_file"
    else
        echo "⚠️ $label PNG 二维码生成失败。"
    fi
}

generate_connection_info_qr() {
    local info="$1"
    local text_file="$2"
    local qr_file="$3"

    [ -n "$info" ] || return 0
    mkdir -p "$(dirname "$text_file")"
    printf '%s\n' "$info" > "$text_file"
    chmod 600 "$text_file"
    generate_connection_qr "完整连接信息" "$info" "$qr_file"
    echo "完整信息文件: $text_file"
}

get_subdomain_prefix() {
    local subdomain="$1"
    local prefix="${subdomain%%.*}"

    prefix=$(printf '%s' "$prefix" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9-]/-/g; s/--*/-/g; s/^-//; s/-$//')
    printf '%s' "$prefix"
}

make_link_tag() {
    local subdomain="$1"
    local core="$2"
    local protocol="$3"
    local prefix

    prefix=$(get_subdomain_prefix "$subdomain")
    [ -n "$prefix" ] || prefix="node"
    printf '%s-%s-%s' "$prefix" "$core" "$protocol"
}

format_link_server_address() {
    local ip_v4="$1"
    local ip_v6="$2"

    if [ -n "$ip_v4" ]; then
        printf '%s' "$ip_v4"
    elif [ -n "$ip_v6" ]; then
        printf '[%s]' "$ip_v6"
    fi
}

# ---
# 1. 安装必要的软件包
# ---

# 通用版本比较函数: version_ge <version> <required> 返回0表示满足
version_ge() {
    local ver="$1" req="$2"
    local vmaj vmin vpatch rmaj rmin rpatch
    vmaj=$(echo "$ver" | cut -d. -f1)
    vmin=$(echo "$ver" | cut -d. -f2)
    vpatch=$(echo "$ver" | cut -d. -f3)
    rmaj=$(echo "$req" | cut -d. -f1)
    rmin=$(echo "$req" | cut -d. -f2)
    rpatch=$(echo "$req" | cut -d. -f3)
    { [ "$vmaj" -gt "$rmaj" ] || \
      { [ "$vmaj" -eq "$rmaj" ] && [ "$vmin" -gt "$rmin" ]; } || \
      { [ "$vmaj" -eq "$rmaj" ] && [ "$vmin" -eq "$rmin" ] && [ "$vpatch" -ge "$rpatch" ]; }; } 2>/dev/null
}

# 检查并安装满足版本要求的 nginx (>= 1.25.1)
ensure_nginx_version() {
    local required="1.25.1"

    echo "---"
    echo "正在检查 apt 源中的 nginx 版本..."

    local apt_version ver_nums
    apt_version=$(apt-cache policy nginx-full 2>/dev/null | grep 'Candidate:' | awk '{print $2}')

    if [ -n "$apt_version" ]; then
        ver_nums=$(echo "$apt_version" | grep -oP '^\d+\.\d+\.\d+')
        echo "apt 源中 nginx-full 候选版本: $ver_nums"
        if version_ge "$ver_nums" "$required"; then
            echo "✅ apt 源中的 nginx 版本 ($ver_nums) >= $required，将使用系统源安装。"
            return 0
        fi
    fi

    echo "⚠️ apt 源中的 nginx 版本不满足要求 (需要 >= $required)。"
    echo "正在添加 nginx 官方仓库..."

    sudo apt install -y curl gnupg2 ca-certificates lsb-release
    curl -fsSL https://nginx.org/keys/nginx_signing.key | sudo gpg --dearmor -o /usr/share/keyrings/nginx-archive-keyring.gpg --yes

    . /etc/os-release
    echo "deb [signed-by=/usr/share/keyrings/nginx-archive-keyring.gpg] http://nginx.org/packages/mainline/$ID $(lsb_release -cs) nginx" | \
        sudo tee /etc/apt/sources.list.d/nginx.list > /dev/null

    echo -e "Package: *\nPin: origin nginx.org\nPin: release o=nginx\nPin-Priority: 900\n" | \
        sudo tee /etc/apt/preferences.d/99nginx > /dev/null

    sudo apt update
    packages=$(echo "$packages" | sed 's/nginx-full/nginx/')
    echo "✅ nginx 官方仓库已添加，将安装最新 mainline 版本。"
}

ensure_tcp_fast_open() {
    local config_file="/etc/sysctl.d/99-tcp-fastopen.conf"
    local current_value=""

    echo "---"
    echo "正在检查 TCP Fast Open..."
    if [ -r /proc/sys/net/ipv4/tcp_fastopen ]; then
        current_value=$(cat /proc/sys/net/ipv4/tcp_fastopen)
    fi

    if [ "$current_value" = "3" ] && \
       sudo grep -Eq '^[[:space:]]*net\.ipv4\.tcp_fastopen[[:space:]]*=[[:space:]]*3([[:space:]]*(#.*)?)?$' "$config_file" 2>/dev/null; then
        echo "✅ TCP Fast Open 已启用并持久化 (值: 3)。"
        return 0
    fi

    printf '%s\n' 'net.ipv4.tcp_fastopen = 3' | sudo tee "$config_file" > /dev/null
    if [ -w /proc/sys/net/ipv4/tcp_fastopen ]; then
        printf '3' > /proc/sys/net/ipv4/tcp_fastopen
    else
        printf '3' | sudo tee /proc/sys/net/ipv4/tcp_fastopen > /dev/null
    fi

    current_value=$(cat /proc/sys/net/ipv4/tcp_fastopen 2>/dev/null)
    if [ "$current_value" != "3" ]; then
        echo "❌ TCP Fast Open 启用失败，当前值: ${current_value:-未知}"
        return 1
    fi
    echo "✅ TCP Fast Open 已启用并持久化 (值: 3)。"
}

ensure_proxy_firewall_ports() {
    local tcp_rule_missing=false
    local udp_rule_missing=false
    local reject_line=""
    local backup_file=""

    echo "---"
    echo "正在检查 IPv4 防火墙的 TCP/UDP 443..."
    if ! command -v iptables >/dev/null 2>&1; then
        echo "⚠️ 未找到 iptables，跳过 IPv4 防火墙配置。"
        return 0
    fi

    if ! sudo iptables -C INPUT -p tcp --dport 443 -m conntrack --ctstate NEW -j ACCEPT 2>/dev/null; then
        tcp_rule_missing=true
    fi
    if ! sudo iptables -C INPUT -p udp --dport 443 -j ACCEPT 2>/dev/null; then
        udp_rule_missing=true
    fi

    if [ "$tcp_rule_missing" = "true" ] || [ "$udp_rule_missing" = "true" ]; then
        if sudo test -f /etc/iptables/rules.v4; then
            backup_file="/etc/iptables/rules.v4.bak.$(date +%Y%m%d%H%M%S)"
            if sudo cp /etc/iptables/rules.v4 "$backup_file"; then
                echo "✅ 已备份 IPv4 防火墙规则到 $backup_file"
            else
                echo "⚠️ IPv4 防火墙规则备份失败，继续执行。"
            fi
        fi
    fi

    if [ "$tcp_rule_missing" = "true" ]; then
        reject_line=$(sudo iptables -L INPUT --line-numbers -n 2>/dev/null | \
            awk '$2 == "REJECT" || $2 == "DROP" { print $1; exit }')
        if [ -n "$reject_line" ]; then
            if sudo iptables -I INPUT "$reject_line" \
                -p tcp --dport 443 -m conntrack --ctstate NEW -j ACCEPT; then
                echo "✅ 已放行 IPv4 TCP 443。"
            else
                echo "⚠️ IPv4 TCP 443 放行失败，继续执行。"
            fi
        else
            if sudo iptables -A INPUT \
                -p tcp --dport 443 -m conntrack --ctstate NEW -j ACCEPT; then
                echo "✅ 已放行 IPv4 TCP 443。"
            else
                echo "⚠️ IPv4 TCP 443 放行失败，继续执行。"
            fi
        fi
    fi

    if [ "$udp_rule_missing" = "true" ]; then
        reject_line=$(sudo iptables -L INPUT --line-numbers -n 2>/dev/null | \
            awk '$2 == "REJECT" || $2 == "DROP" { print $1; exit }')
        if [ -n "$reject_line" ]; then
            if sudo iptables -I INPUT "$reject_line" -p udp --dport 443 -j ACCEPT; then
                echo "✅ 已放行 IPv4 UDP 443。"
            else
                echo "⚠️ IPv4 UDP 443 放行失败，继续执行。"
            fi
        else
            if sudo iptables -A INPUT -p udp --dport 443 -j ACCEPT; then
                echo "✅ 已放行 IPv4 UDP 443。"
            else
                echo "⚠️ IPv4 UDP 443 放行失败，继续执行。"
            fi
        fi
    fi

    if ! sudo iptables -C INPUT -p tcp --dport 443 -m conntrack --ctstate NEW -j ACCEPT 2>/dev/null || \
       ! sudo iptables -C INPUT -p udp --dport 443 -j ACCEPT 2>/dev/null; then
        echo "⚠️ IPv4 TCP/UDP 443 防火墙规则验证失败，继续执行。"
        return 0
    fi

    if command -v netfilter-persistent >/dev/null 2>&1; then
        if ! sudo netfilter-persistent save; then
            echo "⚠️ IPv4 防火墙规则持久化失败，继续执行。"
            return 0
        fi
    else
        sudo install -d -m 755 /etc/iptables
        if ! sudo iptables-save | sudo tee /etc/iptables/rules.v4 >/dev/null; then
            echo "⚠️ 无法保存 IPv4 防火墙规则，继续执行。"
            return 0
        fi
        echo "⚠️ 未找到 netfilter-persistent，规则已写入 /etc/iptables/rules.v4，但需确认启动时会加载。"
    fi

    echo "✅ IPv4 TCP/UDP 443 已放行并持久化。"
}

install_pkgs_and_setup_env() {
    echo "---"
    echo "开始安装必要的软件包: $packages"
    echo "---"
    sudo apt update

    # 先检查 apt 源中的 nginx 版本，如不满足要求则添加官方源
    ensure_nginx_version

    sudo env DEBIAN_FRONTEND=noninteractive apt install -y $packages

    if [ $? -eq 0 ]; then
        echo "✅ 所有软件包已成功安装！"
    else
        echo "❌ 安装过程中出现错误，请检查上面的输出。"
        return 1
    fi

    ensure_tcp_fast_open || return 1
    ensure_proxy_firewall_ports

    # 安装后确认 nginx 版本是否满足要求 (>= 1.25.1)
    local nginx_ver
    nginx_ver=$(sudo nginx -v 2>&1 | grep -oP '\d+\.\d+\.\d+')
    echo "已安装的 nginx 版本: $nginx_ver"
    if ! version_ge "$nginx_ver" "1.25.1"; then
        echo "❌ 安装后 nginx 版本 ($nginx_ver) 仍不满足要求 (>= 1.25.1)，请手动检查。"
        return 1
    fi
    echo "✅ nginx 版本检查通过: $nginx_ver >= 1.25.1"

    echo "---"
    echo "设置系统环境"
    echo "---"
    if grep -q "ss_port" "$HOME/.bashrc"; then
        echo "✅ .bashrc 环境似乎已配置过，跳过写入。"
    else
        echo "正在配置 .bashrc..."
        cat <<'EOF' >> $HOME/.bashrc
alias ll='ls -l'
alias t='tmux a -t 0'
alias tailf='tail -f'
export SYSTEMD_EDITOR=vim
ss_port() {
    if [ -z "$1" ]; then
        echo "错误：请传入一个端口号。"
        return 1
    fi

    # 使用正则表达式检查是否为纯数字
    if ! [[ "$1" =~ ^[0-9]+$ ]]; then
        echo "错误：'$1' 不是一个有效的数字。"
        return 1
    fi

    if [ "$1" -ge 1 ] && [ "$1" -le 65535 ]; then
        sudo ss -ltnp "sport = :$1"
    else
        echo "错误：端口号 '$1' 必须在1到65535之间。"
        return 1
    fi
}
EOF
    fi
    cat <<EOF > $HOME/.inputrc
"\e[A":history-search-backward
"\e[B":history-search-forward
EOF
    cat <<EOF > $HOME/.vimrc
syntax enable
set nu
set autoindent
set expandtab
set tabstop=4
set shiftwidth=4
set backspace=indent,eol,start
set mouse=a
EOF
    cat <<EOF > $HOME/.tmux.conf
set-option -g display-time 1000		# msg display time, 1000 ms

set-option -g prefix C-j
unbind-key C-b
bind-key C-j send-prefix

bind r source-file ~/.tmux.conf \; display "Reloaded!"	    # reload config file

bind c new-window -c "#{pane_current_path}"
bind | split-window -h -c "#{pane_current_path}"    # horizontal
bind - split-window -v -c "#{pane_current_path}"    # vertical
bind h select-pane -L
bind j select-pane -D
bind k select-pane -U
bind l select-pane -R
bind -r H resize-pane -L 5  # if want to expand large space, press H several times
bind -r J resize-pane -D 5
bind -r K resize-pane -U 5
bind -r L resize-pane -R 5

set -g default-terminal "screen-256color"
set -g status-fg white
set -g status-bg black

set -g status-style bright

# default window title colors
set-window-option -g window-status-style fg=cyan
set-window-option -g window-status-style bg=default
set-window-option -g window-status-style dim

# active window title colors
set-window-option -g window-status-current-style fg=white
set-window-option -g window-status-current-style bg=red
set-window-option -g window-status-current-style bright

# Highlight active window
set-window-option -g window-status-current-style bg=red

#setw -g window-status-fg cyan
#setw -g window-status-bg default
#setw -g window-status-attr dim
#setw -g window-status-current-fg white
#setw -g window-status-current-bg red
#setw -g window-status-current-attr bright
#setw -g mode-mouse on
#set -g mouse-select-pane on
#set -g mouse-select-window on
#set -g mouse-resize-pane on
set -g status-left "#[fg=green][#S]"
set -g status-right "#[fg=cyan]#H %d-%b %R"
set -g status-interval 60   # update time every 60 sec
EOF
}

# ---
# 2. 申请或更新证书
# ---
apply_or_renew_cert() {
    local target_subdomain="$1"
    local subdomain=""
    local domain=""
    local cert_domains=()
    local cert_path=""
    local cert_checksum_before=""

    echo "---"
    echo "开始为您的域名申请泛域名证书"
    echo "---"

    mkdir -p "$cert_dir"
    cd "$cert_dir" || { echo "无法进入目录 $cert_dir，退出。"; return 1; }
    get_cloudflare_token >/dev/null || return 1

    if [ -n "$target_subdomain" ]; then
        subdomain="$target_subdomain"
        echo "$subdomain" > "$domain_file"
    else
        if [ -f "$domain_file" ]; then
            subdomain=$(head -n 1 "$domain_file")
            echo "---"
            read -p "从文件读取到名称: $subdomain, 是否正确且为子域名? [Y/n]: " sub_confirm
            if [[ "$sub_confirm" =~ ^[Nn]$ ]]; then
                read -p "请输入正确的子域名（例如 sub.example.com）: " subdomain
                if [ -n "$subdomain" ]; then
                    echo "$subdomain" > "$domain_file"
                    echo "✅ 子域名已更新并保存。"
                fi
            else
                echo "✅ 继续使用: $subdomain"
            fi
        fi
        if [ -z "$subdomain" ]; then
            read -p "请输入您的子域名（例如 sub.example.com）: " subdomain
            if [ -z "$subdomain" ]; then
                echo "❌ 错误：域名不能为空。"
                return 1
            else
                echo "$subdomain" > "$domain_file"
            fi
        fi
    fi
    domain=$(derive_root_domain "$subdomain")
    cert_domains=(-d "$domain" -d "*.$domain")
    cert_path="/etc/letsencrypt/live/$domain/fullchain.pem"
    cert_checksum_before=$(get_cert_checksum "$cert_path")

    echo "---"
    echo "正在使用 Certbot 申请证书..."
    sudo env PYTHONWARNINGS=ignore::PendingDeprecationWarning certbot certonly \
        --no-eff-email \
        --dns-cloudflare \
        --dns-cloudflare-credentials "$cf_ini" \
        --dns-cloudflare-propagation-seconds "$certbot_dns_propagation_seconds" \
        --agree-tos \
        --cert-name "$domain" \
        "${cert_domains[@]}" \
        --preferred-challenges dns

    if [ $? -eq 0 ]; then
        echo ""
        echo "✅ 证书申请成功！证书文件已保存在 /etc/letsencrypt/live/$domain/ 目录下。"
        handle_successful_cert_update "$domain" "$cert_checksum_before" || return 1
    else
        echo ""
        echo "❌ 证书申请失败。请检查您的域名、API Token 以及 DNS 配置。"
        return 1
    fi
}

# ---
# 3. 添加 IPv4 支持 (WARP)
# ---
add_ipv4_by_warp() {
    local warp_dir="$fq_dir/cf_warp"

    echo "---"
    echo "正在检查系统IPv4连接..."
    echo "---"

    if curl -4 -s --connect-timeout 2 https://www.google.com >/dev/null 2>&1 || \
       curl -4 -s --connect-timeout 2 https://1.1.1.1 >/dev/null 2>&1; then
        echo "✅ 检测到系统已有 IPv4 出口，无需配置 WARP。"
        return 0
    else
        echo "⚠️ 未检测到有效的 IPv4 出口，准备配置 WARP 接管 IPv4 流量。"
    fi

    mkdir -p "$warp_dir"
    cd "$warp_dir" || { echo "无法进入目录 $warp_dir，退出。"; return 1; }

    local arch=$(dpkg --print-architecture)
    while true; do
        echo "------------------------------------------------"
        echo "⚠️  检测到可能是纯 IPv6 环境，无法自动从 GitHub 下载 wgcf。"
        echo "请手动下载 wgcf 并上传到服务器。"
        echo ""
        echo "1. 请在您的电脑上下载此文件(根据您的架构 $arch):"
        echo "   下载地址: https://github.com/ViRb3/wgcf/releases/"
        echo ""
        echo "2. 将文件上传到服务器的此目录: $warp_dir"
        echo "   (您可以使用 SFTP 工具，或者 scp 命令)"
        echo "------------------------------------------------"

        read -p "✅ 上传完成后，请按 Enter 键继续检查..."

        local wgcf_file=$(ls -1t wgcf_* | head -n 1)
        if [[ -z "$wgcf_file" ]]; then
            echo "❌ 仍未检测到文件，请检查上传路径是否正确。"
        else
            echo "✅ 检测到 wgcf 文件！"
            chmod +x "$wgcf_file"
            break
        fi
    done

    local bin_dir="$HOME/bin"
    mkdir -p "$bin_dir"
    ln -sf "$warp_dir/$wgcf_file" "$bin_dir/wgcf"
    echo "✅ 已在 ~/bin 目录创建 wgcf 软链接。"

    if [[ ":$PATH:" != *":$bin_dir:"* ]]; then
        echo 'export PATH="$HOME/bin:$PATH"' >> "$HOME/.bashrc"
        echo "⚠️ ~/bin 已添加到 PATH，请重新启动终端或执行 'source ~/.bashrc' 使其生效。"
        source "$HOME/.bashrc"
    fi

    echo "---"
    echo "正在注册 WARP 账户..."
    $bin_dir/wgcf register --accept-tos

    echo "正在生成 WireGuard 配置文件..."
    $bin_dir/wgcf generate

    if [ $? -ne 0 ]; then
        echo "wgcf 注册和生成配置失败，退出..."
        return 1
    fi

    cp wgcf-account.toml wgcf-account.toml.bak
    cp wgcf-profile.conf wgcf-profile.conf.bak
    echo "✅ 配置文件已备份。"

    echo "---"
    echo "正在解析 WARP 节点地址..."
    local warp_ipv6=""

    # 尝试解析
    if command -v nslookup &> /dev/null; then
        # grep 'Address:' | grep -oP '([0-9a-fA-F]{1,4}){0,1}:([0-9a-fA-F]{1,4}){0,1}:[0-9a-fA-F:]+' | head -n 1)
         warp_ipv6=$(nslookup -type=AAAA engage.cloudflareclient.com 2>/dev/null | grep 'Address:' | tail -n1 | awk '{print $2}')
    fi

    # 如果解析失败，使用 Cloudflare 官方固定 IPv6 地址兜底
    if [[ -z "$warp_ipv6" ]]; then
        echo "⚠️ 自动解析失败，使用 Cloudflare 默认 IPv6 节点。"
        warp_ipv6="2606:4700:d0::a29f:c001"
    else
        echo "✅ 解析成功: $warp_ipv6"
    fi
    # 先去掉可能存在的方括号，再统一加上
    warp_ipv6=$(echo "$warp_ipv6" | tr -d '[]')
    echo "✅ 解析到的 WARP IPv6 地址：$warp_ipv6"

    sed -i "s/DNS = .*/DNS = 2001:4860:4860::8888, 2001:4860:4860::8844, 8.8.8.8, 8.8.4.4/" wgcf-profile.conf
    sed -i "s/AllowedIPs = .*/AllowedIPs = 0.0.0.0\/0/" wgcf-profile.conf
    sed -i "s/Endpoint = .*/Endpoint = [${warp_ipv6}]:2408/" wgcf-profile.conf
    echo "✅ 配置文件已修改，准备启动 WARP..."

    sudo wg-quick up wgcf-profile.conf
    if [ $? -ne 0 ]; then
        echo "wg-quick up 执行失败，退出..."
        return 1
    fi

    echo "正在验证连接..."
    if ! curl -4 -s --connect-timeout 5 https://1.1.1.1 >/dev/null; then
        echo "❌ WARP 启动后无法访问 IPv4，正在回滚..."
        sudo wg-quick down wgcf-profile.conf
        return 1
    fi
    echo "✅ IPv4 连接测试成功！"
    sudo wg-quick down wgcf-profile.conf

    read -p "将安装WARP为系统服务，确认后按 Enter 继续..."
    echo "---"
    echo "正在安装 WARP 为系统服务..."
    sudo cp wgcf-profile.conf /etc/wireguard/wgcf0.conf
    sudo systemctl enable wg-quick@wgcf0
    sudo systemctl start wg-quick@wgcf0

    sleep 3
    echo "---"
    echo "正在再次检查 IPv4 连接..."
    if curl -4 -s --connect-timeout 3 https://1.1.1.1 >/dev/null; then
        echo "✅✅ WARP 启动成功！系统现在拥有了 IPv4 访问能力。"
    else
        echo "❌ WARP 启动似乎成功，但无法访问 IPv4 网络。"
        echo "请检查 status: sudo systemctl status wg-quick@wgcf0"
        return 1
    fi
}

# ---
# 4. 安装 sing-box (VLESS Reality、AnyTLS、Hysteria2)
# ---
install_sing_box() {
    local domain="$1"
    local subdomain="$2"
    local cert_path=""
    local key_path=""
    local cert_expires=""
    local uuid=""
    local reality_private_key=""
    local reality_public_key=""
    local reality_short_id=""
    local reality_target=""
    local anytls_domain=""
    local anytls_password=""
    local hy2_domain=""
    local hy2_password=""
    local config_file="$sing_box_dir/config.json"
    local system_config="/etc/sing-box/config.json"
    local reality_output=""
    local ip_v4=""
    local ip_v6=""
    local server_address=""
    local vless_link=""
    local anytls_link=""
    local hy2_link=""
    local vless_tag=""
    local anytls_tag=""
    local hy2_tag=""
    local installer_file=""
    local full_info=""

    if [ -z "$subdomain" ] && [ -f "$domain_file" ]; then
        subdomain=$(head -n 1 "$domain_file")
    fi
    if [ -z "$subdomain" ]; then
        read -p "请输入证书对应的子域名（例如 hello.example.com）: " subdomain
    fi
    if [ -z "$subdomain" ]; then
        echo "❌ 子域名不能为空。"
        return 1
    fi
    if [ -z "$domain" ]; then
        domain=$(echo "$subdomain" | awk -F. '{if (NF>2) { if ($0 ~ /\.(com\.cn|net\.cn|org\.cn|gov\.cn|edu\.cn|ac\.cn|eu\.org|co\.uk|org\.uk|me\.uk)$/) {print $(NF-2)"."$(NF-1)"."$NF} else {print $(NF-1)"."$NF} } else {print $0}}')
    fi
    ensure_tcp_fast_open || return 1
    ensure_proxy_firewall_ports

    cert_path="/etc/letsencrypt/live/$domain/fullchain.pem"
    key_path="/etc/letsencrypt/live/$domain/privkey.pem"
    if ! sudo test -f "$cert_path" || ! sudo test -f "$key_path"; then
        echo "❌ 未找到 $domain 的证书或私钥，请先申请证书。"
        return 1
    fi
    cert_expires=$(sudo openssl x509 -in "$cert_path" -noout -enddate 2>/dev/null | sed 's/^notAfter=//')

    prepare_sing_box_domains "$subdomain" || return 1
    anytls_domain=$(get_state_value "anytls_domain" "$sing_box_key_file")
    hy2_domain=$(get_state_value "hy2_domain" "$sing_box_key_file")

    echo "---"
    echo "正在安装或更新 sing-box..."
    installer_file=$(mktemp)
    if ! curl -fsSL https://sing-box.app/install.sh -o "$installer_file"; then
        rm -f "$installer_file"
        echo "❌ sing-box 安装脚本下载失败。"
        return 1
    fi
    if ! sudo sh "$installer_file"; then
        rm -f "$installer_file"
        echo "❌ sing-box 安装失败。"
        return 1
    fi
    rm -f "$installer_file"
    if ! command -v sing-box >/dev/null 2>&1; then
        echo "❌ sing-box 安装完成后仍未找到可执行文件。"
        return 1
    fi

    mkdir -p "$sing_box_dir"
    chmod 700 "$sing_box_dir"

    uuid=$(get_state_value "uuid" "$sing_box_key_file")
    reality_private_key=$(get_state_value "reality_private_key" "$sing_box_key_file")
    reality_public_key=$(get_state_value "reality_public_key" "$sing_box_key_file")
    reality_short_id=$(get_state_value "reality_short_id" "$sing_box_key_file")
    reality_target=$(get_state_value "reality_target" "$sing_box_key_file")
    anytls_password=$(get_state_value "anytls_password" "$sing_box_key_file")
    hy2_password=$(get_state_value "hy2_password" "$sing_box_key_file")

    if [ -z "$uuid" ]; then
        uuid=$(sing-box generate uuid)
        set_state_value "uuid" "$uuid" "$sing_box_key_file"
    fi
    if [ -z "$reality_private_key" ] || [ -z "$reality_public_key" ]; then
        reality_output=$(sing-box generate reality-keypair)
        reality_private_key=$(printf '%s\n' "$reality_output" | awk -F': ' '/PrivateKey/ {print $2; exit}')
        reality_public_key=$(printf '%s\n' "$reality_output" | awk -F': ' '/PublicKey/ {print $2; exit}')
        if [ -z "$reality_private_key" ] || [ -z "$reality_public_key" ]; then
            echo "❌ 无法生成 Reality 密钥。"
            return 1
        fi
        set_state_value "reality_private_key" "$reality_private_key" "$sing_box_key_file"
        set_state_value "reality_public_key" "$reality_public_key" "$sing_box_key_file"
    fi
    if [ -z "$reality_short_id" ]; then
        reality_short_id=$(openssl rand -hex 4)
        set_state_value "reality_short_id" "$reality_short_id" "$sing_box_key_file"
    fi
    if [ -z "$reality_target" ]; then
        echo "---"
        echo "请选择 sing-box VLESS Reality 目标网站:"
        echo "1. Microsoft (www.microsoft.com)"
        echo "2. Oracle (www.oracle.com)"
        echo "3. LoveLive (www.lovelive-anime.jp)"
        echo "4. AMP (amp.dev)"
        echo "5. Singapore Data (data.gov.sg)"
        echo "6. Singapore Government (www.gov.sg)"
        read -p "请输入选项 (默认 1): " target_choice
        case "$target_choice" in
            2) reality_target="www.oracle.com" ;;
            3) reality_target="www.lovelive-anime.jp" ;;
            4) reality_target="amp.dev" ;;
            5) reality_target="data.gov.sg" ;;
            6) reality_target="www.gov.sg" ;;
            *) reality_target="www.microsoft.com" ;;
        esac
        set_state_value "reality_target" "$reality_target" "$sing_box_key_file"
    fi
    remove_state_keys "$sing_box_key_file" anytls_reality_target
    if [ -z "$anytls_password" ]; then
        anytls_password=$(openssl rand -hex 16)
        set_state_value "anytls_password" "$anytls_password" "$sing_box_key_file"
    fi
    if [ -z "$hy2_password" ]; then
        hy2_password=$(openssl rand -hex 16)
        set_state_value "hy2_password" "$hy2_password" "$sing_box_key_file"
    fi

    cat > "$config_file" <<EOF
{
  "log": {
    "disabled": false,
    "level": "info",
    "timestamp": true
  },
  "dns": {
    "servers": [
      {
        "tag": "cf",
        "type": "tls",
        "server": "2606:4700:4700::1111"
      },
      {
        "tag": "google",
        "type": "tls",
        "server": "2001:4860:4860::8888"
      }
    ]
  },
  "route": {
    "default_domain_resolver": {
      "server": "cf",
      "strategy": "prefer_ipv6"
    },
    "rules": [
      {
        "outbound": "block",
        "rule_set": "geoip-cn"
      },
      {
        "outbound": "block",
        "rule_set": "geosite-cn"
      },
      {
        "outbound": "block",
        "ip_is_private": true
      },
      {
        "outbound": "outbound-direct"
      }
    ],
    "rule_set": [
      {
        "tag": "geoip-cn",
        "type": "remote",
        "format": "binary",
        "url": "https://raw.githubusercontent.com/SagerNet/sing-geoip/rule-set/geoip-cn.srs",
        "download_detour": "outbound-direct"
      },
      {
        "tag": "geosite-cn",
        "type": "remote",
        "format": "binary",
        "url": "https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/geosite-cn.srs",
        "download_detour": "outbound-direct"
      }
    ]
  },
  "experimental": {
    "cache_file": {
      "enabled": true
    }
  },
  "inbounds": [
    {
      "type": "vless",
      "tag": "vless-in",
      "listen": "::1",
      "listen_port": 5443,
      "tcp_fast_open": true,
      "users": [
        {
          "uuid": "$uuid",
          "flow": "xtls-rprx-vision"
        }
      ],
      "tls": {
        "enabled": true,
        "server_name": "$reality_target",
        "reality": {
          "enabled": true,
          "handshake": {
            "server": "$reality_target",
            "server_port": 443
          },
          "private_key": "$reality_private_key",
          "short_id": [
            "$reality_short_id"
          ],
          "max_time_difference": "1m"
        }
      }
    },
    {
      "type": "anytls",
      "tag": "anytls-in",
      "listen": "::1",
      "listen_port": 7443,
      "tcp_fast_open": true,
      "users": [
        {
          "name": "default",
          "password": "$anytls_password"
        }
      ],
      "tls": {
        "enabled": true,
        "server_name": "$anytls_domain",
        "certificate_path": "$cert_path",
        "key_path": "$key_path"
      }
    },
    {
      "type": "hysteria2",
      "tag": "hy2-in",
      "listen": "::",
      "listen_port": 443,
      "users": [
        {
          "name": "default",
          "password": "$hy2_password"
        }
      ],
      "tls": {
        "enabled": true,
        "server_name": "$hy2_domain",
        "certificate_path": "$cert_path",
        "key_path": "$key_path"
      }
    }
  ],
  "outbounds": [
    {
      "type": "direct",
      "tag": "outbound-direct"
    },
    {
      "type": "block",
      "tag": "block"
    }
  ]
}
EOF
    chmod 600 "$config_file"

    echo "正在检查 sing-box 配置..."
    if ! sudo sing-box check -c "$config_file"; then
        echo "❌ sing-box 配置检查失败，未替换系统配置。"
        return 1
    fi

    sudo mkdir -p /etc/sing-box
    if sudo test -f "$system_config"; then
        sudo cp "$system_config" "${system_config}.bak_$(date +%s)"
    fi
    sudo install -m 600 "$config_file" "$system_config"
    sudo systemctl enable sing-box
    if ! sudo systemctl restart sing-box; then
        echo "❌ sing-box 启动失败，请执行 sudo journalctl -u sing-box -n 100 检查日志。"
        return 1
    fi
    sleep 2
    if ! sudo systemctl is-active --quiet sing-box; then
        echo "❌ sing-box 服务未处于运行状态。"
        return 1
    fi

    if command -v dig >/dev/null 2>&1 && [ "$ORIGINAL_HAS_IPV4" = "true" ]; then
        ip_v4=$(dig -4 @1.1.1.1 ch txt whoami.cloudflare +short 2>/dev/null | grep -v '^;' | tr -d '"' | head -n 1)
    fi
    if command -v dig >/dev/null 2>&1 && [ "$ORIGINAL_HAS_IPV6" = "true" ]; then
        ip_v6=$(dig -6 @2606:4700:4700::1111 ch txt whoami.cloudflare +short 2>/dev/null | grep -v '^;' | tr -d '"' | head -n 1)
    fi
    set_state_value "ipv4" "$ip_v4" "$sing_box_key_file"
    set_state_value "ipv6" "$ip_v6" "$sing_box_key_file"

    server_address=$(format_link_server_address "$ip_v4" "$ip_v6")
    vless_tag=$(make_link_tag "$subdomain" "sb" "vless")
    anytls_tag=$(make_link_tag "$subdomain" "sb" "anytls")
    hy2_tag=$(make_link_tag "$subdomain" "sb" "hy2")
    if [ -n "$server_address" ]; then
        vless_link="vless://${uuid}@${server_address}:443?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${reality_target}&fp=chrome&pbk=${reality_public_key}&sid=${reality_short_id}&type=tcp&tfo=1#${vless_tag}"
        set_state_value "vless_link" "$vless_link" "$sing_box_key_file"
        anytls_link="anytls://${anytls_password}@${server_address}:443?security=tls&sni=${anytls_domain}#${anytls_tag}"
        hy2_link="hysteria2://${hy2_password}@${server_address}:443?sni=${hy2_domain}#${hy2_tag}"
        set_state_value "anytls_link" "$anytls_link" "$sing_box_key_file"
        set_state_value "hy2_link" "$hy2_link" "$sing_box_key_file"
    else
        echo "⚠️ 未获取到公网 IP，跳过 VLESS/AnyTLS/Hysteria2 分享链接生成。"
    fi

    echo "✅ sing-box 已安装并启动。"
    echo "配置: $system_config"
    echo "连接信息: $sing_box_key_file"
    echo "AnyTLS: $anytls_domain:443/TCP (server=${server_address:-无})"
    echo "Hysteria2: $hy2_domain:443/UDP"
    [ -n "$vless_link" ] && echo "VLESS 链接: $vless_link"
    [ -n "$anytls_link" ] && echo "AnyTLS 链接: $anytls_link"
    [ -n "$hy2_link" ] && echo "Hysteria2 链接: $hy2_link"

    if [ -n "$vless_link" ]; then
        generate_connection_qr "VLESS" "$vless_link" "$sing_box_dir/vless.png"
    fi
    [ -n "$anytls_link" ] && generate_connection_qr "AnyTLS" "$anytls_link" "$sing_box_dir/anytls.png"
    [ -n "$hy2_link" ] && generate_connection_qr "Hysteria2" "$hy2_link" "$sing_box_dir/hy2.png"

    full_info=$(cat <<EOF
# Summary
IPv4: ${ip_v4:-无}
IPv6: ${ip_v6:-无}
Subdomain: ${subdomain:-无}
AnyTLS domain: ${anytls_domain:-无}
Hysteria2 domain: ${hy2_domain:-无}
Certificate: ${cert_path:-无}
Certificate expires: ${cert_expires:-未知}

VLESS:
${vless_link:-无}

AnyTLS:
${anytls_link:-无}

Hysteria2:
${hy2_link:-无}
EOF
)
    generate_connection_info_qr "$full_info" "$sing_box_dir/full-info.txt" "$sing_box_dir/full-info.png"
}

# ---
# 5. 安装 Xray VLESS Reality (备用，可单独安装)
# ---
install_xray() {
    local xray_port="$1"
    local xray_dir="$fq_dir/xray"

    if [ -z "$xray_port" ]; then
        if sudo ss -ltnp | grep -q ":443 "; then
            echo "⚠️ 检测到有进程已占用 443 端口 (可能是 Nginx)，Xray 将使用 6443 端口。"
            xray_port=6443
        else
            echo "✅ 检测到 443 端口空闲，Xray 将使用 443 端口。"
            xray_port=443
        fi
    fi

    # Set listen address: loopback if not on port 443 (e.g., when Nginx is used for port forwarding)
    local listen_addr="::"
    [ "$xray_port" != "443" ] && listen_addr="::1"

    echo "---"
    echo "正在下载并安装 Xray..."
    sudo bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install

    mkdir -p "$xray_dir"
    cd "$xray_dir" || { echo "❌ 错误: 无法进入目录 $xray_dir。请检查路径或权限。"; return 1; }
    echo "✅ 进入目录: $xray_dir"

    # 生成或加载 Xray 配置
    echo "---"
    echo "正在生成或加载 Xray 配置所需的密钥和ID..."
    local xray_key_file="$xray_dir/xray.key"
    local private_key=""
    local public_key=""
    local uuid=""
    local sid=""
    local xhttp_path=""
    local reality_output=""

    private_key=$(get_state_value "PrivateKey" "$xray_key_file")
    public_key=$(get_state_value "PublicKey" "$xray_key_file")
    uuid=$(get_state_value "uuid" "$xray_key_file")
    [ -n "$uuid" ] || uuid=$(get_state_value "uuid1" "$xray_key_file")
    sid=$(get_state_value "sid" "$xray_key_file")
    [ -n "$sid" ] || sid=$(get_state_value "sid1" "$xray_key_file")
    xhttp_path=$(get_state_value "xhttp_path" "$xray_key_file")

    if [ -z "$private_key" ] || [ -z "$public_key" ]; then
        echo "正在生成新的 Xray Reality 密钥..."
        reality_output=$(xray x25519 | sed 's/Password (PublicKey):/PublicKey:/g')
        private_key=$(printf '%s\n' "$reality_output" | awk -F': *' '/PrivateKey/ {print $2; exit}')
        public_key=$(printf '%s\n' "$reality_output" | awk -F': *' '/PublicKey/ {print $2; exit}')
        if [ -z "$private_key" ] || [ -z "$public_key" ]; then
            echo "❌ 错误: 无法获取 Xray Reality 密钥。请检查 Xray 是否安装成功。"
            return 1
        fi
        set_state_value "PrivateKey" "$private_key" "$xray_key_file"
        set_state_value "PublicKey" "$public_key" "$xray_key_file"
        echo "✅ 已生成 Xray Reality 密钥。"
    fi
    if [ -z "$uuid" ]; then
        uuid=$(xray uuid)
        set_state_value "uuid" "$uuid" "$xray_key_file"
    fi
    if [ -z "$sid" ]; then
        sid=$(openssl rand -hex 4)
        set_state_value "sid" "$sid" "$xray_key_file"
    fi
    if [ -z "$xhttp_path" ]; then
        xhttp_path=$(openssl rand -hex 5)
        set_state_value "xhttp_path" "$xhttp_path" "$xray_key_file"
    fi
    set_state_value "uuid" "$uuid" "$xray_key_file"
    set_state_value "sid" "$sid" "$xray_key_file"
    set_state_value "xhttp_path" "$xhttp_path" "$xray_key_file"
    remove_state_keys "$xray_key_file" uuid1 uuid2 sid1 sid2
    echo "✅ Xray 配置密钥已准备好: $xray_key_file"

    # 询问用户选择 REALITY 目标网站
    local reality_target reality_server_names
    local sing_box_reality_target
    sing_box_reality_target=$(get_state_value "reality_target" "$sing_box_key_file")
    while true; do
        echo "---"
        echo "请选择 REALITY 目标网站（建议根据服务器所在地区选择）："
        echo "1. Microsoft  (www.microsoft.com) — 推荐用于美国 IP"
        echo "2. Oracle     (www.oracle.com)    — 推荐用于美国 IP"
        echo "3. LoveLive   (www.lovelive-anime.jp) — 推荐用于日本 IP"
        echo "4. AMP        (amp.dev)           — 推荐用于美国 IP (GCP)"
        echo "5. Singapore Data (data.gov.sg)   — 推荐用于新加坡 IP"
        echo "6. Singapore Gov  (www.gov.sg)    — 推荐用于新加坡 IP"
        read -p "请输入选项 (默认 1): " target_choice
        case "$target_choice" in
            2)
                reality_target="www.oracle.com:443"
                reality_server_names='            "www.oracle.com",
            "linux.oracle.com",
            "community.oracle.com",
            "fusioncrm.oracle.com",
            "search.oracle.com",
            "my.oracle.com"'
                ;;
            3)
                reality_target="www.lovelive-anime.jp:443"
                reality_server_names='            "lovelive-anime.jp",
            "www.lovelive-anime.jp"'
                ;;
            4)
                reality_target="amp.dev:443"
                reality_server_names='            "amp.dev",
            "go.amp.dev",
            "www.amp.dev"'
                ;;
            5)
                reality_target="data.gov.sg:443"
                reality_server_names='            "data.gov.sg"'
                ;;
            6)
                reality_target="www.gov.sg:443"
                reality_server_names='            "www.gov.sg"'
                ;;
            *)
                reality_target="www.microsoft.com:443"
                reality_server_names='            "www.microsoft.com",
            "wwwqa.microsoft.com",
            "staticview.microsoft.com",
            "i.s-microsoft.com",
            "microsoft.com",
            "c.s-microsoft.com",
            "privacy.microsoft.com"'
                ;;
        esac

        if [ "$xray_port" != "443" ] && \
           [ -n "$sing_box_reality_target" ] && \
           [ "${reality_target%:*}" = "$sing_box_reality_target" ]; then
            echo "❌ 该 SNI 已被 sing-box VLESS 使用，请为 Xray 选择另一个目标。"
            continue
        fi
        break
    done
    echo "✅ 已选择目标: $reality_target"

    echo "---"
    echo "正在创建 config.jsonc 文件..."
    cat << EOF > config.jsonc
{
  "stats": {},
  "log": {
    "access": "/var/log/xray/access.log",
    "error": "/var/log/xray/error.log",
    "loglevel": "warning",
    "dnsLog": false
  },
  "inbounds": [
    {
      "listen": "$listen_addr",
      "port": $xray_port,
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "$uuid", // xray uuid
            "flow": "xtls-rprx-vision"
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "raw",
        //"network": "xhttp",
        //"xhttpSettings": {
        //  "path": "/$xhttp_path"
        //},
        "security": "reality",
        "realitySettings": {
          "show": false,
          "xver": 0,
          "target": "$reality_target",
          "serverNames": [
$reality_server_names
          ],
          "privateKey": "$private_key", // xray x25519
          "minClientVer": "",
          "maxClientVer": "",
          "maxTimeDiff": 0,
          "shortIds": [
            //"",    // 若有此项，客户端 shortId 可为空
            "$sid" // 0 到 f，长度为 2 的倍数，长度上限为 16
          ]
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": [
          "http",
          "tls",
          "quic"
        ]
      }
    }
  ],
  "outbounds": [
    {
      "protocol": "freedom",
      "tag": "default"
    },
    {
      "protocol": "blackhole",
      "tag": "block"
    }
  ],
  "routing": {
    "domainStrategy": "IPIfNonMatch",
    "rules": [
      {
        "type": "field",
        "domain": [
          "geosite:google",
          "domain:gstatic.com",
          "domain:googleapis.com",
          "domain:apple.com"
        ],
       "outboundTag": "default"
      },
      {
        "type": "field",
        "ip": [
          "geoip:cn"
        ],
        "outboundTag": "block"
      },
      {
        "type": "field",
        "domain": [
          "geosite:cn"
        ],
        "outboundTag": "block"
      }
    ]
  }
}
EOF

    echo "config.jsonc 已创建。"
    read -p "是否要打开 config.jsonc 进行编辑？(y/n): " edit_config
    if [[ "$edit_config" =~ ^[Yy]$ ]]; then
        vim config.jsonc
        echo "✅ 编辑完成，继续后续流程。"
    fi

    local sys_conf="/usr/local/etc/xray/config.json"
    echo "---"
    echo "正在将配置保存到 $sys_conf..."

    # 循环验证配置文件，直到通过为止
    while true; do
        # 先去除注释并生成 JSON
        if ! command -v jq &> /dev/null; then
            echo "⚠️ 警告: 未找到 jq 命令，无法格式化 JSON。将直接保存配置。"
            sed -e 's/\/\/.*//' config.jsonc | sudo tee "$sys_conf" > /dev/null
        else
            sed -e 's/\/\/.*//' config.jsonc | jq . | sudo tee "$sys_conf" > /dev/null
        fi

        ln -sf "$sys_conf" config.json

        echo "正在检查 Xray 配置文件（格式正确性）..."
        local test_output
        if command -v jq &> /dev/null; then
            test_output=$(jq empty "$sys_conf" 2>&1)
        else
            test_output=$(python3 -m json.tool "$sys_conf" >/dev/null 2>&1)
        fi
        if [ $? -eq 0 ]; then
            echo "✅ Xray 配置文件检查通过！"
            break
        else
            echo ""
            echo "❌ Xray 配置文件检查失败！错误信息如下："
            echo "---"
            echo "$test_output"
            echo "---"
            read -p "是否打开 config.jsonc 继续编辑以修复错误？(y/n): " fix_choice
            if [[ "$fix_choice" =~ ^[Yy]$ ]]; then
                vim config.jsonc
            else
                echo "⚠️ 配置文件存在错误，终止后续过程。"
                return 1
            fi
        fi
    done

    # 从最终的系统配置文件中提取 target
    local extracted_target=""
    if command -v jq &> /dev/null; then
        extracted_target=$(jq -r '.inbounds[0].streamSettings.realitySettings.target' "$sys_conf")
    else
        extracted_target=$(grep '"target":' "$sys_conf" | cut -d'"' -f4)
    fi
    local clean_target=${extracted_target%:*}

    if [ -n "$clean_target" ]; then
        set_state_value "target" "$clean_target" "$xray_key_file"
        echo "✅ 已提取并保存 target 域名到 xray.key: $clean_target"
    else
        echo "⚠️ 警告: 未能从配置文件中提取到 target 域名。"
    fi

    echo "---"
    echo "正在启动 Xray 服务..."
    sudo systemctl restart xray
    if [ $? -ne 0 ]; then
        echo "❌ Xray 服务启动失败，请检查 systemctl status xray。"
        return 1
    fi
    sudo systemctl status xray --no-pager
    echo "✅ Xray 服务已启动。"

    echo "---"
    echo "正在查询公网 IP 地址 (Cloudflare DNS)..."

    local ip_v4=""
    local ip_v6=""

    # 1. 查询 IPv4 (dig @1.1.1.1)
    # ch = Chaos class, txt = TXT record, whoami.cloudflare = magic domain
    # tr -d '"' 用于去除结果中的引号
    if command -v dig &> /dev/null; then
        ip_v4=$(dig -4 @1.1.1.1 ch txt whoami.cloudflare +short 2>/dev/null | grep -v '^;' | tr -d '"')
    fi

    # 2. 查询 IPv6 (dig @2606:4700:4700::1111)
    if [ "$ORIGINAL_HAS_IPV6" = "true" ]; then
        if command -v dig &> /dev/null; then
            ip_v6=$(dig -6 @2606:4700:4700::1111 ch txt whoami.cloudflare +short 2>/dev/null | grep -v '^;' | tr -d '"')
        fi
    fi

    # 3. 将 IP 保存到 xray.key
    set_state_value "ipv4" "$ip_v4" "$xray_key_file"
    set_state_value "ipv6" "$ip_v6" "$xray_key_file"

    echo "✅ IP 信息已更新到 $xray_key_file"
    echo "   IPv4: ${ip_v4:-[无]}"
    echo "   IPv6: ${ip_v6:-[无]}"

    # --- 新增功能：生成优化后的二维码 ---
    echo "---"
    echo "正在生成配置二维码..."
    if command -v qrencode &> /dev/null; then
        echo ""
        # 技巧：
        # 1. echo "# hi" 添加头部欺骗 iOS 相机
        # 2. grep -v 过滤掉包含 PrivateKey 的敏感行
        # 3. 管道传给 qrencode
        { echo "# hi"; grep -v "PrivateKey" "$xray_key_file"; } | qrencode -t UTF8

        echo ""
        echo "💡 提示：请使用 iPhone 相机扫描上方二维码 (已隐藏私钥，并添加头部修正识别问题)。"
    else
        echo "⚠️ 未找到 qrencode 命令，跳过二维码生成。"
    fi

    # --- 生成 VLESS 链接二维码 (用于 Shadowrocket 导入) ---
    echo "---"
    echo "正在生成 VLESS 链接二维码 (可用于 Shadowrocket 导入)..."
    if command -v qrencode &> /dev/null; then
        # 从xray.key读取必要参数
        local sni="${clean_target:-www.microsoft.com}"
        local xray_subdomain=""
        local vless_tag=""
        if [ -f "$domain_file" ]; then
            xray_subdomain=$(head -n 1 "$domain_file")
        fi
        vless_tag=$(make_link_tag "$xray_subdomain" "xray" "vless")

        # 构建 VLESS 链接
        # 格式: vless://UUID@地址:端口?参数#备注名
        local vless_params="encryption=none&flow=xtls-rprx-vision&security=reality&sni=${sni}&fp=safari&pbk=${public_key}&sid=${sid}&type=tcp&headerType=none&tfo=1"

        if [ -n "$ip_v4" ]; then
            if [ "$ORIGINAL_HAS_IPV4" = "true" ]; then
                # 注意：即使 Xray 监听 6443，客户端连接的仍是 Nginx 的 443，所以这里端口填 443 是正确的
                local vless_v4="vless://${uuid}@${ip_v4}:443?${vless_params}#${vless_tag}"
                echo ""
                echo "📱 IPv4 VLESS 链接二维码 (Shadowrocket):"
                echo "$vless_v4" | qrencode -t UTF8
                echo ""
                echo "链接: $vless_v4"
            else
                echo "⚠️ 按照配置，系统初始无 IPv4，不再展示 IPv4 VLESS 二维码。"
            fi
        else
            echo "⚠️ 无 IPv4 地址，跳过 IPv4 VLESS 二维码。"
        fi

        echo ""

        if [ -n "$ip_v6" ]; then
            local vless_v6="vless://${uuid}@[${ip_v6}]:443?${vless_params}#${vless_tag}"
            echo "📱 IPv6 VLESS 链接二维码 (Shadowrocket):"
            echo "$vless_v6" | qrencode -t UTF8
            echo ""
            echo "链接: $vless_v6"
        else
            echo "⚠️ 无 IPv6 地址，跳过 IPv6 VLESS 二维码。"
        fi
    else
        echo "⚠️ 未找到 qrencode 命令，跳过 VLESS 二维码生成。"
    fi
}

# ---
# 6. 更新 Nginx 配置 (Stream & Site)
# ---
update_nginx_config() {
    local domain="$1"
    local subdomain="$2"

    echo "---"
    echo "正在准备更新 Nginx 配置..."

    # 1. 获取域名
    if [ -z "$domain" ] || [ -z "$subdomain" ]; then
        if [ -f "$domain_file" ]; then
            subdomain=$(head -n 1 "$domain_file")
            domain=$(echo "$subdomain" | awk -F. '{if (NF>2) { if ($0 ~ /\.(com\.cn|net\.cn|org\.cn|gov\.cn|edu\.cn|ac\.cn|eu\.org|co\.uk|org\.uk|me\.uk)$/) {print $(NF-2)"."$(NF-1)"."$NF} else {print $(NF-1)"."$NF} } else {print $0}}')
            echo "✅ 读取到域名：$domain，子域名：$subdomain"
        else
            read -p "无法自动读取域名，请输入您的子域名（如 sub.example.com）: " subdomain
            if [ -z "$subdomain" ]; then
                echo "❌ 域名不能为空，退出。"
                return 1
            fi
            domain=$(echo "$subdomain" | awk -F. '{if (NF>2) { if ($0 ~ /\.(com\.cn|net\.cn|org\.cn|gov\.cn|edu\.cn|ac\.cn|eu\.org|co\.uk|org\.uk|me\.uk)$/) {print $(NF-2)"."$(NF-1)"."$NF} else {print $(NF-1)"."$NF} } else {print $0}}')
        fi
    fi
    if ! sudo test -f "/etc/letsencrypt/live/$domain/fullchain.pem"; then
        echo "❌ 错误：未找到域名 $domain 的证书文件。"
        echo "请先执行步骤 2 申请证书，或检查域名是否一致。"
        return 1
    fi

    # 2. 修改 nginx.conf (添加 Stream 模块)
    local nginx_conf="/etc/nginx/nginx.conf"

    # 备份原始配置
    if [ ! -f "${nginx_conf}.bak_script" ]; then
        sudo cp "$nginx_conf" "${nginx_conf}.bak_script"
        echo "✅ 已备份原始 nginx.conf 到 ${nginx_conf}.bak_script"
    fi

    echo "正在生成 Nginx Stream SNI 分流配置..."
    local sing_box_system_config="/etc/sing-box/config.json"
    local xray_system_config="/usr/local/etc/xray/config.json"
    local nginx_sni_map_entries=""
    local sni_entry=""
    local sni_list=""
    declare -A seen_sni=()

    if command -v jq >/dev/null 2>&1 && sudo test -f "$sing_box_system_config"; then
        sni_entry=$(sudo jq -r '.inbounds[] | select(.tag == "vless-in") | .tls.server_name // empty' "$sing_box_system_config" 2>/dev/null | head -n 1)
        if [ -n "$sni_entry" ]; then
            printf -v nginx_sni_map_entries '%s        %s   sb_vless;\n' "$nginx_sni_map_entries" "$sni_entry"
            seen_sni["$sni_entry"]=1
        fi

        sni_entry=$(sudo jq -r '.inbounds[] | select(.tag == "anytls-in") | .tls.server_name // empty' "$sing_box_system_config" 2>/dev/null | head -n 1)
        if [ -n "$sni_entry" ] && [ -z "${seen_sni[$sni_entry]+x}" ]; then
            printf -v nginx_sni_map_entries '%s        %s   sb_anytls;\n' "$nginx_sni_map_entries" "$sni_entry"
            seen_sni["$sni_entry"]=1
        fi
    fi

    if command -v jq >/dev/null 2>&1 && sudo test -f "$xray_system_config"; then
        sni_list=$(sudo jq -r '.inbounds[].streamSettings.realitySettings.serverNames[]? // empty' "$xray_system_config" 2>/dev/null)
        while IFS= read -r sni_entry; do
            if [ -n "$sni_entry" ] && [ -z "${seen_sni[$sni_entry]+x}" ]; then
                printf -v nginx_sni_map_entries '%s        %s   xray_reality;\n' "$nginx_sni_map_entries" "$sni_entry"
                seen_sni["$sni_entry"]=1
            fi
        done <<< "$sni_list"
    fi

    cat <<EOF > /tmp/nginx_stream.tmp
# BEGIN FQ MANAGED STREAM
stream {
    map \$ssl_preread_server_name \$backend {
$nginx_sni_map_entries
        default         my_nginx;
    }
    upstream sb_vless {
        server [::1]:5443;
    }
    upstream sb_anytls {
        server [::1]:7443;
    }
    upstream xray_reality {
        server [::1]:6443;
    }
    upstream my_nginx {
        server [::1]:4443;
    }
    log_format basic '\$remote_addr [\$time_local] '
        '\$protocol \$status \$bytes_sent \$bytes_received '
        '\$session_time "\$upstream_addr" '
        '"\$upstream_bytes_sent" "\$upstream_bytes_received" "\$upstream_connect_time"';
    server {
        listen 443 reuseport;
        listen [::]:443 reuseport;
        proxy_pass      \$backend;
        ssl_preread     on;
        #proxy_protocol  on;
        proxy_connect_timeout 5s;
        proxy_timeout 10m;
        access_log /var/log/nginx/stream_access.log basic;
        error_log /var/log/nginx/stream_error.log;
    }
}
# END FQ MANAGED STREAM
EOF

    python3 - "$nginx_conf" /tmp/nginx_stream.tmp /tmp/nginx.conf.fq <<'PY'
import re
import sys
from pathlib import Path

config_path, stream_path, output_path = map(Path, sys.argv[1:])
config = config_path.read_text()
managed_stream = stream_path.read_text().rstrip() + "\n"
begin = "# BEGIN FQ MANAGED STREAM"
end = "# END FQ MANAGED STREAM"

if begin in config:
    start = config.index(begin)
    finish = config.index(end, start) + len(end)
    updated = config[:start] + managed_stream.rstrip() + config[finish:]
else:
    stream_match = re.search(r"(?m)^stream\s*\{", config)
    if stream_match:
        if "upstream xray_reality" not in config and "upstream sb_vless" not in config:
            raise SystemExit("检测到非本脚本管理的 stream 块，拒绝自动覆盖。")
        depth = 0
        finish = None
        for index in range(stream_match.start(), len(config)):
            if config[index] == "{":
                depth += 1
            elif config[index] == "}":
                depth -= 1
                if depth == 0:
                    finish = index + 1
                    break
        if finish is None:
            raise SystemExit("现有 stream 块括号不完整。")
        updated = config[:stream_match.start()] + managed_stream.rstrip() + config[finish:]
    else:
        http_match = re.search(r"(?m)^http\s*\{", config)
        if not http_match:
            raise SystemExit("未找到 http 块，无法插入 stream 配置。")
        updated = config[:http_match.start()] + managed_stream + "\n" + config[http_match.start():]

output_path.write_text(updated)
PY
    if [ $? -ne 0 ]; then
        rm -f /tmp/nginx_stream.tmp /tmp/nginx.conf.fq
        echo "❌ Nginx Stream 配置生成失败。"
        return 1
    fi
    sudo install -m 644 /tmp/nginx.conf.fq "$nginx_conf"
    rm -f /tmp/nginx_stream.tmp /tmp/nginx.conf.fq
    echo "✅ Nginx Stream SNI 分流配置已更新。"

    # 检查 include 命令并添加 /etc/nginx/sites-enabled/*
    sudo mkdir -p /etc/nginx/sites-enabled
    if ! grep -q "sites-enabled" "$nginx_conf"; then
        sudo sed -i '/include.*conf\.d\/\*\.conf;/a \    include \/etc\/nginx\/sites-enabled\/*;' "$nginx_conf"
    fi

    # 3. 修改 default 站点配置 (修改 sites-available 处，实际用 sites-enabled)
    local default_site="/etc/nginx/sites-enabled/default"
    echo "正在更新站点配置 $default_site ..."

    if [ ! -f "$default_site" ]; then
        sudo touch "$default_site"
    fi
    # 备份 default 文件
    sudo cp "$default_site" "$cert_dir/default_site.bak_$(date +%s)" 2>/dev/null || true

    # 写入新配置 (注意：$domain 是 Shell 变量，\$host 是 Nginx 变量)
    sudo tee "$default_site" > /dev/null <<EOF
server {
    listen 80 default_server;
    listen [::]:80 default_server;
    return 301 https://\$host\$request_uri;
}

server {
    listen 4443 ssl default_server;
    listen [::]:4443 ssl default_server;
    http2 on; # for nginx version >= 1.25.1
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_reject_handshake on; # must match server name, reject direct ip request
}
server {
    listen 4443 ssl;
    listen [::]:4443 ssl;
    http2 on;
    # change to SNI name in xray
    server_name $subdomain $domain;

    ssl_certificate /etc/letsencrypt/live/$domain/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$domain/privkey.pem;

    ssl_protocols TLSv1.2 TLSv1.3;
    # openssl x509 -in /path/to/your/certificate.crt -noout -text | grep 'Public Key Algorithm'
    # Public Key Algorithm: id-ecPublicKey   --- ECDSA
    # change \`ECDSA\` to \`RSA\` in case of RSA certificate
    ssl_ciphers ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-ECDSA-CHACHA20-POLY1305;
    ssl_prefer_server_ciphers on;

    location / {
        #proxy_set_header Host         \$host;
        #proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        add_header Strict-Transport-Security "max-age=31536000; includeSubDomains; preload" always;
        root /var/www/html;
        index index.html index.htm;
    }
}
EOF
    echo "✅ 站点配置文件已更新。"

    # 确保 /var/www/html 目录下存在 index.html
    echo "正在确保存在默认的 index.html 页面..."
    sudo mkdir -p /var/www/html
    if [ ! -f /var/www/html/index.html ]; then
        local found_index
        found_index=$(ls /var/www/html/index*.html 2>/dev/null | head -n 1)
        if [ -n "$found_index" ]; then
            sudo mv "$found_index" /var/www/html/index.html
            echo "✅ 已将 $found_index 重命名为 index.html"
        else
            sudo tee /var/www/html/index.html > /dev/null <<'EOF'
<!DOCTYPE html>
<html>
<head>
<title>Welcome to nginx!</title>
<style>
    body { width: 35em; margin: 0 auto; font-family: Tahoma, Verdana, Arial, sans-serif; }
</style>
</head>
<body>
<h1>Welcome to nginx!</h1>
<p>If you see this page, the nginx web server is successfully installed and working. Further configuration is required.</p>
</body>
</html>
EOF
            echo "✅ 已生成默认的 index.html"
        fi
    fi

    # 4. 循环检查配置并重启
    echo "---"
    echo "开始检查 Nginx 配置..."

    while true; do
        if sudo nginx -t; then
            echo "✅ Nginx 配置测试通过！"
            echo "正在重新启动 Nginx..."
            sudo systemctl restart nginx
            if [ $? -eq 0 ]; then
                echo "✅ Nginx 重启成功！"
                break
            else
                echo "❌ Nginx 重启失败，请检查 systemctl status nginx。"
                return 1
            fi
        else
            echo ""
            echo "❌ Nginx 配置检测失败！"
            read -p "是否现在手动编辑配置文件以修复错误？(y/n): " edit_choice
            if [[ "$edit_choice" =~ ^[Yy]$ ]]; then
                echo "请选择要编辑的文件:"
                echo "1) nginx.conf (Stream配置)"
                echo "2) sites-available/default (站点配置)"
                read -p "输入数字 (1 或 2): " file_choice
                if [ "$file_choice" == "1" ]; then
                    sudo vim "$nginx_conf"
                elif [ "$file_choice" == "2" ]; then
                    sudo vim "$default_site"
                else
                    echo "无效选择。"
                fi
                echo "编辑完成后，将再次进行测试..."
            else
                echo "您可以稍后手动修复脚本并重新运行。任务已终止。"
                return 1
            fi
        fi
    done
}

# ---
# 7. 交互式菜单 (非第一次运行)
# ---

# 通用 Xray 组件更新函数
update_xray_component() {
    local action="$1"  # "install" 或 "install-geodata"
    local label="$2"   # 用于日志展示的名称
    echo "正在更新 $label..."
    sudo systemctl stop xray 2>/dev/null
    if sudo bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ "$action"; then
        echo "正在启动 Xray 并检查状态..."
        sudo systemctl start xray
        sleep 2
        if sudo systemctl is-active --quiet xray; then
            echo "✅ $label 更新并启动成功！"
        else
            echo "❌ $label 更新后 Xray 启动失败，请检查配置或日志。"
        fi
    else
        echo "❌ $label 更新脚本执行失败。"
    fi
}

interactive_menu() {
    while true; do
        echo "---"
        echo "请选择要执行的操作:"
        echo "1. 安装必要的软件包并设置系统环境"
        echo "2. 申请或更新证书"
        echo "3. 添加 IPv4 支持 (WARP)"
        echo "4. 更新 Nginx 配置 (Stream & SNI 分流)"
        echo "5. 安装或更新 sing-box (VLESS + AnyTLS + Hysteria2)"
        echo "6. 单独安装 Xray VLESS Reality (备用)"
        echo "7. 更新 Xray"
        echo "8. 更新 Xray GeoData"
        echo "q. 退出"
        echo "---"

        read -p "请输入选项: " choice

        case "$choice" in
            1) install_pkgs_and_setup_env ;;
            2) apply_or_renew_cert ;;
            3) add_ipv4_by_warp ;;
            4) update_nginx_config ;;
            5)
                if install_sing_box; then
                    update_nginx_config
                fi
                ;;
            6)
                if install_xray; then
                    if [ -f "$domain_file" ]; then
                        update_nginx_config
                    fi
                fi
                ;;
            7) update_xray_component install "Xray" ;;
            8) update_xray_component install-geodata "Xray GeoData" ;;
            q|Q) break ;;
            *) echo "无效的选项，请重新输入。" ;;
        esac
        echo ""
    done
}

# ---
# 主流程
# ---
main() {
    echo "---"
    echo "欢迎使用 FQ 脚本"
    echo "---"
    read -p "是否是第一次执行流程（自动化从0到1安装）？[Y/n]: " is_first
    if [[ "$is_first" =~ ^[Yy]$ || -z "$is_first" ]]; then
        install_pkgs_and_setup_env || return 1

        echo "---"
        echo "检测 IPv4..."
        if [ "$ORIGINAL_HAS_IPV4" = "false" ]; then
            read -p "未检测到有效的 IPv4 出口，是否要给系统增加 IPv4 支持 (WARP)? [Y/n]: " add_warp
            if [[ "$add_warp" =~ ^[Yy]$ || -z "$add_warp" ]]; then
                add_ipv4_by_warp || return 1
            fi
        fi

        echo "---"
        read -p "是否有自有域名？[Y/n]: " has_domain
        if [[ "$has_domain" =~ ^[Yy]$ || -z "$has_domain" ]]; then
            echo "👉 将安装 sing-box VLESS、AnyTLS 和 Hysteria2。"
            echo "   Nginx 负责 TCP 443 的 VLESS/AnyTLS SNI 分流，Hysteria2 使用 UDP 443。"

            while true; do
                read -p "请输入子域名（例如 sub.example.com）: " full_domain
                if [ -n "$full_domain" ]; then break; fi
            done

            # 提取 domain 和 subdomain
            domain=$(echo "$full_domain" | awk -F. '{if (NF>2) { if ($0 ~ /\.(com\.cn|net\.cn|org\.cn|gov\.cn|edu\.cn|ac\.cn|eu\.org|co\.uk|org\.uk|me\.uk)$/) {print $(NF-2)"."$(NF-1)"."$NF} else {print $(NF-1)"."$NF} } else {print $0}}')
            subdomain=$full_domain
            prepare_sing_box_domains "$subdomain" || return 1
            local anytls_domain
            local hy2_domain
            anytls_domain=$(get_state_value "anytls_domain" "$sing_box_key_file")
            hy2_domain=$(get_state_value "hy2_domain" "$sing_box_key_file")

            read -p "该域名是否通过 Cloudflare 管理？[Y/n]: " is_cf
            if [[ "$is_cf" =~ ^[Yy]$ || -z "$is_cf" ]]; then
                echo "---"
                echo "将通过 Cloudflare API 自动配置以下 DNS 记录："
                echo "  $subdomain"
                echo "  $anytls_domain"
                echo "  $hy2_domain"
                local ip_v4=""
                local ip_v6=""
                if [ "$ORIGINAL_HAS_IPV4" = "true" ]; then
                    ip_v4=$(curl -4 -fsS --connect-timeout 3 --max-time 8 ip.sb 2>/dev/null || \
                        dig -4 @1.1.1.1 ch txt whoami.cloudflare +short 2>/dev/null | grep -v '^;' | tr -d '"' | head -n 1)
                    if [ -z "$ip_v4" ]; then
                        echo "❌ 已检测到原生 IPv4，但无法获取公网 IPv4 地址，拒绝修改 DNS。"
                        return 1
                    fi
                fi
                if [ "$ORIGINAL_HAS_IPV6" = "true" ]; then
                    ip_v6=$(curl -6 -fsS --connect-timeout 3 --max-time 8 ip.sb 2>/dev/null || \
                        dig -6 @2606:4700:4700::1111 ch txt whoami.cloudflare +short 2>/dev/null | grep -v '^;' | tr -d '"' | head -n 1)
                    if [ -z "$ip_v6" ]; then
                        echo "❌ 已检测到原生 IPv6，但无法获取公网 IPv6 地址，拒绝修改 DNS。"
                        return 1
                    fi
                fi
                echo "本机 IPv4: ${ip_v4:-无}"
                echo "本机 IPv6: ${ip_v6:-无}"
                echo "---"

                configure_cloudflare_dns "$domain" "$subdomain" "$ip_v4" "$ip_v6" || return 1
                apply_or_renew_cert "$subdomain" || return 1
            else
                echo "---"
                local manual_cert_domains=(-d "$domain" -d "*.$domain")
                local cert_path="/etc/letsencrypt/live/$domain/fullchain.pem"
                local cert_checksum_before=""
                cert_checksum_before=$(get_cert_checksum "$cert_path")
                echo "将使用 certbot 申请 $domain 和 *.$domain 的证书"
                sudo certbot certonly \
                    --manual \
                    --preferred-challenges dns \
                    --agree-tos \
                    --no-eff-email \
                    --cert-name "$domain" \
                    "${manual_cert_domains[@]}" || return 1
                echo "✅ 证书申请完成！"
                handle_successful_cert_update "$domain" "$cert_checksum_before" || return 1
            fi

            install_sing_box "$domain" "$subdomain" || return 1
            update_nginx_config "$domain" "$subdomain" || return 1
        else
            echo "⚠️ AnyTLS 和 Hysteria2 需要域名证书。"
            echo "👉 无自有域名时使用备用方案：Xray VLESS Reality 监听 443。"
            install_xray 443 || return 1
        fi
        echo "---"
        echo "✅ 全流程自动安装完毕。"
    else
        interactive_menu
    fi
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    case "${1:-}" in
        --renew-cert-if-needed)
            check_system
            renew_cert_if_needed "${2:-}"
            exit $?
            ;;
    esac

    check_system
    check_ipv4_status
    check_ipv6_status
    main
fi
