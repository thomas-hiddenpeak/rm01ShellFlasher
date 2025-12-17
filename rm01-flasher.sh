#!/bin/bash

# RM-01 设备完整刷机脚本
# 版本: 1.0
# 日期: 2025年10月11日
# 描述: 用于RM-01设备的三阶段刷机流程：ESP32S3 + AGX + CFE卡

set -e  # 遇到错误时退出

# ==================== 全局变量配置 ====================

# 脚本目录
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 设备配置
ESP_PORT="/dev/ttyACM0"
SERIAL_PORT="/dev/ttyACM0"
CFE_DISK="${CFE_DISK:-/dev/sdd}"  # CFE卡设备，可通过环境变量覆盖
TF_DISK="${TF_DISK:-/dev/sda}"    # TF卡设备，可通过环境变量覆盖

# L4T目录
L4T_DIR="${L4T_DIR:-/home/rm01/nvidia/nvidia_sdk/JetPack_6.2.1_Linux_JETSON_AGX_ORIN_TARGETS/Linux_for_Tegra/}"

# robOS固件配置
ROBOS_VERSION="v1.1.0"
ROBOS_URL="https://github.com/thomas-hiddenpeak/robOS/releases/download/v1.1.0/robOS-esp32s3-v1.1.0.zip"
FIRMWARE_DIR="$SCRIPT_DIR/firmware"
ROBOS_ZIP="$FIRMWARE_DIR/robOS-esp32s3-v1.1.0.zip"
ROBOS_BUILD_DIR="$FIRMWARE_DIR/build"

# 日志配置
LOG_DIR="$SCRIPT_DIR/logs"
LOG_FILE="$LOG_DIR/rm01-flasher-$(date +%Y%m%d_%H%M%S).log"

# ==================== 颜色定义 ====================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
WHITE='\033[1;37m'
NC='\033[0m' # No Color

# ==================== 日志和输出函数 ====================

# 初始化日志
init_logging() {
    mkdir -p "$LOG_DIR"
    echo "========================================" | tee "$LOG_FILE"
    echo "RM-01刷机脚本启动时间: $(date)" | tee -a "$LOG_FILE"
    echo "脚本版本: 1.0" | tee -a "$LOG_FILE"
    echo "========================================" | tee -a "$LOG_FILE"
}

# 打印带颜色的状态信息
print_status() {
    local message="$1"
    echo -e "${BLUE}[INFO]${NC} $message" | tee -a "$LOG_FILE"
}

print_success() {
    local message="$1"
    echo -e "${GREEN}[SUCCESS]${NC} $message" | tee -a "$LOG_FILE"
}

print_warning() {
    local message="$1"
    echo -e "${YELLOW}[WARNING]${NC} $message" | tee -a "$LOG_FILE"
}

print_error() {
    local message="$1"
    echo -e "${RED}[ERROR]${NC} $message" | tee -a "$LOG_FILE"
}

print_step() {
    local step="$1"
    local message="$2"
    echo -e "${PURPLE}[步骤 $step]${NC} ${WHITE}$message${NC}" | tee -a "$LOG_FILE"
}

print_separator() {
    echo "============================================" | tee -a "$LOG_FILE"
}

# ==================== 用户交互函数 ====================

# 用户确认函数
confirm_action() {
    local message="$1"
    local default="${2:-n}"
    
    if [ "$default" = "y" ]; then
        local prompt="$message (Y/n): "
    else
        local prompt="$message (y/N): "
    fi
    
    echo -e "${CYAN}$prompt${NC}"
    read -r response
    
    case "$response" in
        [yY]|[yY][eE][sS]) return 0 ;;
        [nN]|[nN][oO]) return 1 ;;
        "") [ "$default" = "y" ] && return 0 || return 1 ;;
        *) echo -e "${RED}无效输入，请输入 y 或 n${NC}"; confirm_action "$message" "$default" ;;
    esac
}

# 等待用户按键继续
wait_for_key() {
    local message="${1:-按任意键继续...}"
    echo -e "${CYAN}$message${NC}"
    read -n 1 -s
}

# ==================== 环境检查函数 ====================

# 检查是否为root用户
check_root() {
    if [[ $EUID -eq 0 ]]; then
        print_warning "检测到以root用户运行"
        if ! confirm_action "建议使用普通用户运行此脚本，是否继续？"; then
            exit 1
        fi
    fi
}

# 检查必需的工具
check_dependencies() {
    print_status "检查系统依赖..."
    
    local missing_tools=()
    local tools=("wget" "unzip" "esptool.py" "lsusb" "python3" "minicom" "e2label" "fdisk" "mkfs.ext4" "partprobe" "mkfs.fat" "git")
    
    for tool in "${tools[@]}"; do
        if ! command -v "$tool" >/dev/null 2>&1; then
            missing_tools+=("$tool")
        fi
    done
    
    if [ ${#missing_tools[@]} -gt 0 ]; then
        print_error "缺少必需的工具: ${missing_tools[*]}"
        print_status "正在尝试安装缺少的工具..."
        
        if confirm_action "是否自动安装缺少的工具？" "y"; then
            sudo apt update
            for tool in "${missing_tools[@]}"; do
                case "$tool" in
                    "esptool.py") sudo apt install -y python3-esptool ;;
                    "minicom") sudo apt install -y minicom ;;
                    "e2label"|"mkfs.ext4") sudo apt install -y e2fsprogs ;;
                    "fdisk"|"partprobe") sudo apt install -y util-linux parted ;;
                    "mkfs.fat") sudo apt install -y dosfstools ;;
                    "git") sudo apt install -y git ;;
                    *) sudo apt install -y "$tool" ;;
                esac
            done
        else
            print_error "请手动安装缺少的工具后重新运行脚本"
            exit 1
        fi
    fi
    
    print_success "所有依赖检查通过"
}

# 检查L4T环境
check_l4t_environment() {
    print_status "检查L4T环境..."
    
    if [ ! -d "$L4T_DIR" ]; then
        print_error "L4T目录不存在: $L4T_DIR"
        print_error "请确认NVIDIA JetPack SDK已正确安装"
        exit 1
    fi
    
    if [ ! -f "$L4T_DIR/flash.sh" ]; then
        print_error "flash.sh脚本不存在: $L4T_DIR/flash.sh"
        exit 1
    fi
    
    if [ ! -f "$L4T_DIR/tools/kernel_flash/l4t_initrd_flash.sh" ]; then
        print_error "l4t_initrd_flash.sh脚本不存在"
        exit 1
    fi
    
    print_success "L4T环境检查通过: $L4T_DIR"
}

# 检查设备连接
check_device_connections() {
    print_status "检查设备连接状态..."
    
    # 检查串口设备
    if [ ! -e "$ESP_PORT" ]; then
        print_warning "串口设备不存在: $ESP_PORT"
        print_status "请检查设备连接和驱动安装"
        if ! confirm_action "是否继续？（如果设备稍后连接）"; then
            exit 1
        fi
    else
        print_success "串口设备已连接: $ESP_PORT"
    fi
}

# ==================== robOS固件管理函数 ====================

# 下载robOS固件
download_robos_firmware() {
    print_step "1" "准备robOS固件"
    
    mkdir -p "$FIRMWARE_DIR"
    
    if [ -f "$ROBOS_ZIP" ]; then
        print_status "robOS固件已存在，跳过下载"
        return 0
    fi
    
    print_status "正在下载robOS固件 $ROBOS_VERSION..."
    if wget -O "$ROBOS_ZIP" "$ROBOS_URL"; then
        print_success "robOS固件下载完成"
    else
        print_error "robOS固件下载失败"
        return 1
    fi
}

# 解压robOS固件
extract_robos_firmware() {
    # 检查是否已经解压（通过检查build目录是否存在）
    if [ -d "$FIRMWARE_DIR/build" ]; then
        print_status "robOS固件已解压，跳过解压"
        return 0
    fi
    
    print_status "正在解压robOS固件..."
    if unzip -o -q "$ROBOS_ZIP" -d "$FIRMWARE_DIR"; then
        print_success "robOS固件解压完成"
        
        # 验证解压是否成功（检查关键文件）
        if [ -d "$ROBOS_BUILD_DIR" ] && [ -f "$ROBOS_BUILD_DIR/flash_args" ]; then
            print_success "固件文件验证通过"
        else
            print_error "固件解压后验证失败，缺少必要文件"
            return 1
        fi
    else
        print_error "robOS固件解压失败"
        return 1
    fi
}

# ==================== ESP32S3刷机函数 ====================

# ESP32S3刷机
flash_esp32s3() {
    print_step "2" "ESP32S3刷入robOS固件"
    print_separator
    
    if [ ! -e "$ESP_PORT" ]; then
        print_error "串口设备不存在: $ESP_PORT"
        print_status "请连接ESP32S3设备到串口"
        wait_for_key "连接完成后按任意键继续..."
        
        if [ ! -e "$ESP_PORT" ]; then
            print_error "串口设备仍然不存在，跳过ESP32S3刷机"
            return 1
        fi
    fi
    
    # 检查串口连接（ESP32S3）
    if ! check_serial_connection "$ESP_PORT"; then
        print_error "ESP32S3串口连接检查失败"
        return 1
    fi
    
    # 切换到固件的build目录
    cd "$ROBOS_BUILD_DIR"
    
    print_status "开始刷写ESP32S3固件..."
    print_status "使用参数: DIO 80MHz 16MB"
    print_status "串口: $ESP_PORT"
    
    # 用户确认擦除操作
    print_warning "⚠️  即将执行完整的Flash擦除和固件刷写："
    print_warning "  1. 擦除整个Flash存储器（清除固件、NVS、配置等）"
    print_warning "  2. 刷写新的robOS固件"
    print_warning "  3. 初始化设备参数"
    echo
    
    if ! confirm_action "确认要继续ESP32S3完整刷写流程吗？" "y"; then
        print_warning "用户取消ESP32S3刷写"
        cd "$SCRIPT_DIR"
        return 1
    fi
    
    # 步骤1: 擦除flash
    print_separator
    print_status "🧹 步骤1: 擦除ESP32S3 Flash存储器..."
    print_status "正在清除所有之前的固件、NVS数据和配置信息..."
    
    local erase_cmd="esptool.py --chip esp32s3 --port $ESP_PORT --baud 460800 erase_flash"
    print_status "执行擦除命令: $erase_cmd"
    
    if eval "$erase_cmd"; then
        print_success "✅ Flash擦除完成"
    else
        print_error "❌ Flash擦除失败"
        cd "$SCRIPT_DIR"
        return 1
    fi
    
    print_status "等待设备重启完成..."
    sleep 3
    
    # 步骤2: 刷写固件
    print_separator
    print_status "🔥 步骤2: 刷写robOS固件到ESP32S3..."
    
    # 执行esptool命令 - 使用标准的重启参数
    print_status "执行ESP32S3固件刷写(自动重启)..."
    
    if esptool.py --chip esp32s3 --port "$ESP_PORT" --baud 460800 \
        --before default_reset --after hard_reset \
        write_flash --flash_mode dio --flash_freq 80m --flash_size 16MB \
        0x0 bootloader/bootloader.bin \
        0x10000 robOS.bin \
        0x8000 partition_table/partition-table.bin; then
        print_success "🎉 ESP32S3固件刷写完成"
        print_status "完整流程: Flash擦除 ✅ → 固件刷写 ✅"
        cd "$SCRIPT_DIR"
        
        # esptool显示"Hard resetting via RTS pin..."但可能没有真正重启
        # 使用我们的专用程序确保真正的硬件重启
        print_separator
        print_status "🔄 确保ESP32S3真正重启到正常模式..."
        if [ -f "$SCRIPT_DIR/esp32s3_reset" ]; then
            if "$SCRIPT_DIR/esp32s3_reset" "$ESP_PORT"; then
                print_success "✅ ESP32S3硬件重启完成"
            else
                print_warning "⚠️  硬件重启失败"
            fi
        else
            print_warning "⚠️  重启程序不存在"
        fi
        
        print_status "⏳ 等待ESP32S3启动完成..."
        print_status "robOS固件启动和初始化中..."
        
        # 等待4秒让固件完全启动
        for i in {4..1}; do
            print_status "等待倒计时: ${i}秒..."
            sleep 1
        done
        
        # 直接进行参数初始化，因为硬件重启已经完成
        print_status "🚀 开始执行参数初始化..."
        
        # 初始化ESP32S3参数
        if initialize_esp32s3_parameters; then
            print_success "🎉 ESP32S3刷机和参数初始化全部完成！"
        else
            print_warning "⚠️  参数初始化失败"
            print_status "固件刷写已成功完成，如需重新初始化参数请使用选项3"
        fi
        
        return 0
    else
        print_error "ESP32S3固件刷写失败"
        cd "$SCRIPT_DIR"
        return 1
    fi
}

# ESP32S3参数发送函数（专用于参数初始化）
send_esp32s3_parameter() {
    local command="$1"
    local port="$2"
    local timeout="${3:-1}"
    local show_echo="${4:-false}"
    
    # 创建临时文件存储回显
    local echo_file="/tmp/esp32s3_param_$$"
    
    # 启动后台进程监听串口回显
    timeout $((timeout + 1)) cat "$port" > "$echo_file" &
    local cat_pid=$!
    
    # 等待一下确保cat进程已启动
    sleep 0.5
    
    # 发送命令到串口（添加回车换行符）
    printf "%s\r\n" "$command" > "$port" 2>/dev/null
    
    # 等待指定时间
    sleep "$timeout"
    
    # 终止cat进程
    kill $cat_pid 2>/dev/null || true
    wait $cat_pid 2>/dev/null || true
    
    # 检查是否有回显
    local success=true
    if [ -f "$echo_file" ] && [ -s "$echo_file" ]; then
        # 显示回显内容
        local echo_content=$(cat "$echo_file" | head -1 | tr -d '\r\n')
        if [ -n "$echo_content" ]; then
            # 检查是否有错误信息
            if echo "$echo_content" | grep -q -i "error\|fail\|invalid\|unknown"; then
                echo "    ❌ 错误回显: $echo_content"
                success=false
            elif [ "$show_echo" = true ]; then
                echo "    📟 回显: $echo_content"
            fi
        fi
    else
        # 对于某些命令，没有回显也是正常的
        if [ "$show_echo" = true ]; then
            case "$command" in
                *"save"*|*"enable"*|*"set"*)
                    echo "    📝 (配置命令，无回显)"
                    ;;
                *)
                    echo "    ⚪ (无回显)"
                    ;;
            esac
        fi
    fi
    
    # 清理临时文件
    rm -f "$echo_file"
    
    if [ "$success" = true ]; then
        return 0
    else
        return 1
    fi
}

# ESP32S3参数初始化
initialize_esp32s3_parameters() {
    print_step "3" "ESP32S3参数初始化"
    print_separator
    
    print_status "准备初始化ESP32S3设备参数..."
    print_warning "⚠️  此操作将配置以下参数："
    print_warning "  • 电源管理和USB复用"
    print_warning "  • 网络配置 (IP: 10.10.99.97)"
    print_warning "  • 风扇控制和温度管理"
    print_warning "  • LED灯效和颜色设置"
    echo
    
    if ! confirm_action "确认要继续ESP32S3参数初始化吗？" "y"; then
        print_warning "用户取消ESP32S3参数初始化"
        return 1
    fi
    
    # 询问是否显示详细回显
    local show_echo=false
    if confirm_action "是否显示每条命令的串口回显？（推荐用于调试）" "n"; then
        show_echo=true
        print_status "将显示详细的串口回显信息"
    else
        print_status "将以简洁模式执行（仅显示错误）"
    fi
    
    print_status "等待ESP32S3重启完成..."
    sleep 5
    
    # 设置正确的波特率（参数通信使用115200）
    print_status "设置串口波特率为115200..."
    if command -v stty >/dev/null 2>&1; then
        stty -F "$ESP_PORT" 115200 cs8 -cstopb -parenb 2>/dev/null || {
            print_warning "设置波特率失败，但继续执行"
        }
    fi
    
    print_status "开始发送初始化参数..."
    
    # 定义所有需要发送的命令
    local commands=(
        "lpmu config auto-start on"
        "usbmux lpmu"
        "usbmux save"
        "net config set ip 10.10.99.97"
        "net config set gateway 10.10.99.100"
        "net config set dns 8.8.8.8"
        "net config set dhcp_lease_hours 24"
        "net config save"
        "fan gpio 0 41 1"
        "fan enable 0 on"
        "fan set 0 75"
        "fan status"
        "temp auto"
        "fan mode 0 curve"
        "fan config curve 0 40:20 50:40 60:55 70:70 80:100"
        "fan config hysteresis 0 3.0 2000"
        "fan config save"
        "temp status"
        "fan status"
        "led touch set white"
        "led touch config save"
        "led board anim fire 40"
        "led board config save"
        "led matrix mode static"
        "led matrix image import /sdcard/matrix.json"
        "led matrix config save"
        "color enable"
        "color gamma 0.6"
        "color saturation 1.5"
        "color brightness 1.2"
        "color save"
        "reboot"
    )
    
    # 检查串口连接
    if ! check_serial_connection "$ESP_PORT"; then
        print_error "串口连接检查失败，无法进行参数初始化"
        return 1
    fi
    
    local total_commands=${#commands[@]}
    local current_command=1
    local failed_commands=()
    
    print_status "总共需要发送 $total_commands 条初始化命令"
    print_separator
    
    # 逐条发送命令
    for cmd in "${commands[@]}"; do
        print_status "[$current_command/$total_commands] 发送命令: $cmd"
        
        # 根据命令类型决定等待时间（整数秒）
        local wait_time=1
        case "$cmd" in
            "reboot")
                wait_time=4
                ;;
            *"save"*)
                wait_time=1
                ;;
            *"status"*)
                wait_time=1
                ;;
        esac
        
        # 使用专用的参数发送函数
        if send_esp32s3_parameter "$cmd" "$ESP_PORT" "$wait_time" "$show_echo"; then
            print_success "✅ 命令执行成功"
        else
            print_warning "⚠️  命令执行可能失败: $cmd"
            failed_commands+=("$cmd")
        fi
        
        # 特殊处理某些需要更长等待时间的命令
        case "$cmd" in
            "reboot")
                print_status "设备重启中，额外等待5秒..."
                sleep 5
                ;;
        esac
        
        # 命令间间隔500毫秒
        sleep 0.5
        
        ((current_command++))
        echo
    done
    
    print_separator
    
    # 总结初始化结果
    if [ ${#failed_commands[@]} -eq 0 ]; then
        print_success "🎉 所有初始化命令发送完成！"
        print_separator
        print_status "📋 ESP32S3参数配置汇总："
        print_status "  • 电源管理：自动启动已启用"
        print_status "  • USB复用：已配置为ESP32S3模式"
        print_status "  • 网络配置：IP 10.10.99.97, 网关 10.10.99.100"
        print_status "  • DNS配置：8.8.8.8, DHCP租期 24小时"
        print_status "  • 风扇控制：GPIO 41启用，转速75%，曲线模式"
        print_status "  • 温度监控：自动模式"
        print_status "  • LED触摸：白色"
        print_status "  • LED板：火焰动画效果"
        print_status "  • LED矩阵：静态模式，导入matrix.json"
        print_status "  • 颜色校正：伽马0.6，饱和度1.5，亮度1.2"
        print_status ""
        print_status "设备正在重启，请等待启动完成..."
        print_success "ESP32S3初始化完成，设备已就绪！"
        return 0
    else
        print_warning "⚠️  部分命令发送失败:"
        for failed_cmd in "${failed_commands[@]}"; do
            print_error "  - $failed_cmd"
        done
        print_status "成功发送: $((total_commands - ${#failed_commands[@]}))/$total_commands 条命令"
        print_warning "建议检查串口连接或手动发送失败的命令"
        return 1
    fi
}

# ==================== AGX刷机函数 ====================

# 检查串口连接状态
check_serial_connection() {
    local port="$1"
    
    print_status "🔍 检查串口连接状态: $port"
    
    # 检查设备文件是否存在
    if [ ! -e "$port" ]; then
        print_error "串口设备文件不存在: $port"
        return 1
    fi
    
    # 检查设备权限
    if [ ! -r "$port" ] || [ ! -w "$port" ]; then
        print_error "串口设备权限不足: $port"
        print_status "当前权限: $(ls -l $port)"
        print_status "尝试修复权限..."
        if sudo chmod 666 "$port"; then
            print_success "权限修复成功"
        else
            print_error "权限修复失败"
            return 1
        fi
    fi
    
    # 检查是否被其他进程占用
    local processes=$(lsof "$port" 2>/dev/null || true)
    if [ -n "$processes" ]; then
        print_warning "串口设备正被其他进程占用:"
        echo "$processes"
        if confirm_action "是否终止占用进程并继续？" "y"; then
            local pids=$(lsof -t "$port" 2>/dev/null || true)
            if [ -n "$pids" ]; then
                echo "$pids" | xargs -r kill 2>/dev/null || true
                sleep 1
                # 再次检查
                if lsof "$port" >/dev/null 2>&1; then
                    print_error "无法释放串口设备"
                    return 1
                else
                    print_success "串口设备已释放"
                fi
            fi
        else
            return 1
        fi
    fi
    
    # 测试串口通信
    print_status "测试串口通信..."
    if timeout 2 bash -c "echo '' > $port" 2>/dev/null; then
        print_success "串口设备可写入"
    else
        print_error "串口设备写入测试失败"
        return 1
    fi
    
    # 显示串口设备信息
    print_status "串口设备信息:"
    echo "  设备路径: $port"
    echo "  权限: $(ls -l $port | awk '{print $1, $3, $4}')"
    
    # 尝试读取设备属性
    if command -v stty >/dev/null 2>&1; then
        local stty_info=$(stty -F "$port" 2>/dev/null || echo "无法获取")
        echo "  波特率等信息: $stty_info"
    fi
    
    print_success "✅ 串口连接检查通过"
    return 0
}

# 发送串口命令并显示回显
send_serial_command_with_echo() {
    local command="$1"
    local port="$2"
    local timeout="${3:-3}"
    local skip_precheck="${4:-false}"  # 第4个参数：是否跳过预检测，默认false
    
    print_status "向串口 $port 发送命令: $command"
    
    # 创建临时文件存储回显
    local echo_file="/tmp/serial_echo_$$"
    
    print_status "📤 发送命令: $command"
    
    # 启动后台进程监听串口回显并保存到文件
    timeout $((timeout + 2)) cat "$port" > "$echo_file" &
    local cat_pid=$!
    
    # 等待一下确保cat进程已启动
    sleep 0.5
    
    # 发送命令到串口（添加回车换行符）
    printf "%s\r\n" "$command" > "$port"
    
    print_status "⏳ 等待 $timeout 秒并捕获串口回显..."
    sleep "$timeout"
    
    # 终止cat进程
    kill $cat_pid 2>/dev/null || true
    wait $cat_pid 2>/dev/null || true
    
    # 显示捕获的回显
    if [ -f "$echo_file" ] && [ -s "$echo_file" ]; then
        print_status "📺 串口回显内容:"
        echo -e "${CYAN}----------------------------------------${NC}"
        # 使用 cat -v 显示控制字符，或者使用 strings 过滤
        cat "$echo_file"
        echo -e "${CYAN}----------------------------------------${NC}"
        
        # 检查回显内容是否包含错误信息
        if grep -q -i "error\|fail\|invalid" "$echo_file"; then
            print_warning "⚠️  回显中包含错误信息，请检查"
        fi
    else
        print_warning "❌ 未捕获到串口回显"
        print_status "📋 故障排除步骤："
        print_status "1. 确认RM-01设备已通电并开机"
        print_status "2. 检查串口线缆连接是否牢固"
        print_status "3. 确认设备正在监听串口命令"
        print_status "4. 尝试手动测试串口通信"
    fi
    
    # 清理临时文件
    rm -f "$echo_file"
    
    echo # 换行
}

# 发送串口命令（原版本，用于简单命令）
send_serial_command() {
    local command="$1"
    local port="$2"
    local timeout="${3:-3}"
    
    print_status "向串口 $port 发送命令: $command"
    
    # 使用原生方式发送命令到串口（添加回车换行符）
    printf "%s\r\n" "$command" > "$port"
    
    print_status "等待 $timeout 秒..."
    sleep "$timeout"
}

# 检查NVIDIA APX设备
check_nvidia_apx() {
    print_status "检查NVIDIA APX设备..."
    
    local max_attempts=10
    local attempt=1
    
    while [ $attempt -le $max_attempts ]; do
        print_status "尝试检测NVIDIA APX设备 (第 $attempt/$max_attempts 次)"
        
        # 检查具体的设备名称："NVIDIA Corp. APX"
        local nvidia_device=$(lsusb | grep -i "NVIDIA Corp.*APX")
        if [ -n "$nvidia_device" ]; then
            print_success "检测到NVIDIA APX设备"
            print_status "设备详情: $nvidia_device"
            return 0
        fi
        
        # 兼容性检查：也检查其他可能的NVIDIA APX格式
        if lsusb | grep -i "nvidia" | grep -i "apx"; then
            print_success "检测到NVIDIA APX设备 (兼容格式)"
            lsusb | grep -i "nvidia" | grep -i "apx"
            return 0
        fi
        
        print_status "未检测到APX设备，等待1秒后重试..."
        print_status "当前USB设备列表:"
        lsusb | grep -i nvidia || print_status "  (未发现NVIDIA设备)"
        sleep 1
        ((attempt++))
    done
    
    print_warning "未检测到NVIDIA APX设备"
    print_status "完整USB设备列表:"
    lsusb
    return 1
}

# AGX刷机
flash_agx() {
    print_step "4" "AGX刷入引导镜像"
    print_separator
    
    # 详细检查串口连接
    if ! check_serial_connection "$SERIAL_PORT"; then
        print_error "串口连接检查失败，无法继续"
        print_status "请检查："
        print_status "1. 设备是否正确连接到串口"
        print_status "2. 串口驱动是否正确安装" 
        print_status "3. 用户是否有串口访问权限"
        return 1
    fi
    
    print_status "准备让设备进入Recovery模式..."
    
    local recovery_success=false
    local max_recovery_attempts=3
    local recovery_attempt=1
    
    while [ $recovery_attempt -le $max_recovery_attempts ] && [ "$recovery_success" = false ]; do
        print_status "Recovery尝试 $recovery_attempt/$max_recovery_attempts"
        print_status "即将重启ESP32S3并发送recovery命令"
        
        if confirm_action "是否配置USB多路复用器并发送 'agx recovery' 命令？" "y"; then
            print_separator
            print_status "📡 配置USB多路复用器..."
            
            # 先发送 usbmux agx 命令（跳过预检测，因为设备可能静默）
            print_status "发送 'usbmux agx' 命令"
            send_serial_command_with_echo "usbmux agx" "$SERIAL_PORT" 2 true
            sleep 1
            
            # 再发送 usbmux save 命令（跳过预检测）
            print_status "发送 'usbmux save' 命令"
            send_serial_command_with_echo "usbmux save" "$SERIAL_PORT" 2 true
            sleep 1
            
            print_status "🔄 重启ESP32S3..."
            
            # 发送重启命令
            send_serial_command "reboot" "$SERIAL_PORT" 2
            
            print_status "⏳ 等待ESP32S3重启完成 (5秒)..."
            sleep 5
            
            print_status "📡 发送recovery命令并显示串口回显:"
            
            # 发送recovery命令并显示回显
            send_serial_command_with_echo "agx recovery" "$SERIAL_PORT" 5
            
            print_separator
            print_status "请查看上面的串口回显信息"
            
            if confirm_action "recovery命令执行成功了吗？（看到正确的回显信息）" "y"; then
                recovery_success=true
                print_success "用户确认recovery命令执行成功"
                
                # 等待用户确认插入USB线缆
                print_warning "请确保已将USB-C线缆连接到设备顶部的刷机接口！"
                wait_for_key "连接完成后按任意键继续检测APX设备..."
            else
                print_warning "recovery命令似乎没有成功执行"
                ((recovery_attempt++))
                
                if [ $recovery_attempt -le $max_recovery_attempts ]; then
                    print_status "准备重新尝试recovery命令..."
                    sleep 2
                else
                    print_error "已达到最大重试次数，无法成功执行recovery命令"
                    if ! confirm_action "是否仍要继续尝试检测APX设备？"; then
                        return 1
                    fi
                fi
            fi
        else
            print_warning "用户取消发送recovery命令"
            return 1
        fi
    done
    
    # 检查recovery是否成功
    if [ "$recovery_success" = false ]; then
        print_error "Recovery命令未成功执行，无法继续刷机"
        return 1
    fi
    
    # 检查APX设备
    print_status "开始检测NVIDIA APX设备..."
    if check_nvidia_apx; then
        print_success "✅ 设备已成功进入Recovery模式，检测到APX设备"
    else
        print_error "❌ 未检测到NVIDIA APX设备，设备可能未正确进入Recovery模式"
        print_error "刷机无法继续，请检查："
        print_error "1. USB-C线缆是否正确连接到设备顶部刷机接口"
        print_error "2. 设备是否正确响应了recovery命令"
        print_error "3. 设备驱动是否正确安装"
        return 1
    fi
    
    sleep 1
    
    # 执行刷机
    print_status "🚀 开始执行AGX刷机..."
    print_status "切换到L4T目录: $L4T_DIR"
    cd "$L4T_DIR"
    
    local flash_command="sudo ./flash.sh rm01-orin nvme0n1p1"
    print_status "执行刷机命令: $flash_command"
    
    if eval "$flash_command"; then
        print_success "🎉 AGX引导镜像刷写完成"
        cd "$SCRIPT_DIR"
        return 0
    else
        print_error "❌ AGX引导镜像刷写失败"
        cd "$SCRIPT_DIR"
        return 1
    fi
}

# ==================== CFE卡初始化函数 ====================

# 获取CFE卡信息
get_cfe_card_info() {
    local disk="$CFE_DISK"
    
    print_status "🔍 检测CFE卡信息..."
    
    if [ ! -b "$disk" ]; then
        print_error "未检测到CFE卡设备: $disk"
        return 1
    fi
    
    # 获取磁盘大小(GB)
    local size_bytes=$(lsblk -b -n -o SIZE "$disk" 2>/dev/null | head -1)
    local size_gb=$((size_bytes / 1024 / 1024 / 1024))
    
    # 获取磁盘型号
    local model=$(lsblk -n -o MODEL "$disk" 2>/dev/null | head -1 | xargs)
    
    print_status "📋 CFE卡详细信息:"
    echo "  设备路径: $disk"
    echo "  磁盘大小: ${size_gb}GB"
    echo "  磁盘型号: ${model:-未知}"
    
    # 显示当前分区信息
    print_status "🗂️  当前分区信息:"
    lsblk "$disk" || echo "  无分区信息"
    
    return 0
}

# 卸载CFE卡所有分区
unmount_all_cfe_partitions() {
    local disk="$CFE_DISK"
    local cfe_device=$(basename "$CFE_DISK")
    
    print_status "🔧 卸载CFE卡所有分区..."
    
    # 获取所有相关分区
    local partitions=$(lsblk -n -o NAME "$disk" | grep -v "^${cfe_device}$" | sed 's/^/\/dev\//' || true)
    
    if [ -n "$partitions" ]; then
        echo "$partitions" | while read -r partition; do
            if mount | grep -q "$partition"; then
                print_status "卸载分区: $partition"
                sudo umount "$partition" 2>/dev/null || true
            fi
        done
    fi
    
    # 强制卸载常见分区
    for i in 1 2 3; do
        local partition="${disk}${i}"
        if mount | grep -q "$partition"; then
            print_status "强制卸载分区: $partition"
            sudo umount "$partition" 2>/dev/null || true
        fi
    done
    
    sleep 2
    print_success "所有分区已卸载"
}

# 删除CFE卡所有分区
delete_all_partitions() {
    local disk="$CFE_DISK"
    
    print_status "🗑️  删除CFE卡所有分区..."
    
    # 使用fdisk删除所有分区
    sudo fdisk "$disk" << EOF >/dev/null 2>&1
o
w
EOF
    
    # 等待设备更新
    sleep 2
    sudo partprobe "$disk" 2>/dev/null || true
    sleep 1
    
    print_success "所有分区已删除"
}

# 根据容量创建分区
create_partitions_by_size() {
    local disk="$CFE_DISK"
    local size_bytes=$(lsblk -b -n -o SIZE "$disk" 2>/dev/null | head -1)
    local size_gb=$((size_bytes / 1024 / 1024 / 1024))
    local partition_scheme=""
    
    print_status "📝 根据磁盘容量创建分区..."
    print_status "磁盘容量: ${size_gb}GB"
    
    if [ $size_gb -ge 900 ]; then
        # 1T卡：单分区 rm01rootfs (1T)
        print_status "🎯 创建1T单分区方案..."
        sudo fdisk "$disk" << EOF >/dev/null 2>&1
o
n
p
1


w
EOF
        partition_scheme="1T"
        
    elif [ $size_gb -ge 450 ]; then
        # 512G卡：三分区 rm01rootfs(128G) + rm01models(256G) + rm01app(128G)
        print_status "🎯 创建512G三分区方案..."
        sudo fdisk "$disk" << EOF >/dev/null 2>&1
o
n
p
1

+128G
n
p
2

+256G
n
p
3


w
EOF
        partition_scheme="512G"
        
    elif [ $size_gb -ge 220 ]; then
        # 256G卡：三分区 rm01rootfs(64G) + rm01models(128G) + rm01app(64G)
        print_status "🎯 创建256G三分区方案..."
        sudo fdisk "$disk" << EOF >/dev/null 2>&1
o
n
p
1

+64G
n
p
2

+128G
n
p
3


w
EOF
        partition_scheme="256G"
        
    elif [ $size_gb -ge 100 ]; then
        # 128G卡：双分区 rm01rootfs(64G) + rm01models(64G)
        print_status "🎯 创建128G双分区方案..."
        sudo fdisk "$disk" << EOF >/dev/null 2>&1
o
n
p
1

+64G
n
p
2


w
EOF
        partition_scheme="128G"
        
    else
        print_error "磁盘容量太小 (${size_gb}GB)，至少需要100GB"
        return 1
    fi
    
    # 等待设备更新
    sleep 3
    sudo partprobe "$disk" 2>/dev/null || true
    sleep 2
    
    print_success "分区创建完成 - $partition_scheme 方案"
    
    # 显示新建的分区
    print_status "📋 新建分区信息:"
    lsblk "$disk"
    
    # 通过stdout返回分区方案
    echo "$partition_scheme"
}

# 格式化分区并设置标签
format_and_label_partitions() {
    local disk="$CFE_DISK"
    local partition_scheme="$1"
    
    print_status "🎨 格式化分区并设置标签..."
    
    case "$partition_scheme" in
        "1T")
            # 单分区
            print_status "格式化 ${disk}1 为 ext4 并设置标签 rm01rootfs..."
            if sudo mkfs.ext4 -F -L "rm01rootfs" "${disk}1"; then
                print_success "${disk}1 格式化完成"
            else
                print_error "${disk}1 格式化失败"
                return 1
            fi
            ;;
        "128G")
            # 双分区
            print_status "格式化 ${disk}1 为 ext4 并设置标签 rm01rootfs..."
            if sudo mkfs.ext4 -F -L "rm01rootfs" "${disk}1"; then
                print_success "${disk}1 格式化完成"
            else
                print_error "${disk}1 格式化失败"
                return 1
            fi
            
            print_status "格式化 ${disk}2 为 ext4 并设置标签 rm01models..."
            if sudo mkfs.ext4 -F -L "rm01models" "${disk}2"; then
                print_success "${disk}2 格式化完成"
            else
                print_error "${disk}2 格式化失败"
                return 1
            fi
            ;;
        "256G")
            # 三分区 (256G方案)
            print_status "格式化 ${disk}1 为 ext4 并设置标签 rm01rootfs..."
            if sudo mkfs.ext4 -F -L "rm01rootfs" "${disk}1"; then
                print_success "${disk}1 格式化完成"
            else
                print_error "${disk}1 格式化失败"
                return 1
            fi
            
            print_status "格式化 ${disk}2 为 ext4 并设置标签 rm01models..."
            if sudo mkfs.ext4 -F -L "rm01models" "${disk}2"; then
                print_success "${disk}2 格式化完成"
            else
                print_error "${disk}2 格式化失败"
                return 1
            fi
            
            print_status "格式化 ${disk}3 为 ext4 并设置标签 rm01app..."
            if sudo mkfs.ext4 -F -L "rm01app" "${disk}3"; then
                print_success "${disk}3 格式化完成"
            else
                print_error "${disk}3 格式化失败"
                return 1
            fi
            ;;
        "512G")
            # 三分区 (512G方案)
            print_status "格式化 ${disk}1 为 ext4 并设置标签 rm01rootfs..."
            if sudo mkfs.ext4 -F -L "rm01rootfs" "${disk}1"; then
                print_success "${disk}1 格式化完成"
            else
                print_error "${disk}1 格式化失败"
                return 1
            fi
            
            print_status "格式化 ${disk}2 为 ext4 并设置标签 rm01models..."
            if sudo mkfs.ext4 -F -L "rm01models" "${disk}2"; then
                print_success "${disk}2 格式化完成"
            else
                print_error "${disk}2 格式化失败"
                return 1
            fi
            
            print_status "格式化 ${disk}3 为 ext4 并设置标签 rm01app..."
            if sudo mkfs.ext4 -F -L "rm01app" "${disk}3"; then
                print_success "${disk}3 格式化完成"
            else
                print_error "${disk}3 格式化失败"
                return 1
            fi
            ;;
        *)
            print_error "未知的分区方案: $partition_scheme"
            return 1
            ;;
    esac
    
    print_success "所有分区格式化和标签设置完成"
}

# 验证分区结果
verify_partitions() {
    local disk="$CFE_DISK"
    local partition_scheme="$1"
    
    print_status "✅ 验证分区结果..."
    
    # 等待分区表更新
    sleep 2
    sudo partprobe "$disk" 2>/dev/null || true
    sleep 1
    
    # 显示最终分区信息
    print_status "📋 最终分区表信息:"
    lsblk -f "$disk"
    
    print_separator
    
    # 详细验证每个分区的标签
    print_status "🏷️  分区标签详细验证:"
    local verification_failed=false
    local expected_labels=()
    
    # 根据分区方案设置期望的标签
    case "$partition_scheme" in
        "1T")
            expected_labels=("rm01rootfs")
            ;;
        "128G")
            expected_labels=("rm01rootfs" "rm01models")
            ;;
        "256G")
            expected_labels=("rm01rootfs" "rm01models" "rm01app")
            ;;
        "512G")
            expected_labels=("rm01rootfs" "rm01models" "rm01app")
            ;;
    esac
    
    # 验证每个分区
    for i in $(seq 1 ${#expected_labels[@]}); do
        local partition="${disk}${i}"
        local expected_label="${expected_labels[$((i-1))]}"
        
        if [ -b "$partition" ]; then
            print_status "检查分区 $partition..."
            
            # 获取实际标签
            local actual_label=$(sudo e2label "$partition" 2>/dev/null || echo "")
            local size=$(lsblk -n -o SIZE "$partition" 2>/dev/null || echo "未知")
            local fstype=$(lsblk -n -o FSTYPE "$partition" 2>/dev/null || echo "未知")
            local uuid=$(sudo blkid -s UUID -o value "$partition" 2>/dev/null || echo "未知")
            
            # 验证标签
            if [ "$actual_label" = "$expected_label" ]; then
                print_success "✅ ${partition}: 标签正确"
                echo "    期望标签: $expected_label"
                echo "    实际标签: $actual_label"
                echo "    文件系统: $fstype"
                echo "    分区大小: $size"
                echo "    UUID: $uuid"
            else
                print_error "❌ ${partition}: 标签不匹配"
                echo "    期望标签: $expected_label"
                echo "    实际标签: $actual_label"
                echo "    文件系统: $fstype"
                echo "    分区大小: $size"
                verification_failed=true
            fi
            echo
        else
            print_error "❌ 分区 $partition 不存在"
            verification_failed=true
        fi
    done
    
    print_separator
    
    # 显示完整的分区汇总
    print_status "📊 CFE卡分区汇总报告:"
    echo "  磁盘设备: $disk"
    echo "  分区方案: $partition_scheme"
    echo "  总分区数: ${#expected_labels[@]}"
    echo
    echo "  分区详情:"
    for i in $(seq 1 ${#expected_labels[@]}); do
        local partition="${disk}${i}"
        if [ -b "$partition" ]; then
            local label=$(sudo e2label "$partition" 2>/dev/null || echo "无标签")
            local size=$(lsblk -n -o SIZE "$partition" 2>/dev/null || echo "未知")
            local fstype=$(lsblk -n -o FSTYPE "$partition" 2>/dev/null || echo "未知")
            echo "    ${partition}: ${label} (${fstype}, ${size})"
        fi
    done
    
    print_separator
    
    if [ "$verification_failed" = true ]; then
        print_error "❌ CFE卡初始化验证失败！部分标签设置不正确"
        return 1
    else
        print_success "✅ CFE卡初始化验证完全成功！"
        print_success "🎉 所有分区均已正确格式化并设置标签"
        return 0
    fi
}

# CFE卡初始化主函数
initialize_cfe_card() {
    print_step "5" "CFE卡初始化 (分区/格式化)"
    print_separator
    
    # 步骤0: 确认插入卡并读取信息
    if ! get_cfe_card_info; then
        print_error "无法获取CFE卡信息，请检查卡是否正确插入"
        return 1
    fi
    
    # 用户确认
    print_warning "⚠️  CFE卡初始化将会："
    print_warning "  1. 删除CFE卡上的所有数据"
    print_warning "  2. 重新分区并格式化"
    print_warning "  3. 设置对应的分区标签"
    echo
    
    if ! confirm_action "确认要继续CFE卡初始化吗？这将删除所有数据！" "n"; then
        print_warning "用户取消CFE卡初始化"
        return 1
    fi
    
    # 步骤1: 卸载所有分区
    unmount_all_cfe_partitions
    
    # 步骤2: 删除所有分区
    delete_all_partitions
    
    # 步骤3: 根据容量创建分区
    print_status "开始创建分区..."
    local partition_output
    partition_output=$(create_partitions_by_size)
    local create_result=$?
    
    if [ $create_result -ne 0 ]; then
        print_error "分区创建失败"
        return 1
    fi
    
    # 从输出中提取分区方案（最后一行）
    local partition_scheme=$(echo "$partition_output" | tail -1)
    print_status "检测到分区方案: $partition_scheme"
    
    # 步骤4: 格式化并设置标签
    if ! format_and_label_partitions "$partition_scheme"; then
        print_error "格式化和标签设置失败"
        return 1
    fi
    
    # 步骤5: 验证结果
    if ! verify_partitions "$partition_scheme"; then
        print_error "分区验证失败"
        return 1
    fi
    
    print_separator
    print_success "🎉 CFE卡初始化完成！"
    
    return 0
}

# ==================== TF卡初始化函数 ====================

# 获取TF卡信息
get_tf_card_info() {
    local disk="${TF_DISK}1"
    
    print_status "🔍 检测TF卡信息..."
    
    if [ ! -b "$disk" ]; then
        print_error "未检测到TF卡设备: $disk"
        return 1
    fi
    
    # 获取磁盘大小(GB)
    local size_bytes=$(lsblk -b -n -o SIZE "$disk" 2>/dev/null | head -1)
    local size_gb=$((size_bytes / 1024 / 1024 / 1024))
    
    # 获取磁盘型号
    local model=$(lsblk -n -o MODEL "$disk" 2>/dev/null | head -1 | xargs)
    
    print_status "📋 TF卡详细信息:"
    echo "  设备路径: $disk"
    echo "  磁盘大小: ${size_gb}GB"
    echo "  磁盘型号: ${model:-未知}"
    
    # 显示当前分区信息
    print_status "🗂️  当前分区信息:"
    lsblk "$disk" || echo "  无分区信息"
    
    return 0
}

# 卸载TF卡所有分区
unmount_all_tf_partitions() {
    local disk="${TF_DISK}1"
    local tf_device=$(basename "$TF_DISK")
    
    print_status "🔧 卸载TF卡所有分区..."
    
    # 获取所有相关分区
    local partitions=$(lsblk -n -o NAME "$disk" | grep -v "^${tf_device}$" | sed 's/^/\/dev\//' || true)
    
    if [ -n "$partitions" ]; then
        echo "$partitions" | while read -r partition; do
            if mount | grep -q "$partition"; then
                print_status "卸载分区: $partition"
                sudo umount "$partition" 2>/dev/null || true
            fi
        done
    fi
    
    # 强制卸载常见分区
    for i in 1 2 3; do
        local partition="${disk}${i}"
        if mount | grep -q "$partition"; then
            print_status "强制卸载分区: $partition"
            sudo umount "$partition" 2>/dev/null || true
        fi
    done
    
    sleep 2
    print_success "所有TF卡分区已卸载"
}

# 删除TF卡所有分区并创建新分区
create_tf_partition() {
    local disk="$TF_DISK"
    
    print_status "🗑️  删除TF卡所有分区..."
    
    # 使用fdisk删除所有分区并创建新的fat32分区
    sudo fdisk "$disk" << EOF >/dev/null 2>&1
o
n
p
1


t
b
w
EOF
    
    # 等待设备更新
    sleep 3
    sudo partprobe "$disk" 2>/dev/null || true
    sleep 2
    
    print_success "TF卡分区创建完成"
    
    # 显示新建的分区
    print_status "📋 新建分区信息:"
    lsblk "$disk"
}

# 格式化TF卡并设置标签
format_tf_card() {
    local disk="$TF_DISK"
    local partition="${disk}1"
    
    print_status "🎨 格式化TF卡为FAT32并设置标签..."
    
    # 检查分区是否存在
    if [ ! -b "$partition" ]; then
        print_error "TF卡分区不存在: $partition"
        return 1
    fi
    
    print_status "格式化 $partition 为 FAT32 并设置标签 rm01tf..."
    if sudo mkfs.fat -F 32 -n "rm01tf" "$partition"; then
        print_success "$partition 格式化完成"
    else
        print_error "$partition 格式化失败"
        return 1
    fi
    
    print_success "TF卡格式化和标签设置完成"
}

# 下载robOS sdcard内容
download_sdcard_content() {
    local sdcard_dir="$SCRIPT_DIR/sdcard"
    local robos_repo_url="https://github.com/thomas-hiddenpeak/robOS.git"
    local temp_repo_dir="$SCRIPT_DIR/temp_robos"
    
    print_status "📥 下载robOS sdcard内容..."
    
    # 如果sdcard目录已存在，直接删除
    if [ -d "$sdcard_dir" ]; then
        print_status "发现已存在的sdcard目录，正在删除..."
        rm -rf "$sdcard_dir"
    fi
    
    # 克隆robOS仓库到临时目录
    print_status "正在克隆robOS仓库..."
    if git clone --depth 1 "$robos_repo_url" "$temp_repo_dir"; then
        print_success "robOS仓库克隆完成"
    else
        print_error "robOS仓库克隆失败"
        return 1
    fi
    
    # 检查sdcard目录是否存在
    if [ ! -d "$temp_repo_dir/sdcard" ]; then
        print_error "robOS仓库中未找到sdcard目录"
        rm -rf "$temp_repo_dir"
        return 1
    fi
    
    # 复制sdcard内容
    print_status "复制sdcard内容到本地..."
    if cp -r "$temp_repo_dir/sdcard" "$sdcard_dir"; then
        print_success "sdcard内容复制完成"
    else
        print_error "sdcard内容复制失败"
        rm -rf "$temp_repo_dir"
        return 1
    fi
    
    # 清理临时目录
    rm -rf "$temp_repo_dir"
    
    # 显示sdcard内容
    print_status "📁 sdcard目录内容:"
    ls -la "$sdcard_dir/"
    
    return 0
}

# 复制文件到TF卡
copy_files_to_tf_card() {
    local disk="$TF_DISK"
    local partition="${disk}1"
    local sdcard_dir="$SCRIPT_DIR/sdcard"
    local mount_point="/tmp/tf_mount_$$"
    
    print_status "📋 复制文件到TF卡..."
    
    # 检查sdcard目录是否存在
    if [ ! -d "$sdcard_dir" ]; then
        print_error "sdcard目录不存在: $sdcard_dir"
        return 1
    fi
    
    # 创建临时挂载点
    mkdir -p "$mount_point"
    
    # 挂载TF卡
    print_status "挂载TF卡到 $mount_point..."
    if sudo mount "$partition" "$mount_point"; then
        print_success "TF卡挂载成功"
    else
        print_error "TF卡挂载失败"
        rmdir "$mount_point"
        return 1
    fi
    
    # 复制所有文件和目录
    print_status "正在复制sdcard内容到TF卡..."
    if sudo cp -r "$sdcard_dir"/* "$mount_point"/; then
        print_success "文件复制完成"
    else
        print_error "文件复制失败"
        sudo umount "$mount_point"
        rmdir "$mount_point"
        return 1
    fi
    
    # 同步数据
    print_status "同步数据到TF卡..."
    sudo sync
    
    # 显示复制结果
    print_status "📁 TF卡内容:"
    sudo ls -la "$mount_point/"
    
    # 卸载TF卡
    print_status "卸载TF卡..."
    if sudo umount "$mount_point"; then
        print_success "TF卡安全卸载"
    else
        print_warning "TF卡卸载可能失败"
    fi
    
    # 清理挂载点
    rmdir "$mount_point"
    
    return 0
}

# 验证TF卡结果
verify_tf_card() {
    local disk="$TF_DISK"
    local partition="${disk}1"
    
    print_status "✅ 验证TF卡结果..."
    
    # 等待分区表更新
    sleep 2
    sudo partprobe "$disk" 2>/dev/null || true
    sleep 1
    
    # 显示最终分区信息
    print_status "📋 最终TF卡分区信息:"
    lsblk -f "$disk"
    
    print_separator
    
    # 检查分区标签和文件系统
    if [ -b "$partition" ]; then
        print_status "检查TF卡分区 $partition..."
        
        # 获取文件系统信息
        local fstype=$(lsblk -n -o FSTYPE "$partition" 2>/dev/null || echo "未知")
        local size=$(lsblk -n -o SIZE "$partition" 2>/dev/null || echo "未知")
        local label=$(sudo blkid -s LABEL -o value "$partition" 2>/dev/null || echo "无标签")
        local uuid=$(sudo blkid -s UUID -o value "$partition" 2>/dev/null || echo "未知")
        
        if [ "$fstype" = "vfat" ] && [ "$label" = "rm01tf" ]; then
            print_success "✅ TF卡分区验证通过"
            echo "    文件系统: $fstype"
            echo "    分区标签: $label"
            echo "    分区大小: $size"
            echo "    UUID: $uuid"
        else
            print_error "❌ TF卡分区验证失败"
            echo "    期望文件系统: vfat，实际: $fstype"
            echo "    期望标签: rm01tf，实际: $label"
            echo "    分区大小: $size"
            return 1
        fi
    else
        print_error "❌ TF卡分区不存在: $partition"
        return 1
    fi
    
    print_separator
    
    # 显示TF卡汇总报告
    print_status "📊 TF卡初始化汇总报告:"
    echo "  磁盘设备: $disk"
    echo "  分区: $partition"
    echo "  文件系统: vfat (FAT32)"
    echo "  标签: rm01tf"
    echo "  大小: $size"
    
    print_separator
    print_success "✅ TF卡初始化验证完全成功！"
    print_success "🎉 TF卡已正确格式化为FAT32并复制了所有必要文件"
    
    return 0
}

# TF卡初始化主函数
initialize_tf_card() {
    print_step "1" "TF卡初始化 (格式化/复制文件)"
    print_separator
    
    # 步骤0: 确认插入卡并读取信息
    if ! get_tf_card_info; then
        print_error "无法获取TF卡信息，请检查TF卡是否正确插入"
        return 1
    fi
    
    # 用户确认
    print_warning "⚠️  TF卡初始化将会："
    print_warning "  1. 删除TF卡上的所有数据"
    print_warning "  2. 重新分区并格式化为FAT32"
    print_warning "  3. 设置标签为rm01tf"
    print_warning "  4. 下载并复制robOS sdcard内容"
    echo
    
    if ! confirm_action "确认要继续TF卡初始化吗？这将删除所有数据！" "n"; then
        print_warning "用户取消TF卡初始化"
        return 1
    fi
    
    # 步骤1: 卸载所有分区
    unmount_all_tf_partitions
    
    # 步骤2: 删除所有分区并创建新分区
    create_tf_partition
    
    # 步骤3: 格式化并设置标签
    if ! format_tf_card; then
        print_error "TF卡格式化失败"
        return 1
    fi
    
    # 步骤4: 下载sdcard内容
    if ! download_sdcard_content; then
        print_error "下载sdcard内容失败"
        return 1
    fi
    
    # 步骤5: 复制文件到TF卡
    if ! copy_files_to_tf_card; then
        print_error "复制文件到TF卡失败"
        return 1
    fi
    
    # 步骤6: 验证结果
    if ! verify_tf_card; then
        print_error "TF卡验证失败"
        return 1
    fi
    
    print_separator
    print_success "🎉 TF卡初始化完成！已格式化为FAT32格式"
    
    return 0
}

# ==================== CFE卡刷机函数 ====================

# 卸载磁盘挂载
unmount_disk() {
    local disk="$1"
    print_status "卸载磁盘挂载: $disk"
    
    # 尝试卸载所有可能的分区
    for partition in "${disk}1" "${disk}2" "${disk}3"; do
        if mount | grep -q "$partition"; then
            print_status "卸载分区: $partition"
            sudo umount "$partition" 2>/dev/null || true
        fi
    done
    
    # 等待一下确保卸载完成
    sleep 1
}

# CFE卡刷机
flash_cfe_card() {
    print_step "6" "CFE卡刷入运行镜像"
    print_separator
    
    print_status "请连接读卡器并插入CFE卡"
    print_warning "注意: 此操作将完全擦除CFE卡上的所有数据!"
    
    if ! confirm_action "是否已连接读卡器并插入CFE卡？"; then
        print_warning "用户取消CFE卡刷机"
        return 1
    fi
    
    sleep 3
    
    # 卸载磁盘挂载
    unmount_disk "$CFE_DISK"
    
    # 切换到L4T目录
    print_status "切换到L4T目录: $L4T_DIR"
    cd "$L4T_DIR"
    
    # 提取CFE_DISK的设备名（去掉/dev/前缀）
    local cfe_device=$(basename "$CFE_DISK")
    
    # 构建刷机命令
    local flash_command="sudo ./tools/kernel_flash/l4t_initrd_flash.sh --flash-only -c tools/kernel_flash/flash_l4t_t234_nvme.xml -k APP --external-device nvme0n1p1 --direct ${cfe_device}1 rm01-orin nvme0n1p1"
    
    print_status "执行CFE卡刷机命令:"
    print_status "$flash_command"
    
    if eval "$flash_command"; then
        print_success "CFE卡运行镜像刷写完成"
        
        # 再次卸载磁盘
        unmount_disk "$CFE_DISK"
        
        # 设置磁盘标签
        print_status "设置磁盘标签..."
        if sudo e2label ${CFE_DISK}1 rm01rootfs; then
            print_success "磁盘标签设置完成: rm01rootfs"
        else
            print_warning "磁盘标签设置失败，但刷机已完成"
        fi
        
        cd "$SCRIPT_DIR"
        return 0
    else
        print_error "CFE卡运行镜像刷写失败"
        cd "$SCRIPT_DIR"
        return 1
    fi
}

# ==================== 主菜单和控制函数 ====================

# 显示主菜单
show_main_menu() {
    clear
    echo -e "${WHITE}======================================${NC}"
    echo -e "${WHITE}        RM-01 设备刷机脚本           ${NC}"
    echo -e "${WHITE}            版本 1.0                ${NC}"
    echo -e "${WHITE}======================================${NC}"
    echo
    echo -e "${CYAN}请选择要执行的操作:${NC}"
    echo
    echo -e "${GREEN}1.${NC} TF卡初始化 (格式化/复制文件)"
    echo -e "${GREEN}2.${NC} ESP32S3刷写+初始化 (robOS固件+参数配置)"
    echo -e "${GREEN}3.${NC} 仅初始化ESP32S3参数 (不刷机)"
    echo -e "${GREEN}4.${NC} 仅刷写AGX (引导镜像)"
    echo -e "${GREEN}5.${NC} CFE卡初始化 (分区/格式化)"
    echo -e "${GREEN}6.${NC} 仅刷写CFE卡 (运行镜像)"
    echo -e "${GREEN}7.${NC} 下载/更新robOS固件"
    echo -e "${GREEN}8.${NC} 检查环境和设备状态"
    echo -e "${GREEN}9.${NC} 查看日志文件"
    echo -e "${GREEN}0.${NC} 退出"
    echo
    echo -ne "${CYAN}请输入选项 [0-9]: ${NC}"
}

# 完整刷机流程
full_flash_process() {
    print_step "开始" "RM-01完整刷机流程"
    print_separator
    
    local steps_completed=0
    local total_steps=4
    
    # 步骤1: 准备固件
    if download_robos_firmware && extract_robos_firmware; then
        ((steps_completed++))
        print_success "步骤 1/$total_steps 完成: robOS固件准备就绪"
    else
        print_error "步骤 1/$total_steps 失败: robOS固件准备失败"
        return 1
    fi
    
    print_separator
    
    # 步骤2: ESP32S3刷机
    if flash_esp32s3; then
        ((steps_completed++))
        print_success "步骤 2/$total_steps 完成: ESP32S3刷机成功"
    else
        print_error "步骤 2/$total_steps 失败: ESP32S3刷机失败"
        if ! confirm_action "是否继续后续步骤？"; then
            return 1
        fi
    fi
    
    print_separator
    
    # 步骤3: AGX刷机
    if flash_agx; then
        ((steps_completed++))
        print_success "步骤 3/$total_steps 完成: AGX刷机成功"
    else
        print_error "步骤 3/$total_steps 失败: AGX刷机失败"
        if ! confirm_action "是否继续CFE卡刷机？"; then
            return 1
        fi
    fi
    
    print_separator
    
    # 步骤4: CFE卡刷机
    if flash_cfe_card; then
        ((steps_completed++))
        print_success "步骤 4/$total_steps 完成: CFE卡刷机成功"
    else
        print_error "步骤 4/$total_steps 失败: CFE卡刷机失败"
    fi
    
    print_separator
    print_success "完整刷机流程结束"
    print_status "完成步骤: $steps_completed/$total_steps"
    
    if [ $steps_completed -eq $total_steps ]; then
        print_success "🎉 所有刷机步骤都已成功完成！"
        print_status "RM-01设备刷机完成，可以开始使用了"
    else
        print_warning "⚠️  部分步骤未成功完成，请检查日志文件"
    fi
}

# 环境检查
check_environment_status() {
    print_step "检查" "环境和设备状态"
    print_separator
    
    echo -e "${WHITE}系统信息:${NC}"
    echo "操作系统: $(lsb_release -d | cut -f2)"
    echo "内核版本: $(uname -r)"
    echo "Python版本: $(python3 --version)"
    echo
    
    echo -e "${WHITE}设备连接状态:${NC}"
    if [ -e "$ESP_PORT" ]; then
        echo -e "${GREEN}✓${NC} ESP串口设备: $ESP_PORT"
    else
        echo -e "${RED}✗${NC} ESP串口设备: $ESP_PORT (未连接)"
    fi
    
    echo
    echo -e "${WHITE}USB设备列表:${NC}"
    lsusb | head -10
    
    echo
    echo -e "${WHITE}存储设备:${NC}"
    lsblk | grep -E "(sda|nvme)"
    
    echo
    echo -e "${WHITE}L4T环境:${NC}"
    if [ -d "$L4T_DIR" ]; then
        echo -e "${GREEN}✓${NC} L4T目录: $L4T_DIR"
        if [ -f "$L4T_DIR/flash.sh" ]; then
            echo -e "${GREEN}✓${NC} flash.sh: 存在"
        else
            echo -e "${RED}✗${NC} flash.sh: 不存在"
        fi
    else
        echo -e "${RED}✗${NC} L4T目录: $L4T_DIR (不存在)"
    fi
    
    echo
    echo -e "${WHITE}固件状态:${NC}"
    if [ -f "$ROBOS_ZIP" ]; then
        echo -e "${GREEN}✓${NC} robOS固件: 已下载"
        if [ -d "$ROBOS_BUILD_DIR" ]; then
            echo -e "${GREEN}✓${NC} robOS固件: 已解压"
        else
            echo -e "${YELLOW}!${NC} robOS固件: 需要解压"
        fi
    else
        echo -e "${RED}✗${NC} robOS固件: 需要下载"
    fi
}

# 查看日志
view_logs() {
    print_status "最近的日志文件:"
    ls -la "$LOG_DIR"/*.log 2>/dev/null | tail -5 || echo "没有找到日志文件"
    echo
    
    if [ -f "$LOG_FILE" ]; then
        echo -e "${CYAN}当前日志文件内容 (最后20行):${NC}"
        tail -20 "$LOG_FILE"
    fi
    
    echo
    wait_for_key
}

# ==================== 主程序 ====================

# 主程序循环
main() {
    # 初始化
    init_logging
    check_root
    check_dependencies
    check_l4t_environment
    check_device_connections
    
    print_success "初始化完成，进入交互模式"
    
    while true; do
        show_main_menu
        read -r choice
        
        case $choice in
            1)
                initialize_tf_card
                wait_for_key
                ;;
            2)
                download_robos_firmware && extract_robos_firmware && flash_esp32s3
                wait_for_key
                ;;
            3)
                initialize_esp32s3_parameters
                wait_for_key
                ;;
            4)
                flash_agx
                wait_for_key
                ;;
            5)
                initialize_cfe_card
                wait_for_key
                ;;
            6)
                flash_cfe_card
                wait_for_key
                ;;
            7)
                rm -f "$ROBOS_ZIP"
                rm -rf "$ROBOS_BUILD_DIR"
                download_robos_firmware && extract_robos_firmware
                wait_for_key
                ;;
            8)
                check_environment_status
                wait_for_key
                ;;
            9)
                view_logs
                ;;
            0)
                print_status "感谢使用RM-01刷机脚本！"
                exit 0
                ;;
            *)
                print_error "无效选择，请重新输入"
                sleep 1
                ;;
        esac
    done
}

# ==================== 脚本入口 ====================

# 捕获退出信号
trap 'print_error "脚本被中断退出"; exit 1' INT TERM

# 启动主程序
main "$@"
