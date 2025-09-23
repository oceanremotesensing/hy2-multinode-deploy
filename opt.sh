#!/usr/bin/env bash
# wj - 节点优选生成器（网络调试最终版）
# 主要改进：增加调试功能，将从关键URL获取的内容保存到文件以供分析

set -o errexit
set -o pipefail
set -o nounset

# 默认配置
INSTALL_PATH="/usr/local/bin/wj"
USE_NETWORK=false
PROXY=""
CACHE_DIR="./wj_cache"
OUT_FILE=""
QUIET=false

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

# ---------- helper: usage ----------
usage() {
    cat <<EOF
Usage: $(basename "$0") [options]
Options:
  --online               允许联网（默认禁止，避免泄露机器公网 IP）
  --proxy PROXY_URL      使用代理（如 http://127.0.0.1:8080 或 socks5h://127.0.0.1:1080）
  --cache-dir DIR        本地缓存目录（默认: ./wj_cache）
  --out FILE             将生成的 vmess 链写入 FILE（默认打印到 stdout）
  --install              将此脚本安装到 $INSTALL_PATH （需要 root）
  -h|--help              显示此帮助
EOF
    exit 0
}

# ---------- parse args ----------
while [[ $# -gt 0 ]]; do
    case "$1" in
        --online) USE_NETWORK=true; shift ;;
        --proxy) PROXY="$2"; shift 2 ;;
        --cache-dir) CACHE_DIR="$2"; shift 2 ;;
        --out) OUT_FILE="$2"; shift 2 ;;
        --install) INSTALL_AFTER=1; shift ;;
        -h|--help) usage ;;
        *) echo -e "${RED}未知参数: $1${NC}"; usage ;;
    esac
done

# ---------- check deps ----------
check_deps() {
    for cmd in jq base64 grep sed mktemp shuf awk; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            echo -e "${RED}错误: 命令 '$cmd' 未找到. 请先安装它.${NC}"
            exit 1
        fi
    done
    if ! command -v curl >/dev/null 2>&1 && [ "$USE_NETWORK" = true ]; then
        echo -e "${RED}警告: 系统未安装 curl，但开启了 --online 模式. 请安装 curl 或关闭 --online.${NC}"
        exit 1
    fi
}

# ---------- network fetch with cache and optional proxy ----------
fetch() {
    local url="$1"
    local cache_key
    cache_key="$(echo -n "$url" | sed 's/[^a-zA-Z0-9]/_/g')"
    local cache_file="$CACHE_DIR/$cache_key"

    if [ -f "$cache_file" ] && [ -s "$cache_file" ]; then
        cat "$cache_file"
        return 0
    fi

    if [ "$USE_NETWORK" != true ]; then
        return 1
    fi

    local error_log; error_log=$(mktemp)
    trap 'rm -f "$error_log"' RETURN

    local curl_args=(
        --location --max-time 20 --connect-timeout 10 --retry 2 --retry-delay 3
        -A "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/117.0.0.0 Safari/537.36"
    )

    if [ -n "$PROXY" ]; then
        curl_args+=(--proxy "$PROXY")
    fi

    local output
    if ! output=$(curl --silent --show-error --fail "${curl_args[@]}" "$url" 2>"$error_log"); then
        local curl_error
        curl_error=$(<"$error_log")
        echo -e "${RED}   └ 失败. 底层网络错误: ${curl_error}${NC}" >&2
        return 1
    fi

    if [ -z "$output" ]; then
        echo -e "${RED}   └ 失败: 连接成功但服务器返回内容为空.${NC}" >&2
        return 1
    fi

    mkdir -p "$CACHE_DIR"
    printf "%s" "$output" > "$cache_file"
    echo -n "$output"
    return 0
}

# ---------- parse optimized lists (robust) ----------
get_all_optimized_ips() {
    declare -a OPTIMIZED_IP_URLS
    OPTIMIZED_IP_URLS=(
        "https://raw.gitmirror.com/badafans/better-cloudflare-ip/master/ip.txt"
        "https://cdn.jsdelivr.net/gh/badafans/better-cloudflare-ip@master/ip.txt"
        "https://api.uouin.com/cloudflare.html"
        "https://gcore.jsdelivr.net/gh/badafans/better-cloudflare-ip@master/ip.txt"
    )

    echo -e "${YELLOW}正在尝试从多个来源获取优选 IP...${NC}"

    local tmp; tmp="$(mktemp)"
    trap 'rm -f "$tmp"' RETURN
    
    declare -a ip_list=()

    for url in "${OPTIMIZED_IP_URLS[@]}"; do
        echo -e "${YELLOW} > 正在尝试: $url${NC}"
        local html
        
        # 我们对所有URL都执行fetch，但只对目标URL进行特殊调试
        if ! html=$(fetch "$url"); then
            # 即使fetch失败，如果是目标URL，我们仍要记录一下
            if [[ "$url" == "https://api.uouin.com/cloudflare.html" ]]; then
                 echo "DEBUG: fetch command for api.uouin.com failed." > debug_output.html
            fi
            continue
        fi

        # ⭐⭐ 调试代码核心 ⭐⭐
        # 如果当前URL是我们关心的那个，就把抓取到的内容保存到文件
        if [[ "$url" == "https://api.uouin.com/cloudflare.html" ]]; then
            echo "$html" > debug_output.html
            echo -e "${GREEN}   └ DEBUG: 已将从 api.uouin.com 收到的内容保存到 'debug_output.html' 文件中。${NC}"
        fi
        # ⭐⭐ 调试结束 ⭐⭐

        echo "$html" | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}(/[0-9]{1,2})?' >> "$tmp" || true

        if [ -s "$tmp" ]; then
            awk '{$1=$1};1' "$tmp" | sort -u | shuf > "${tmp}_uniq" || true
            mapfile -t ip_list < "${tmp}_uniq" || true
            if [ "${#ip_list[@]}" -gt 0 ]; then
                echo -e "${GREEN}   └ 成功: 获取到 ${#ip_list[@]} 条候选 IP.${NC}"
                break
            fi
        else
            >"$tmp"
            echo -e "${RED}   └ 失败: 未能在此来源中解析出任何IP地址.${NC}"
        fi
    done

    if [ "${#ip_list[@]}" -eq 0 ]; then
        echo -e "${RED}错误: 尝试了所有来源，但均未能成功解析出优选 IP 地址。请再次检查您的网络环境（DNS、防火墙或是否需要代理）。${NC}"
        return 1
    fi

    echo -e "${GREEN}最终成功获取 ${#ip_list[@]} 条候选 IP（已去重与随机化）。${NC}"
    return 0
}


# ---------- helper: is_ip_or_cidr ----------
is_ip_or_cidr() {
    local val="$1"
    if [[ "$val" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}(/[0-9]{1,2})?$ ]]; then
        return 0
    fi
    if [[ "$val" =~ : ]]; then
        return 0
    fi
    return 1
}

# ---------- main ----------
main() {
    check_deps

    local url_file="/etc/sing-box/url.txt"
    declare -a valid_urls valid_ps_names

    cat <<'BANNER'
==================================================
 节点优选生成器 (wj) - 网络调试最终版
 (离线优先，需联网请加 --online 或设置 --proxy)
 作者: byJoey (modified)
==================================================
BANNER

    if [ -f "$url_file" ]; then
        mapfile -t urls < "$url_file"
        for url in "${urls[@]}"; do
            [[ -z "$url" || "$url" =~ ^# ]] && continue
            decoded_json=$(echo "${url#vmess://}" | base64 -d 2>/dev/null || true)
            if [ -n "$decoded_json" ]; then
                ps=$(echo "$decoded_json" | jq -r .ps 2>/dev/null || true)
                if [ -n "$ps" ]; then
                    valid_urls+=("$url")
                    valid_ps_names+=("$ps")
                fi
            fi
        done
    fi

    local selected_url
    if [ "${#valid_urls[@]}" -gt 0 ]; then
        if [ "${#valid_urls[@]}" -eq 1 ]; then
            selected_url="${valid_urls[0]}"
            echo -e "${YELLOW}检测到只有一个有效节点, 已自动选择: ${valid_ps_names[0]}${NC}"
        else
            echo -e "${YELLOW}请选择一个节点:${NC}"
            for i in "${!valid_ps_names[@]}"; do printf "%3d) %s\n" "$((i+1))" "${valid_ps_names[$i]}"; done
            local choice
            while true; do
                read -r -p "请输入选项编号 (1-${#valid_urls[@]}): " choice
                if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le ${#valid_urls[@]} ]; then
                    selected_url="${valid_urls[$((choice-1))]}"; break
                else
                    echo -e "${RED}无效的输入, 请重试.${NC}"
                fi
            done
        fi
    else
        echo -e "${YELLOW}在 $url_file 中未找到有效节点.${NC}"
        while true; do
            read -r -p "请手动粘贴一个 vmess:// 链接: " selected_url
            if [[ "$selected_url" != vmess://* ]]; then
                echo -e "${RED}格式错误, 必须以 vmess:// 开头.${NC}"; continue
            fi
            decoded_json=$(echo "${selected_url#vmess://}" | base64 -d 2>/dev/null || true)
            if [ -z "$decoded_json" ]; then
                echo -e "${RED}无法解码链接, 请检查链接是否完整有效.${NC}"; continue
            fi
            if ! echo "$decoded_json" | jq -e .ps >/dev/null 2>&1; then
                echo -e "${RED}解码成功, 但 JSON 内容格式不正确.${NC}"; continue
            fi
            break
        done
    fi

    local base64_part="${selected_url#vmess://}"
    local original_json
    original_json=$(echo "$base64_part" | base64 -d)
    local original_ps
    original_ps=$(echo "$original_json" | jq -r .ps)

    echo -e "${GREEN}已选择: $original_ps${NC}"

    echo -e "${YELLOW}请选择要使用的 IP 地址来源:${NC}"
    echo "  1) Cloudflare 官方 (需联网)"
    echo "  2) 第三方优选IP (自动尝试多个来源, 推荐)"
    echo "  3) 本地缓存/离线模式（优先）"

    local ip_source_choice; local use_optimized_ips=false
    while true; do
        read -r -p "请输入选项编号 (1-3): " choice
        case "$choice" in
            1)
                if [ "$USE_NETWORK" != true ]; then
                    echo -e "${RED}当前为离线模式（未启用 --online），无法获取 Cloudflare 列表。请启用 --online 或准备本地缓存.${NC}"
                    continue
                fi
                cloudflare_ips=$(fetch "https://www.cloudflare.com/ips-v4") || cloudflare_ips=""
                if [ -z "$cloudflare_ips" ]; then
                    echo -e "${RED}无法获取 Cloudflare IP 列表.${NC}"
                    continue
                fi
                mapfile -t ip_list <<<"$cloudflare_ips"
                break
                ;;
            2)
                if get_all_optimized_ips; then
                    use_optimized_ips=true
                    break
                else
                    continue
                fi
                ;;
            3)
                if [ ! -d "$CACHE_DIR" ]; then
                    echo -e "${RED}缓存目录 $CACHE_DIR 不存在. 请把候选 IP 保存为文件放在该目录下 (每行一个 IP/CIDR).${NC}"
                    continue
                fi
                mapfile -t ip_list < <(find "$CACHE_DIR" -type f -maxdepth 1 -print0 | xargs -0 cat | sort -u)
                if [ "${#ip_list[@]}" -eq 0 ]; then
                    echo -e "${RED}缓存目录中未找到任何 IP 数据.${NC}"
                    continue
                fi
                echo -e "${GREEN}从本地缓存中读取到 ${#ip_list[@]} 条候选IP.${NC}"
                break
                ;;
            *) echo -e "${RED}无效选项.${NC}" ;;
        esac
    done

    if [ "${#ip_list[@]}" -eq 0 ]; then
        echo -e "${RED}未获取到任何 IP，退出.${NC}"
        exit 1
    fi

    local num_to_generate=0
    if [ "$use_optimized_ips" = true ]; then
        num_to_generate=${#ip_list[@]}
    else
        while true; do
            read -r -p "请输入您想生成的 URL 数量: " num_to_generate
            if [[ "$num_to_generate" =~ ^[0-9]+$ ]] && [ "$num_to_generate" -gt 0 ]; then break; fi
            echo -e "${RED}请输入一个有效的正整数.${NC}"
        done
    fi

    local out_buf=""
    for ((i=0; i<num_to_generate; i++)); do
        if [ "$use_optimized_ips" = true ]; then
            current_ip="${ip_list[$i]}"
        else
            idx=$((RANDOM % ${#ip_list[@]}))
            current_ip="${ip_list[$idx]}"
        fi
        
        if ! is_ip_or_cidr "$current_ip"; then
            echo -e "${YELLOW}跳过非法条目: $current_ip${NC}"
            continue
        fi
        
        ip_for_add="${current_ip%%/*}"
        new_ps="${original_ps}-优选"
        
        if [[ "$current_ip" =~ [[:space:]] ]]; then
            ip_for_add=$(echo "$current_ip" | awk '{print $1}')
            isp_name=$(echo "$current_ip" | cut -d' ' -f2-)
            new_ps="${original_ps}-优选${isp_name}"
        fi
        
        modified_json=$(echo "$original_json" | jq --arg new_add "$ip_for_add" --arg new_ps "$new_ps" '.add = $new_add | .ps = $new_ps')
        new_base64=$(printf "%s" "$modified_json" | base64 | tr -d '\n')
        out_buf+=$'vmess://'"$new_base64"$'\n'
    done

    if [ -n "$OUT_FILE" ]; then
        printf "%s" "$out_buf" > "$OUT_FILE"
        echo -e "${GREEN}生成完毕，已写入: $OUT_FILE${NC}"
    else
        echo -e "${YELLOW}生成的新节点链接如下:${NC}"
        printf "%s" "$out_buf"
        echo -e "${GREEN}共生成约 ${num_to_generate} 个链接（实际可能略少，因过滤/跳过）.${NC}"
    fi
}

# ---------- install helper (安全提示) ----------
do_install() {
    if [ "$(id -u)" -ne 0 ]; then
        echo -e "${RED}安装需要管理员权限，请以 root 或 sudo 运行: sudo bash $0 --install${NC}"
        exit 1
    fi
    echo -e "${YELLOW}注意：请先确认脚本内容无敏感信息。安装仅复制文件到 ${INSTALL_PATH} 并赋予可执行权限。${NC}"
    cp "$0" "$INSTALL_PATH"
    chmod +x "$INSTALL_PATH"
    echo -e "${GREEN}安装完成。要运行请执行: wj 或 sudo -u <user> wj${NC}"
    exit 0
}

if [[ "${INSTALL_AFTER:-}" == "1" ]]; then
    do_install
fi

main
