#!/bin/bash
#
# Tracker服务器状态检查脚本
# 功能：检查tracker服务器的可用性和响应时间
# 用法：./tracker_check.sh [tracker列表文件|磁力链接|种子文件]
#

set -euo pipefail

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# 配置
CHECK_TIMEOUT=${CHECK_TIMEOUT:-5}
MAX_CONCURRENT_CHECKS=${MAX_CONCURRENT_CHECKS:-10}
CACHE_FILE="${HOME}/.tracker_check_cache"
CACHE_EXPIRE=3600  # 1小时

# 依赖检查
check_deps() {
    local deps=("curl" "dig" "timeout")
    local missing=()
    
    for dep in "${deps[@]}"; do
        if ! command -v "$dep" &> /dev/null; then
            missing+=("$dep")
        fi
    done
    
    if [ ${#missing[@]} -gt 0 ]; then
        echo -e "${RED}错误: 缺少依赖: ${missing[*]}${NC}"
        exit 1
    fi
}

# 打印帮助
usage() {
    cat << EOF
Tracker服务器检查工具

用法: $0 [选项] [输入]

输入可以是:
  - 磁力链接 (magnet:?xt=...)
  - .torrent文件路径
  - tracker列表文件 (每行一个tracker URL)
  - 直接传入tracker URL

选项:
  -h, --help          显示此帮助信息
  -t, --timeout N     设置检查超时时间(秒，默认: $CHECK_TIMEOUT)
  -c, --concurrent N  设置最大并发检查数(默认: $MAX_CONCURRENT_CHECKS)
  -v, --verbose       详细输出模式
  -j, --json          以JSON格式输出结果
  --no-cache          禁用缓存
  --update-list       更新tracker列表
  --test-url URL      使用特定URL测试所有tracker

示例:
  $0 ./test.torrent
  $0 "magnet:?xt=urn:btih:..."
  $0 tracker_list.txt
  $0 "http://tracker.example.com:80/announce"
  $0 --update-list
EOF
    exit 0
}

# 从磁力链接提取tracker
extract_trackers_from_magnet() {
    local magnet="$1"
    echo "$magnet" | grep -o '&tr=[^&]*' | sed 's/&tr=//g' | urldecode
}

# 从torrent文件提取tracker (需要python)
extract_trackers_from_torrent() {
    local torrent_file="$1"
    
    python3 - << EOF
import sys
import os
sys.path.append(os.path.dirname(os.path.abspath(__file__)))

try:
    import bencodepy
    
    with open("$torrent_file", 'rb') as f:
        data = bencodepy.decode(f.read())
    
    trackers = set()
    
    # 获取announce
    if b'announce' in data and data[b'announce']:
        trackers.add(data[b'announce'].decode('utf-8', errors='ignore'))
    
    # 获取announce-list
    if b'announce-list' in data:
        for group in data[b'announce-list']:
            for tracker in group:
                if tracker:
                    trackers.add(tracker.decode('utf-8', errors='ignore'))
    
    for tracker in trackers:
        if tracker.strip():
            print(tracker.strip())
            
except Exception as e:
    print(f"错误: 无法解析torrent文件: {e}", file=sys.stderr)
    exit(1)
EOF
}

# URL解码
urldecode() {
    : "${*//+/ }"
    echo -e "${_//%/\\x}"
}

# 获取tracker类型
get_tracker_type() {
    local url="$1"
    case "$url" in
        udp://*)    echo "udp" ;;
        http://*)   echo "http" ;;
        https://*)  echo "https" ;;
        ws://*)     echo "websocket" ;;
        wss://*)    echo "websocket_secure" ;;
        *)          echo "unknown" ;;
    esac
}

# 清理URL
clean_url() {
    echo "$1" | sed 's/\/$//; s/^[[:space:]]*//; s/[[:space:]]*$//'
}

# 检查单个tracker
check_tracker() {
    local tracker="$1"
    local verbose="${2:-false}"
    local test_url="${3:-}"
    
    local protocol
    local domain
    local port
    local path="/announce"
    
    # 解析URL
    if [[ "$tracker" =~ ^(udp|http|https)://([^:/]+)(:([0-9]+))?(/.*)?$ ]]; then
        protocol="${BASH_REMATCH[1]}"
        domain="${BASH_REMATCH[2]}"
        port="${BASH_REMATCH[4]}"
        [[ -n "${BASH_REMATCH[5]}" ]] && path="${BASH_REMATCH[5]}"
        
        # 设置默认端口
        if [ -z "$port" ]; then
            case "$protocol" in
                udp)    port=80 ;;
                http)   port=80 ;;
                https)  port=443 ;;
            esac
        fi
    else
        echo -e "${RED}无效的tracker URL: $tracker${NC}" >&2
        return 1
    fi
    
    local result=""
    local status="unknown"
    local response_time=""
    local error_msg=""
    
    # 检查DNS解析
    if ! host_output="$(timeout 3 dig +short "$domain" 2>/dev/null | head -1)"; then
        status="dns_failed"
        error_msg="DNS解析失败"
    elif [ -z "$host_output" ]; then
        status="dns_failed"
        error_msg="DNS无记录"
    else
        # 根据协议进行不同检查
        case "$protocol" in
            udp)
                # UDP tracker检查 (简化)
                if timeout "$CHECK_TIMEOUT" nc -z -u "$domain" "$port" 2>/dev/null; then
                    status="online"
                    response_time="$(ping -c 2 -W 2 "$domain" 2>/dev/null | tail -1 | awk -F'/' '{print $5}')"
                    [ -n "$response_time" ] && response_time="${response_time}ms"
                else
                    status="offline"
                    error_msg="UDP端口不可达"
                fi
                ;;
            
            http|https)
                # 构建测试URL
                local test_announce_url="${protocol}://${domain}:${port}${path}"
                
                # 如果是info_hash测试
                if [ -n "$test_url" ]; then
                    test_announce_url="${test_announce_url}?${test_url#*\?}"
                else
                    # 基本连接测试
                    test_announce_url="${test_announce_url}?info_hash=test&peer_id=test&port=6881&uploaded=0&downloaded=0&left=0"
                fi
                
                # HTTP tracker检查
                local start_time
                start_time=$(date +%s%3N)
                
                if curl_output="$(timeout "$CHECK_TIMEOUT" curl -s -L -w "\n%{http_code}" \
                    -H "User-Agent: qBittorrent/4.6.0" \
                    -H "Accept-Encoding: gzip" \
                    "$test_announce_url" 2>/dev/null)"; then
                    
                    local http_code
                    http_code=$(echo "$curl_output" | tail -1)
                    local response
                    response=$(echo "$curl_output" | head -n -1)
                    
                    local end_time
                    end_time=$(date +%s%3N)
                    response_time="$((end_time - start_time))ms"
                    
                    if [ "$http_code" = "200" ] || [ "$http_code" = "301" ] || [ "$http_code" = "302" ]; then
                        status="online"
                        
                        # 尝试解析响应
                        if echo "$response" | grep -q "complete\|incomplete\|interval"; then
                            error_msg=""
                        else
                            error_msg="响应格式异常"
                        fi
                    else
                        status="error"
                        error_msg="HTTP $http_code"
                    fi
                else
                    status="offline"
                    error_msg="连接超时"
                fi
                ;;
                
            *)
                status="unsupported"
                error_msg="不支持的协议"
                ;;
        esac
    fi
    
    # 输出结果
    if [ "$verbose" = "true" ]; then
        case "$status" in
            online)
                echo -e "${GREEN}✓${NC} $tracker"
                echo -e "  状态: ${GREEN}在线${NC} | 响应: ${CYAN}${response_time:-N/A}${NC}"
                [ -n "$error_msg" ] && echo -e "  警告: ${YELLOW}$error_msg${NC}"
                ;;
            offline|error|dns_failed|unsupported)
                echo -e "${RED}✗${NC} $tracker"
                echo -e "  状态: ${RED}${status^^}${NC} | 错误: ${error_msg}"
                ;;
            *)
                echo -e "${YELLOW}?${NC} $tracker"
                echo -e "  状态: ${YELLOW}未知${NC}"
                ;;
        esac
    fi
    
    # 返回结构化数据
    echo "$tracker|$status|${response_time:-}|${error_msg:-}"
}

# 更新tracker列表
update_tracker_list() {
    echo -e "${CYAN}更新tracker列表...${NC}"
    
    # 从多个来源获取tracker列表
    local temp_file
    temp_file=$(mktemp)
    
    # 来源列表
    local sources=(
        "https://raw.githubusercontent.com/ngosang/trackerslist/master/trackers_best.txt"
        "https://raw.githubusercontent.com/ngosang/trackerslist/master/trackers_all.txt"
        "https://raw.githubusercontent.com/XIU2/TrackersListCollection/master/best.txt"
        "https://raw.githubusercontent.com/XIU2/TrackersListCollection/master/all.txt"
        "https://newtrackon.com/api/live"
        "https://trackerslist.com/all.txt"
    )
    
    local count=0
    for source in "${sources[@]}"; do
        echo -n "从 ${source##*/} 获取... "
        if curl -s -L --max-time 10 "$source" >> "$temp_file" 2>/dev/null; then
            echo -e "${GREEN}成功${NC}"
            count=$((count + 1))
        else
            echo -e "${RED}失败${NC}"
        fi
    done
    
    if [ "$count" -eq 0 ]; then
        echo -e "${RED}错误: 无法从任何来源获取tracker列表${NC}"
        rm -f "$temp_file"
        return 1
    fi
    
    # 去重和清理
    local unique_count
    unique_count=$(sort -u "$temp_file" | grep -v '^$' | grep -v '^#' | wc -l)
    
    # 保存到文件
    local output_file="trackers_$(date +%Y%m%d).txt"
    sort -u "$temp_file" | grep -v '^$' | grep -v '^#' > "$output_file"
    
    rm -f "$temp_file"
    
    echo -e "${GREEN}获取完成!${NC} 共找到 ${unique_count} 个唯一的tracker"
    echo -e "已保存到: ${CYAN}${output_file}${NC}"
    
    # 测试前10个tracker
    echo -e "\n${CYAN}测试前10个tracker...${NC}"
    head -10 "$output_file" | while read -r tracker; do
        [ -n "$tracker" ] && check_tracker "$tracker" true
    done
}

# 并行检查tracker
check_trackers_parallel() {
    local trackers=("$@")
    local verbose="${VERBOSE:-false}"
    local json_output="${JSON_OUTPUT:-false}"
    local test_url="${TEST_URL:-}"
    
    local total=${#trackers[@]}
    local completed=0
    local online_count=0
    
    # JSON输出开始
    if [ "$json_output" = "true" ]; then
        echo '{"trackers": ['
    fi
    
    # 进度显示函数
    show_progress() {
        if [ "$json_output" = "false" ] && [ "$verbose" = "false" ]; then
            local percent=$((completed * 100 / total))
            printf "\r检查进度: [%-50s] %d/%d (在线: %d)" \
                "$(printf '#%.0s' $(seq 1 $((percent / 2))))" \
                "$completed" "$total" "$online_count"
        fi
    }
    
    # 初始化进度
    show_progress
    
    # 创建临时文件存储结果
    local result_file
    result_file=$(mktemp)
    
    # 并行检查
    for tracker in "${trackers[@]}"; do
        # 限制并发数
        while [ "$(jobs -r | wc -l)" -ge "$MAX_CONCURRENT_CHECKS" ]; do
            sleep 0.1
        done
        
        # 后台检查
        (check_tracker "$tracker" "$verbose" "$test_url" >> "$result_file") &
    done
    
    # 等待所有后台任务完成
    wait
    
    # 处理结果
    local results=()
    while IFS= read -r line; do
        [ -z "$line" ] && continue
        results+=("$line")
        
        IFS='|' read -r _ status _ _ <<< "$line"
        completed=$((completed + 1))
        
        if [ "$status" = "online" ]; then
            online_count=$((online_count + 1))
        fi
        
        show_progress
    done < "$result_file"
    
    # 清理临时文件
    rm -f "$result_file"
    
    # 完成进度显示
    if [ "$json_output" = "false" ] && [ "$verbose" = "false" ]; then
        echo
    fi
    
    # 输出结果
    if [ "$json_output" = "true" ]; then
        local first=true
        for result in "${results[@]}"; do
            IFS='|' read -r tracker status response_time error_msg <<< "$result"
            
            if [ "$first" = "true" ]; then
                first=false
            else
                echo ","
            fi
            
            cat << EOF
  {
    "url": "$tracker",
    "status": "$status",
    "response_time": "$response_time",
    "error": "$error_msg"
EOF
            echo -n "  }"
        done
        echo -e "\n],"
        echo "\"summary\": {"
        echo "  \"total\": $total,"
        echo "  \"online\": $online_count,"
        echo "  \"offline\": $((total - online_count)),"
        printf "  \"success_rate\": %.2f" "$(echo "scale=2; $online_count * 100 / $total" | bc)"
        echo -e "\n  }"
        echo "}"
    else
        # 统计信息
        echo -e "\n${CYAN}========== 检查完成 ==========${NC}"
        echo -e "总计:    $total 个tracker"
        echo -e "${GREEN}在线:   $online_count${NC}"
        echo -e "${RED}离线:   $((total - online_count))${NC}"
        
        if [ "$total" -gt 0 ]; then
            local success_rate
            success_rate=$(echo "scale=1; $online_count * 100 / $total" | bc)
            echo -e "在线率:  ${BLUE}${success_rate}%${NC}"
        fi
        
        # 显示最快的tracker
        if [ "$online_count" -gt 0 ]; then
            echo -e "\n${CYAN}最快tracker (前5):${NC}"
            for result in "${results[@]}"; do
                IFS='|' read -r tracker status response_time _ <<< "$result"
                if [ "$status" = "online" ] && [ -n "$response_time" ]; then
                    echo "$response_time $tracker"
                fi
            done | sort -n | head -5 | while read -r time tracker; do
                echo -e "  ${GREEN}${time}${NC} - ${tracker}"
            done
        fi
        
        # 建议
        echo -e "\n${CYAN}建议:${NC}"
        if [ "$online_count" -eq 0 ]; then
            echo -e "${RED}⚠ 所有tracker都离线，请更新tracker列表${NC}"
        elif [ "$online_count" -lt 3 ]; then
            echo -e "${YELLOW}⚠ 在线tracker较少，建议添加更多tracker${NC}"
        else
            echo -e "${GREEN}✓ tracker状态良好${NC}"
        fi
    fi
    
    return 0
}

# 主函数
main() {
    check_deps
    
    # 解析参数
    local input=""
    local verbose=false
    local json_output=false
    local no_cache=false
    local update_list=false
    local test_url=""
    
    while [ $# -gt 0 ]; do
        case "$1" in
            -h|--help)
                usage
                ;;
            -v|--verbose)
                verbose=true
                ;;
            -j|--json)
                json_output=true
                verbose=false
                ;;
            -t|--timeout)
                CHECK_TIMEOUT="$2"
                shift
                ;;
            -c|--concurrent)
                MAX_CONCURRENT_CHECKS="$2"
                shift
                ;;
            --no-cache)
                no_cache=true
                ;;
            --update-list)
                update_list=true
                ;;
            --test-url)
                test_url="$2"
                shift
                ;;
            *)
                input="$1"
                ;;
        esac
        shift
    done
    
    VERBOSE="$verbose"
    JSON_OUTPUT="$json_output"
    
    # 更新tracker列表
    if [ "$update_list" = "true" ]; then
        update_tracker_list
        return 0
    fi
    
    # 收集tracker
    local trackers=()
    
    if [ -z "$input" ]; then
        # 没有输入，使用默认tracker列表
        if [ -f "trackers.txt" ]; then
            input="trackers.txt"
        elif [ -f "$HOME/.config/trackers.txt" ]; then
            input="$HOME/.config/trackers.txt"
        else
            echo -e "${YELLOW}提示: 没有指定输入，使用内置tracker列表${NC}"
            # 内置一些常用tracker
            trackers=(
                "udp://tracker.opentrackr.org:1337/announce"
                "http://tracker.opentrackr.org:1337/announce"
                "udp://open.tracker.cl:1337/announce"
                "udp://9.rarbg.me:2710/announce"
                "http://tracker.openbittorrent.com:80/announce"
                "https://tracker.gac.today:443/announce"
            )
        fi
    fi
    
    if [ ${#trackers[@]} -eq 0 ]; then
        # 根据输入类型处理
        if [ -z "$input" ]; then
            echo -e "${RED}错误: 没有指定tracker源${NC}"
            usage
            return 1
        elif [[ "$input" =~ ^magnet: ]]; then
            echo -e "${CYAN}从磁力链接提取tracker...${NC}"
            mapfile -t trackers < <(extract_trackers_from_magnet "$input")
        elif [[ "$input" =~ \.torrent$ ]] && [ -f "$input" ]; then
            echo -e "${CYAN}从种子文件提取tracker...${NC}"
            if ! command -v python3 &> /dev/null; then
                echo -e "${RED}错误: 需要python3来解析torrent文件${NC}"
                return 1
            fi
            mapfile -t trackers < <(extract_trackers_from_torrent "$input")
        elif [[ "$input" =~ ^(http|udp|https):// ]]; then
            # 单个tracker URL
            trackers=("$input")
        elif [ -f "$input" ]; then
            # tracker列表文件
            echo -e "${CYAN}从文件读取tracker: $input${NC}"
            mapfile -t trackers < <(grep -v '^#' "$input" | grep -v '^$' | sort -u)
        else
            echo -e "${RED}错误: 无法识别的输入格式${NC}"
            usage
            return 1
        fi
    fi
    
    if [ ${#trackers[@]} -eq 0 ]; then
        echo -e "${RED}错误: 没有找到tracker${NC}"
        return 1
    fi
    
    echo -e "${CYAN}找到 ${#trackers[@]} 个tracker，开始检查...${NC}"
    echo -e "${YELLOW}超时: ${CHECK_TIMEOUT}秒 | 并发: ${MAX_CONCURRENT_CHECKS}${NC}"
    
    # 清理和去重
    local unique_trackers=()
    for tracker in "${trackers[@]}"; do
        tracker=$(clean_url "$tracker")
        [ -n "$tracker" ] && unique_trackers+=("$tracker")
    done
    
    # 去重
    mapfile -t unique_trackers < <(printf "%s\n" "${unique_trackers[@]}" | sort -u)
    
    if [ ${#unique_trackers[@]} -eq 0 ]; then
        echo -e "${RED}错误: 没有有效的tracker${NC}"
        return 1
    fi
    
    if [ ${#unique_trackers[@]} -ne ${#trackers[@]} ]; then
        echo -e "${YELLOW}去重后剩余: ${#unique_trackers[@]} 个tracker${NC}"
    fi
    
    # 检查tracker
    check_trackers_parallel "${unique_trackers[@]}"
}

# 运行主函数
if [[ "${BASH_SOURCE[0]}" = "${0}" ]]; then
    main "$@"
fi