#!/usr/bin/env bash

echo 'CONFIGURE_FAIL_1' > /tmp/configure.result


# 检查是否以root权限运行
if [ "$EUID" -ne 0 ]; then
    echo "请使用root权限运行此脚本"
    echo 'CONFIGURE_FAIL_43' > /tmp/configure.result
    exit 43
fi

echo "进行系统配置-->环境变量..."
# 彻底禁用needrestart交互式提示
sudo mkdir -p /etc/needrestart/conf.d
cat > /tmp/needrestart.conf << 'NREOF'
# 自动重启服务，不询问
$nrconf{restart} = 'a';
# 禁用内核升级提示
$nrconf{kernelhints} = -1;
# 禁用微码提示
$nrconf{ucodehints} = 0;
NREOF
sudo mv /tmp/needrestart.conf /etc/needrestart/conf.d/50-autorestart.conf
sudo rm -f /etc/needrestart/conf.d/51-keep-custom.conf

# 备选方案：如果上面不生效，直接禁用needrestart服务
sudo systemctl disable needrestart.service 2>/dev/null || true
sudo systemctl stop needrestart.service 2>/dev/null || true

# 设置所有需要的环境变量
export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a
export NEEDRESTART_SUSPEND=1
export UCF_FORCE_CONFOLD=1

# 设置主机名
sudo hostnamectl set-hostname {{FULL_DOMAIN}}
sudo sed -i 's/^127\.0\.0\.1.*/127.0.0.1 localhost {{FULL_DOMAIN}}\n{{INTERNAL_IP}} {{SUBDOMAIN}} {{FULL_DOMAIN}}/' /etc/hosts
sudo systemctl restart sshd
sudo systemctl daemon-reload
sudo systemctl restart systemd-networkd
sudo systemctl restart systemd-hostnamed

# 设置时区为东京
echo "设置系统时区为东京时间..."
timedatectl set-timezone Asia/Tokyo
date

#####################################################
# DNS和软件源修复（三层容错方案）
#####################################################

echo "==========================================="
echo "步骤1: 检测和修复DNS配置..."
echo "==========================================="

# 测试网络连通性
test_network() {
    ping -c 1 -W 5 8.8.8.8 >/dev/null 2>&1
    return $?
}

# 测试DNS解析
test_dns() {
    ping -c 1 -W 5 google.com >/dev/null 2>&1
    return $?
}

# 主方案：修复DNS
fix_dns() {
    echo "配置Google DNS..."
    # 备份原有resolv.conf
    cp /etc/resolv.conf /etc/resolv.conf.bak 2>/dev/null || true
    
    # 解除 resolv.conf 的不可变属性（上次部署可能设置了 chattr +i）
    sudo chattr -i /etc/resolv.conf 2>/dev/null || true
    
    # 检查是否是符号链接（systemd-resolved管理）
    if [ -L /etc/resolv.conf ]; then
        # 使用systemd-resolved方式配置
        mkdir -p /etc/systemd/resolved.conf.d/
        cat > /etc/systemd/resolved.conf.d/dns.conf << 'DNSEOF'
[Resolve]
DNS=8.8.8.8 8.8.4.4
FallbackDNS=1.1.1.1 1.0.0.1
DNSEOF
        systemctl restart systemd-resolved 2>/dev/null || true
    else
        # 直接修改resolv.conf
        echo "nameserver 8.8.8.8" > /etc/resolv.conf
        echo "nameserver 8.8.4.4" >> /etc/resolv.conf
        echo "nameserver 1.1.1.1" >> /etc/resolv.conf
    fi
    
    # 等待DNS生效
    sleep 3
}

# 检测并修复DNS
if ! test_network; then
    echo "网络连接异常，请检查服务器网络配置"
else
    echo "网络连接正常"
    if ! test_dns; then
        echo "DNS解析异常，正在修复..."
        fix_dns
        if test_dns; then
            echo "DNS修复成功"
        else
            echo "DNS修复失败，继续尝试..."
        fi
    else
        echo "DNS解析正常"
    fi
fi

echo "==========================================="
echo "步骤2: 检测和切换软件源..."
echo "==========================================="

# 测试软件源是否可用
test_apt_source() {
    local mirror="$1"
    timeout 10 curl -s --head "http://${mirror}/ubuntu/dists/" >/dev/null 2>&1
    return $?
}

# 切换软件源
switch_apt_source() {
    local new_mirror="$1"
    echo "切换软件源到: $new_mirror"
    # 备份原sources.list
    cp /etc/apt/sources.list /etc/apt/sources.list.bak.$(date +%Y%m%d%H%M%S)
    # 替换所有镜像源地址
    sed -i "s|http://[^/]*/ubuntu|http://${new_mirror}/ubuntu|g" /etc/apt/sources.list
    sed -i "s|https://[^/]*/ubuntu|http://${new_mirror}/ubuntu|g" /etc/apt/sources.list
}

# 备用方案：多镜像源列表（按优先级排序）
MIRRORS=(
    "archive.ubuntu.com"
    "mirrors.aliyun.com"
    "mirrors.tuna.tsinghua.edu.cn"
    "mirrors.cloud.tencent.com"
    "mirrors.163.com"
)

# 获取当前sources.list中的镜像源
CURRENT_MIRROR=$(grep -oP '(?<=http://)[^/]+(?=/ubuntu)' /etc/apt/sources.list 2>/dev/null | head -1)
if [ -z "$CURRENT_MIRROR" ]; then
    CURRENT_MIRROR=$(grep -oP '(?<=https://)[^/]+(?=/ubuntu)' /etc/apt/sources.list 2>/dev/null | head -1)
fi
echo "当前软件源: ${CURRENT_MIRROR:-未知}"

# 测试当前源是否可用
APT_SOURCE_OK=0
if [ -n "$CURRENT_MIRROR" ] && test_apt_source "$CURRENT_MIRROR"; then
    echo "当前软件源可用"
    APT_SOURCE_OK=1
else
    echo "当前软件源不可用，尝试其他镜像源..."
    
    for mirror in "${MIRRORS[@]}"; do
        echo "测试镜像源: $mirror"
        if test_apt_source "$mirror"; then
            echo "镜像源 $mirror 可用"
            switch_apt_source "$mirror"
            APT_SOURCE_OK=1
            break
        else
            echo "镜像源 $mirror 不可用"
        fi
    done
fi

# 兜底方案：无论是否成功，都继续执行
if [ $APT_SOURCE_OK -eq 0 ]; then
    echo "警告: 所有镜像源测试均失败，将使用当前配置继续尝试..."
else
    echo "软件源配置完成"
fi

echo "==========================================="
echo "步骤3: 更新软件包索引..."
echo "==========================================="

# 更新系统包索引
echo "更新系统的软件包索引信息..."
DEBIAN_FRONTEND=noninteractive sudo apt-get -y -qq update < /dev/null

# 处理未完成的配置
echo "配置未完成的软件包..."
DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a dpkg --configure -a --force-confnew

# 确保时间同步服务已安装并启用
echo "安装和配置时间同步服务..."
DEBIAN_FRONTEND=noninteractive apt-get -y -qq install systemd-timesyncd < /dev/null
systemctl enable systemd-timesyncd
systemctl start systemd-timesyncd

# 清理系统
echo "执行系统清理..."
apt-get -y -qq autoremove < /dev/null
apt-get -y -qq clean < /dev/null

# 安装必要的软件包（批量安装，大幅提升效率）
echo "安装必要的软件包..."

# 定义需要安装的包列表
PACKAGES="curl git zip unzip python3 python3-pip screen tmux software-properties-common build-essential certbot iptables-persistent"

echo "批量安装软件包: $PACKAGES"
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -q \
    --no-install-recommends \
    --allow-downgrades \
    --allow-change-held-packages \
    $PACKAGES < /dev/null

echo "软件包安装完成"

#####################################################
# 本地 DNS 缓存服务（Unbound）
# 目的：加速 PowerMTA 的 MX/A 记录查询
# 原理：本地缓存 DNS 响应，避免每次都走网络查询
#####################################################

echo "==========================================="
echo "步骤4: 安装和配置本地 DNS 缓存（Unbound）..."
echo "==========================================="

# 安装 Unbound
echo "安装 Unbound DNS 缓存服务..."
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -q unbound dns-root-data dnsutils < /dev/null

# 停止 systemd-resolved 释放 53 端口（Unbound 需要监听 53 端口）
echo "配置 DNS 服务..."
if systemctl is-active --quiet systemd-resolved; then
    echo "停止 systemd-resolved 释放 53 端口..."
    sudo systemctl stop systemd-resolved 2>/dev/null
    sudo systemctl disable systemd-resolved 2>/dev/null
fi

# 写入 Unbound 配置文件
cat > /etc/unbound/unbound.conf.d/pmta-cache.conf << 'UNBOUNDEOF'
server:
    # 监听地址和端口
    interface: 127.0.0.1
    port: 53
    do-ip6: no
    do-daemonize: no

    # 访问控制：仅允许本机
    access-control: 127.0.0.0/8 allow
    access-control: 0.0.0.0/0 refuse

    # 缓存优化（核心参数）
    msg-cache-size: 64m
    rrset-cache-size: 128m
    key-cache-size: 32m
    neg-cache-size: 16m

    # 预取：TTL 快过期时自动后台刷新，不等过期才查
    prefetch: yes
    prefetch-key: yes

    # 缓存 TTL 控制
    cache-min-ttl: 300
    cache-max-ttl: 86400
    cache-max-negative-ttl: 60

    # 并发优化
    num-threads: 2
    so-reuseport: yes
    msg-cache-slabs: 4
    rrset-cache-slabs: 4
    key-cache-slabs: 4
    infra-cache-slabs: 4

    # 性能调优
    outgoing-range: 4096
    num-queries-per-thread: 2048
    so-rcvbuf: 4m
    so-sndbuf: 4m

    # 安全设置
    hide-identity: yes
    hide-version: yes
    harden-glue: yes
    harden-dnssec-stripped: yes
    use-caps-for-id: yes

    # 根提示文件
    root-hints: /usr/share/dns/root.hints

# 上游 DNS 转发（多个上游保证可用性）
forward-zone:
    name: .
    forward-addr: 8.8.8.8
    forward-addr: 8.8.4.4
    forward-addr: 1.1.1.1
    forward-addr: 208.67.222.222
UNBOUNDEOF

# 删除可能冲突的默认配置
sudo rm -f /etc/unbound/unbound.conf.d/root-auto-trust-anchor-file.conf 2>/dev/null || true

# 检查 Unbound 配置语法
echo "验证 Unbound 配置..."
if sudo unbound-checkconf >/dev/null 2>&1; then
    echo "Unbound 配置验证通过"
else
    echo "Unbound 配置有误，尝试修复..."
    # 如果有语法错误，使用最简配置兜底
    cat > /etc/unbound/unbound.conf.d/pmta-cache.conf << 'UNBOUNDEOF2'
server:
    interface: 127.0.0.1
    port: 53
    do-ip6: no
    access-control: 127.0.0.0/8 allow
    access-control: 0.0.0.0/0 refuse
    msg-cache-size: 64m
    rrset-cache-size: 128m
    prefetch: yes
    cache-min-ttl: 300
    cache-max-ttl: 86400
    hide-identity: yes
    hide-version: yes
forward-zone:
    name: .
    forward-addr: 8.8.8.8
    forward-addr: 1.1.1.1
UNBOUNDEOF2
fi

# 启动 Unbound
echo "启动 Unbound 服务..."
sudo systemctl enable unbound 2>/dev/null
sudo systemctl restart unbound 2>/dev/null
sleep 2

# 验证 Unbound 是否正常运行
if systemctl is-active --quiet unbound; then
    echo "Unbound 服务已成功启动"
    
    # 将系统 DNS 指向本地 Unbound
    # 先解除 resolv.conf 的不可变属性（上次部署可能设置了 chattr +i）
    sudo chattr -i /etc/resolv.conf 2>/dev/null || true
    # 先删除旧的符号链接（如果 systemd-resolved 创建的）
    if [ -L /etc/resolv.conf ]; then
        sudo rm -f /etc/resolv.conf
    fi
    
    # 写入新的 resolv.conf 指向本地
    cat > /etc/resolv.conf << 'RESOLVEOF'
# DNS 由本地 Unbound 缓存服务提供
nameserver 127.0.0.1
RESOLVEOF
    
    # 防止 resolv.conf 被自动覆盖
    sudo chattr +i /etc/resolv.conf 2>/dev/null || true
    
    # 测试 DNS 解析
    if dig @127.0.0.1 google.com +short >/dev/null 2>&1; then
        echo "本地 DNS 缓存测试通过"
    elif nslookup google.com 127.0.0.1 >/dev/null 2>&1; then
        echo "本地 DNS 缓存测试通过（nslookup）"
    else
        echo "警告: 本地 DNS 测试未通过，恢复公共 DNS..."
        sudo chattr -i /etc/resolv.conf 2>/dev/null || true
        cat > /etc/resolv.conf << 'RESOLVEOF2'
nameserver 8.8.8.8
nameserver 1.1.1.1
RESOLVEOF2
        sudo chattr +i /etc/resolv.conf 2>/dev/null || true
    fi
else
    echo "警告: Unbound 启动失败，保持使用公共 DNS"
    # 确保 resolv.conf 有可用的 DNS
    if [ -L /etc/resolv.conf ]; then
        sudo rm -f /etc/resolv.conf
    fi
    sudo chattr -i /etc/resolv.conf 2>/dev/null || true
    cat > /etc/resolv.conf << 'RESOLVEOF3'
nameserver 8.8.8.8
nameserver 1.1.1.1
RESOLVEOF3
    sudo chattr +i /etc/resolv.conf 2>/dev/null || true
fi

echo "DNS 缓存配置完成"

#####################################################
# 系统内核优化（TCP/网络/文件描述符）
# 目的：提升 PowerMTA 高并发出站 SMTP 连接能力
#####################################################

echo "==========================================="
echo "步骤5: 配置系统内核优化参数..."
echo "==========================================="

# 写入 sysctl 内核优化参数
cat > /etc/sysctl.d/99-pmta-optimize.conf << 'SYSCTLEOF'
###############################################
# PowerMTA 高并发出站优化 - 内核参数
###############################################

# === TCP 连接池优化 ===
# 监听队列最大长度（高并发必须调大）
net.core.somaxconn = 65535
# SYN 队列长度（防止 SYN flood 时队列溢出）
net.ipv4.tcp_max_syn_backlog = 65535

# === 端口范围扩大（更多并发出站连接）===
# 默认 32768-60999，扩大后可用端口从 ~28000 增至 ~64000
net.ipv4.ip_local_port_range = 1024 65535

# === TIME_WAIT 优化（高并发出站必须）===
# 允许复用 TIME_WAIT 状态的端口（关键！）
net.ipv4.tcp_tw_reuse = 1
# FIN_WAIT2 超时时间（默认 60 秒，缩短加速端口回收）
net.ipv4.tcp_fin_timeout = 15

# === TCP 缓冲区优化 ===
# 接收/发送缓冲区最大值（16MB）
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
# TCP 缓冲区自动调优范围（最小/默认/最大）
net.ipv4.tcp_rmem = 4096 87380 16777216
net.ipv4.tcp_wmem = 4096 65536 16777216
# TCP 内存页面（单位为页面，不是字节）
net.ipv4.tcp_mem = 786432 1048576 1572864

# === 网络队列优化 ===
# 网卡接收队列长度
net.core.netdev_max_backlog = 65535
# 默认接收/发送缓冲区
net.core.rmem_default = 262144
net.core.wmem_default = 262144

# === 连接跟踪优化 ===
# 最大跟踪连接数（默认太小，高并发会溢出）
net.netfilter.nf_conntrack_max = 1048576
# 已建立连接的超时时间（默认 432000 即 5 天，缩短释放资源）
net.netfilter.nf_conntrack_tcp_timeout_established = 600
# TIME_WAIT 超时
net.netfilter.nf_conntrack_tcp_timeout_time_wait = 30

# === 文件描述符 ===
# 系统级最大文件描述符数（每个 SMTP 连接占 1 个 fd）
fs.file-max = 1000000

# === TCP Keepalive 优化 ===
# 空闲多久后发 keepalive 探测（默认 7200 秒，缩短及时发现死连接）
net.ipv4.tcp_keepalive_time = 300
# 探测间隔
net.ipv4.tcp_keepalive_intvl = 30
# 探测次数（超过则断开）
net.ipv4.tcp_keepalive_probes = 5
SYSCTLEOF

# 应用 sysctl 参数
echo "应用内核优化参数..."
# 先加载 nf_conntrack 模块（部分 VPS 默认未加载，否则 conntrack 参数会失败）
sudo modprobe nf_conntrack 2>/dev/null || true
# 确保重启后也自动加载 nf_conntrack
echo "nf_conntrack" | sudo tee /etc/modules-load.d/nf_conntrack.conf >/dev/null 2>&1 || true
sudo sysctl -p /etc/sysctl.d/99-pmta-optimize.conf 2>/dev/null || true
# 忽略个别参数加载失败（比如 nf_conntrack 模块未加载时）
sudo sysctl --system 2>/dev/null || true

echo "内核参数优化完成"

# 配置文件描述符限制（进程级）
echo "配置文件描述符限制..."
cat > /etc/security/limits.d/99-pmta.conf << 'LIMITSEOF'
# PowerMTA 文件描述符限制
*         soft    nofile    1000000
*         hard    nofile    1000000
root      soft    nofile    1000000
root      hard    nofile    1000000
pmta      soft    nofile    1000000
pmta      hard    nofile    1000000
LIMITSEOF

# 确保 PAM 加载 limits 模块
if ! grep -q "pam_limits.so" /etc/pam.d/common-session 2>/dev/null; then
    echo "session required pam_limits.so" >> /etc/pam.d/common-session
fi

# 同时设置 systemd 的默认文件描述符限制（影响所有 systemd 管理的服务）
sudo mkdir -p /etc/systemd/system.conf.d/
cat > /etc/systemd/system.conf.d/limits.conf << 'SYSTEMDEOF'
[Manager]
DefaultLimitNOFILE=1000000
SYSTEMDEOF

# 如果 PowerMTA 有 systemd service 文件，也追加 LimitNOFILE
PMTA_SERVICE_FILE=$(find /usr/lib/systemd/system /etc/systemd/system -name "pmta.service" 2>/dev/null | head -1)
if [ -n "$PMTA_SERVICE_FILE" ]; then
    # 创建 override 目录
    sudo mkdir -p /etc/systemd/system/pmta.service.d/
    cat > /etc/systemd/system/pmta.service.d/limits.conf << 'PMTASERVEOF'
[Service]
LimitNOFILE=1000000
PMTASERVEOF
fi

sudo systemctl daemon-reload 2>/dev/null || true

echo "文件描述符限制配置完成"
echo "系统优化全部完成"

# 清理旧的PowerMTA安装
echo "清理旧的PowerMTA安装..."
sudo rm -rf /etc/pmta/
sudo rm -rf /opt/pmta/
sudo rm -rf /var/lib/pmta/
sudo rm -rf /var/log/pmta/
sudo rm -rf /var/spool/pmta/
sudo rm -rf /root/etc/
sudo rm -rf /root/usr/
sudo rm -f /root/config
sudo rm -f /root/PowerMTA-5.0r8.deb
sudo rm -f /usr/sbin/pmta*
sudo rm -f /usr/lib/systemd/system/pmta*.service

# 下载 PowerMTA Bundle（gui/assets/bundle_pmta.txt）
BUNDLE_URL='{{BUNDLE_URL}}'
BUNDLE_SHA256='{{BUNDLE_SHA256}}'

echo "正在准备 PowerMTA 部署前的工作..."
cd /root
rm -f smtp.zip /tmp/pmta-bundle.tar.gz

DOWNLOAD_OK=0
for i in 1 2 3; do
    echo "Bundle 下载尝试 $i/3..."
    rm -f /tmp/pmta-bundle.tar.gz
    if wget -4 -q -L --timeout=120 --tries=1 -O /tmp/pmta-bundle.tar.gz "$BUNDLE_URL"; then
        if [ -s /tmp/pmta-bundle.tar.gz ]; then
            DOWNLOAD_OK=1
            break
        fi
    fi
    echo "第 $i 次下载失败"
    [ $i -lt 3 ] && sleep 3
done

if [ "$DOWNLOAD_OK" != "1" ]; then
    echo "ERROR: bundle 下载失败"
    rm -f /tmp/pmta-bundle.tar.gz
    exit 1
fi

ACTUAL_SHA256=$(sha256sum /tmp/pmta-bundle.tar.gz | awk '{print $1}')
if [ "$ACTUAL_SHA256" != "$BUNDLE_SHA256" ]; then
    echo "ERROR: bundle sha256 不匹配"
    echo "  期望: $BUNDLE_SHA256"
    echo "  实际: $ACTUAL_SHA256"
    rm -f /tmp/pmta-bundle.tar.gz
    exit 1
fi
echo "Bundle sha256 校验通过"

echo "正在部署 PowerMTA ，请稍等片刻..."
echo "正在解压 pmta-bundle..."
if ! tar -xzf /tmp/pmta-bundle.tar.gz --strip-components=1 -C /root; then
    echo "ERROR: bundle 解压失败"
    rm -f /tmp/pmta-bundle.tar.gz
    exit 1
fi
rm -f /tmp/pmta-bundle.tar.gz

echo "正在尝试安装 PowerMTA ..."
# 使用 --force-confnew 自动接受包中的配置文件，stderr 重定向隐藏 postinst 脚本警告
sudo DEBIAN_FRONTEND=noninteractive dpkg -i --force-confnew PowerMTA-5.0r8.deb 2>/dev/null

# 移动文件
mkdir -p /etc/pmta
[ -f /root/etc/pmta/license ] && sudo mv /root/etc/pmta/license /etc/pmta/license
[ -f /root/usr/sbin/pmtad ] && sudo mv /root/usr/sbin/pmtad /usr/sbin/pmtad
[ -f /root/usr/sbin/pmtahttpd ] && sudo mv /root/usr/sbin/pmtahttpd /usr/sbin/pmtahttpd

# 设置权限
sudo chmod 644 /etc/pmta/license
sudo chmod 755 /usr/sbin/pmtad
sudo chmod 755 /usr/sbin/pmtahttpd

# 删除临时文件
sudo rm -rf /root/etc/
sudo rm -rf /root/usr/
sudo rm -rf /root/config
sudo rm -rf /root/PowerMTA-5.0r8.deb
sudo rm -f /root/smtp.zip /root/Untitled /tmp/pmta-bundle.tar.gz

# 创建证书和私钥目录
mkdir -p /etc/pmta/private
mkdir -p /etc/pmta/certs

chown root:root /etc/pmta/private
chown root:root /etc/pmta/certs

chmod 755 /etc/pmta/private
chmod 755 /etc/pmta/certs

# ===== 运行与 Pickup 目录创建 =====
echo "创建 PMTA 运行与 Pickup 目录..."
mkdir -p /var/log/pmta /var/lib/pmta /var/spool/pmta/pickup /var/spool/pmta/tmp
mkdir -p /data/tasks
mkdir -p /opt/pmta-injector

# 确保 pmta 用户存在
id pmta &>/dev/null || useradd -r -s /bin/false pmta

# 设置目录权限（pmta 用户需要读写权限）
chown -R pmta:pmta /var/log/pmta /var/lib/pmta /var/spool/pmta
chmod 755 /var/log/pmta /var/lib/pmta
chmod 770 /var/spool/pmta/pickup /var/spool/pmta/tmp

echo "PMTA 目录创建完成"
# ===== 运行与 Pickup 目录创建结束 =====

# 创建DKIM私钥文件
mkdir -p /etc/pmta/private /etc/pmta/certs
base64 -d > /etc/pmta/private/{{DKIM_SELECTOR}}.{{FULL_DOMAIN}}.private.pem << 'EOFDKIM'
{{DKIM_PRIVATE_B64}}
EOFDKIM
chmod 600 /etc/pmta/private/{{DKIM_SELECTOR}}.{{FULL_DOMAIN}}.private.pem

# 创建证书文件
base64 -d > /etc/pmta/certs/fullchain_{{DOMAIN}}.pem << 'EOFFULLCHAIN'
{{TLS_FULLCHAIN_B64}}
EOFFULLCHAIN

base64 -d > /etc/pmta/certs/privkey_{{DOMAIN}}.pem << 'EOFPRIVKEY'
{{TLS_PRIVKEY_B64}}
EOFPRIVKEY

chmod 644 /etc/pmta/certs/fullchain_{{DOMAIN}}.pem
chmod 600 /etc/pmta/certs/privkey_{{DOMAIN}}.pem

# 从fullchain分离证书
sed -n '1,/-----END CERTIFICATE-----/p' /etc/pmta/certs/fullchain_{{DOMAIN}}.pem > /etc/pmta/certs/cert_{{DOMAIN}}.pem
sed -n '/-----BEGIN CERTIFICATE-----/{:a;n;/-----BEGIN CERTIFICATE-----/!p;/-----BEGIN CERTIFICATE-----/q};/-----BEGIN CERTIFICATE-----/p' /etc/pmta/certs/fullchain_{{DOMAIN}}.pem > /etc/pmta/certs/ca_{{DOMAIN}}.pem

# 创建组合文件
cat /etc/pmta/certs/privkey_{{DOMAIN}}.pem > /etc/pmta/certs/combined_{{DOMAIN}}.pem
cat /etc/pmta/certs/cert_{{DOMAIN}}.pem >> /etc/pmta/certs/combined_{{DOMAIN}}.pem

chmod 600 /etc/pmta/certs/combined_{{DOMAIN}}.pem
chmod 644 /etc/pmta/certs/ca_{{DOMAIN}}.pem

# 添加交换空间（如果不存在）
echo "检查并添加交换空间..."
if [ ! -f /swapfile ]; then
    sudo fallocate -l 2G /swapfile
    sudo chmod 600 /swapfile
    sudo mkswap /swapfile
    sudo swapon /swapfile
    if ! grep -q '/swapfile' /etc/fstab; then
        echo '/swapfile swap swap defaults 0 0' | sudo tee -a /etc/fstab
    fi
    echo "交换空间已创建"
else
    echo "交换空间已存在，跳过创建"
fi

# 创建PowerMTA配置文件
cat > /etc/pmta/config << 'EOFCONFIG'
#########################################################
# PowerMTA v5.0r8 企业级综合配置文件
# 基于官方文档 - https://serverok.in/doc/pmta/UsersGuide.html
# 包含所有高级功能和最佳实践
#########################################################

# 最基本的必需设置
spool /var/spool/pmta

# 性能优化：异步写入spool（提升注入吞吐量）
sync-msg-create false
sync-msg-update false

#########################################################
# 全局系统设置
#########################################################
# 服务器标识和基本配置
host-name {{FULL_DOMAIN}}
domain-suffix {{DOMAIN}}
postmaster postmaster@{{FULL_DOMAIN}}

# DNS 解析优化（使用本地 Unbound 缓存，查询延迟从几十毫秒降至 1 毫秒以内）
# dns-resolver-address 127.0.0.1
# DNS 解析优化：系统 resolv.conf 已指向本地 Unbound 缓存（127.0.0.1）
# PowerMTA 自动使用系统 DNS，无需额外配置

# TLS证书配置
smtp-server-tls-certificate /etc/pmta/certs/combined_{{DOMAIN}}.pem
smtp-server-tls-ca-file /etc/pmta/certs/ca_{{DOMAIN}}.pem

#########################################################
# SMTP监听器设置
# 本地 SMTP 监听（用于 pmtasendfile 和本地提交）
#########################################################
smtp-listener {{INTERNAL_IP}}:587
smtp-listener {{INTERNAL_IP}}:2525
smtp-listener 127.0.0.1:25
smtp-listener 127.0.0.1:587
smtp-listener 127.0.0.1:2525

#########################################################
# 用户认证和安全
#########################################################
<smtp-user {{EMAIL_USER}}>
    password {{EMAIL_PASS}}
</smtp-user>
<smtp-user {{SUBDOMAIN}}@{{FULL_DOMAIN}}>
    password {{EMAIL_PASS}}
</smtp-user>

#########################################################
# 源控制和访问设置
#########################################################
# 默认源配置
<source 0/0>
    allow-mailmerge no
    always-allow-relaying yes
    default-virtual-mta pmta-pool
    process-x-virtual-mta yes
    remove-received-headers true
    add-received-header false
    hide-message-source true
    log-connections yes
    log-commands yes
    allow-unencrypted-plain-auth yes
    require-auth true
    smtp-service yes
    always-allow-api-submission yes
    add-message-id-header yes
    verp-default yes
    process-x-envid yes
    process-x-job yes
    jobid-header X-Mailer-RecptId
    allow-starttls yes

    # [优化] 不保留内部跟踪头，避免暴露 PowerMTA 内部信息
    retain-x-job no
    retain-x-virtual-mta no

    # [优化] 移除可能泄露发送环境信息的头部（逗号分隔列表）
    remove-header X-Originating-IP, X-PHP-Script, X-PHP-Originating-Script, User-Agent, X-MSMail-Priority, X-MimeOLE, X-Sender, X-AntiAbuse, X-Source, X-Source-Args, X-Source-Dir
</source>

#########################################################
# Pickup 源配置（高性能注入模式），通过直接写入文件实现高吞吐量邮件发送
# 性能：可达 5,000-100,000 封/秒
#########################################################
<source {/var/spool/pmta/pickup}>
    default-virtual-mta     pmta-pool
    process-x-virtual-mta   yes
    # [重要] 保留自定义邮件头：不删除Received头、不自动添加Received头、不隐藏来源
    remove-received-headers false
    add-received-header false
    hide-message-source false
</source>

#########################################################
# 虚拟MTA配置
#########################################################
# 默认出站虚拟MTA
<virtual-mta default-outbound>
    smtp-source-host {{INTERNAL_IP}} {{FULL_DOMAIN}}
    max-smtp-out 500
</virtual-mta>

# DKIM配置
<virtual-mta pmta-vmta1>
    smtp-source-host {{INTERNAL_IP}} {{FULL_DOMAIN}}
    domain-key {{DKIM_SELECTOR}}, {{FULL_DOMAIN}}, /etc/pmta/private/{{DKIM_SELECTOR}}.{{FULL_DOMAIN}}.private.pem
    <domain *>
    dkim-sign yes
    max-msg-rate 500000000/h
    use-starttls yes
    </domain>
</virtual-mta>

# 定义一个名为"pmta-pool"的虚拟MTA池
<virtual-mta-pool pmta-pool>
    virtual-mta pmta-vmta1
</virtual-mta-pool>

#########################################################
# 域特定设置
#########################################################
# 默认域设置
<domain *>
    max-smtp-out 500
    max-msg-per-connection 9999
    max-errors-per-connection 10
    bounce-upon-no-mx yes
    bounce-upon-5xx-greeting yes
    max-connect-rate 500000000/h
    max-msg-rate 500000000/h
    use-starttls true
    require-starttls false
    ignore-8bitmime true
    smtp-421-means-mx-unavailable yes

    # 引用错误识别规则（遇到特定错误自动进入退避模式）
    smtp-pattern-list blocking-errors

    # 重试策略（渐进式间隔，匹配主流邮件商的灰名单周期）
    retry-after 10m,10m,20m,30m,1h,1h,2h,6h

    # 超过24小时还未发出则彻底放弃
    bounce-after 24h

    # 退避策略（被限速后的智能行为）
    backoff-max-msg-rate 99999999/m
    backoff-retry-after 20m
    backoff-notify ""
    backoff-to-normal-after-delivery yes
    backoff-to-normal-after 1h
</domain>

# Gmail特殊设置
<domain gmail.com>
    max-msg-per-connection 9999
    max-msg-rate 500000000/h
    max-errors-per-connection 10
    use-starttls true
    require-starttls true
    log-connections yes
    dkim-sign yes
    queue-priority 90
</domain>

<domain googlemail.com>
    max-msg-per-connection 9999
    max-msg-rate 500000000/h
    max-errors-per-connection 10
    use-starttls true
    require-starttls true
    log-connections yes
    dkim-sign yes
    queue-priority 90
</domain>

# Hotmail/Outlook/Microsoft特殊设置
<domain hotmail.com>
    max-msg-per-connection 9999
    max-msg-rate 500000000/h
    max-errors-per-connection 10
    use-starttls true
    require-starttls true
    log-connections yes
    dkim-sign yes
    queue-priority 85
</domain>

<domain outlook.com>
    max-msg-per-connection 9999
    max-msg-rate 500000000/h
    max-errors-per-connection 10
    use-starttls true
    require-starttls true
    log-connections yes
    dkim-sign yes
    queue-priority 85
</domain>

<domain live.com>
    max-msg-per-connection 9999
    max-msg-rate 500000000/h
    max-errors-per-connection 10
    use-starttls true
    require-starttls true
    log-connections yes
    dkim-sign yes
    queue-priority 85
</domain>

<domain msn.com>
    max-msg-per-connection 9999
    max-msg-rate 500000000/h
    max-errors-per-connection 10
    use-starttls true
    require-starttls true
    log-connections yes
    dkim-sign yes
    queue-priority 85
</domain>

# Yahoo特殊设置
<domain yahoo.co.jp>
    max-msg-per-connection 9999
    max-msg-rate 500000000/h
    max-errors-per-connection 10
    use-starttls true
    require-starttls false
    log-connections yes
    dkim-sign yes
    queue-priority 80
</domain>

<domain yahoo.com>
    max-msg-per-connection 9999
    max-msg-rate 500000000/h
    max-errors-per-connection 10
    use-starttls true
    require-starttls false
    log-connections yes
    dkim-sign yes
    queue-priority 80
</domain>
<domain ymail.com>
    max-msg-per-connection 9999
    max-msg-rate 500000000/h
    max-errors-per-connection 10
    use-starttls true
    require-starttls false
    log-connections yes
    dkim-sign yes
    queue-priority 80
</domain>


# AOL特殊设置
<domain aol.com>
    max-msg-per-connection 9999
    max-msg-rate 500000000/h
    max-errors-per-connection 10
    use-starttls true
    require-starttls false
    log-connections yes
    dkim-sign yes
</domain>

# Comcast特殊设置
<domain comcast.net>
    max-msg-per-connection 9999
    max-msg-rate 500000000/h
    max-errors-per-connection 10
    use-starttls true
    require-starttls false
    dkim-sign yes
</domain>
<domain xfinity.com>
    max-msg-per-connection 9999
    max-msg-rate 500000000/h
    max-errors-per-connection 10
    use-starttls true
    require-starttls false
    dkim-sign yes
</domain>

# Apple iCloud特殊设置
<domain icloud.com>
    max-msg-per-connection 9999
    max-msg-rate 500000000/h
    max-errors-per-connection 10
    use-starttls true
    require-starttls true
    dkim-sign yes
</domain>
<domain mac.com>
    max-msg-per-connection 9999
    max-msg-rate 500000000/h
    max-errors-per-connection 10
    use-starttls true
    require-starttls true
    dkim-sign yes
</domain>
<domain me.com>
    max-msg-per-connection 9999
    max-msg-rate 500000000/h
    max-errors-per-connection 10
    use-starttls true
    require-starttls true
    dkim-sign yes
</domain>

# 垃圾邮件陷阱域名 - 完全屏蔽发送
<domain spamcop.net>
    max-msg-rate 0
    bounce-upon-no-mx yes
</domain>
<domain spamhaus.org>
    max-msg-rate 0
    bounce-upon-no-mx yes
</domain>
<domain sorbs.net>
    max-msg-rate 0
    bounce-upon-no-mx yes
</domain>

# 具体域名配置
<domain {{DOMAIN}}>
    smtp-hosts [127.0.0.1]:2525
    use-starttls yes
</domain>


#########################################################
# DKIM签名配置
#########################################################
<domain-key-list dkim-keys>
    domain-key {{DKIM_SELECTOR}}, {{FULL_DOMAIN}}, /etc/pmta/private/{{DKIM_SELECTOR}}.{{FULL_DOMAIN}}.private.pem
</domain-key-list>


#########################################################
# 日志和会计设置
#########################################################
log-file /var/log/pmta/pmta.log
<acct-file /var/log/pmta/acct.csv>
    max-size 500M
    delete-after 10d
</acct-file>
<acct-file /var/log/pmta/diag.csv>
    move-interval 1d
    delete-after never
    records t
</acct-file>
# TG: delivered only (type=d). Watcher reads acct-tg-YYYY-MM-DD-NNNN.csv
# 5.0r8 rejects acct-file "header" (unknown directive) and will not start.
<acct-file /var/log/pmta/acct-tg.csv>
    max-size 100M
    move-interval 1h
    delete-after 7d
    records d
</acct-file>


#########################################################
# 监控和警报设置
#########################################################
http-mgmt-port 1983
http-access 127.0.0.1 admin
http-access 0.0.0.0/0 monitor

# 本地提交免认证
<source localhost>
    always-allow-relaying yes
    require-auth false
    allow-unencrypted-plain-auth yes
    default-virtual-mta pmta-pool
    process-x-virtual-mta yes
    # [重要] 保留自定义邮件头
    remove-received-headers false
    add-received-header false
    hide-message-source true
</source>

<source 127.0.0.1>
    always-allow-relaying yes
    require-auth false
    allow-unencrypted-plain-auth yes
    default-virtual-mta pmta-pool
    process-x-virtual-mta yes
    # [重要] 保留自定义邮件头
    remove-received-headers false
    add-received-header false
    hide-message-source true
</source>


############################################################################
# 智能错误识别规则（自动退避）
# 当目标服务器返回以下特定错误时，自动进入退避模式降速发送
############################################################################

<smtp-pattern-list blocking-errors>
    #
    # AOL 错误
    #
    reply /421 .* SERVICE NOT AVAILABLE/ mode=backoff
    reply /generating high volumes of.* complaints from AOL/ mode=backoff
    reply /554 .*aol.com/ mode=backoff
    reply /421dynt1/ mode=backoff
    reply /HVU:B1/ mode=backoff
    reply /DNS:NR/ mode=backoff
    reply /RLY:NW/ mode=backoff
    reply /DYN:T1/ mode=backoff
    reply /RLY:BD/ mode=backoff
    reply /RLY:CH2/ mode=backoff
    #
    # Yahoo 错误
    #
    reply /421 .* Please try again later/ mode=backoff
    reply /421 Message temporarily deferred/ mode=backoff
    reply /VS3-IP5 Excessive unknown recipients/ mode=backoff
    reply /VSS-IP Excessive unknown recipients/ mode=backoff
    reply /\[GL01\] Message from/ mode=backoff
    reply /\[TS01\] Messages from/ mode=backoff
    reply /\[TS02\] Messages from/ mode=backoff
    reply /\[TS03\] All messages from/ mode=backoff
    #
    # Hotmail/Outlook/Microsoft 错误
    #
    reply /exceeded the rate limit/ mode=backoff
    reply /exceeded the connection limit/ mode=backoff
    reply /Mail rejected by Windows Live Hotmail for policy reasons/ mode=backoff
    reply /mail.live.com\/mail\/troubleshooting.aspx/ mode=backoff
    #
    # Adelphia 错误
    #
    reply /421 Message Rejected/ mode=backoff
    reply /Client host rejected/ mode=backoff
    reply /blocked using UCEProtect/ mode=backoff
    #
    # Road Runner 错误
    #
    reply /Mail Refused/ mode=backoff
    reply /421 Exceeded allowable connection time/ mode=backoff
    reply /amIBlockedByRR/ mode=backoff
    reply /block-lookup/ mode=backoff
    reply /Too many concurrent connections from source IP/ mode=backoff
    #
    # 通用错误
    #
    reply /too many/ mode=backoff
    reply /Exceeded allowable connection time/ mode=backoff
    reply /Connection rate limit exceeded/ mode=backoff
    reply /refused your connection/ mode=backoff
    reply /try again later/ mode=backoff
    reply /try later/ mode=backoff
    reply /550 RBL/ mode=backoff
    reply /TDC internal RBL/ mode=backoff
    reply /connection refused/ mode=backoff
    reply /please see www.spamhaus.org/ mode=backoff
    reply /Message Rejected/ mode=backoff
    reply /refused by antispam/ mode=backoff
    reply /Service not available/ mode=backoff
    reply /currently blocked/ mode=backoff
    reply /locally blacklisted/ mode=backoff
    reply /not currently accepting mail from your ip/ mode=backoff
    reply /421.*closing connection/ mode=backoff
    reply /421.*Lost connection/ mode=backoff
    reply /476 connections from your host are denied/ mode=backoff
    reply /421 Connection cannot be established/ mode=backoff
    reply /421 temporary envelope failure/ mode=backoff
    reply /421 4.4.2 Timeout while waiting for command/ mode=backoff
    reply /450 Requested action aborted/ mode=backoff
    reply /550 Access denied/ mode=backoff
    reply /421rlynw/ mode=backoff
    reply /permanently deferred/ mode=backoff
    reply /\d+\.\d+\.\d+\.\d+ blocked/ mode=backoff
    reply /Excessive unknown recipients - possible Open Relay/ mode=backoff
    reply /^421 .* too many errors/ mode=backoff
    reply /blocked.*spamhaus/ mode=backoff
    reply /451 Rejected/ mode=backoff
    #
    # QQ 邮箱错误
    #
    reply /550 Mailbox unavailable or access denied/ mode=backoff
    reply /550 Connection frequency limited/ mode=backoff
    reply /550 Ip frequency limited/ mode=backoff
    reply /550 Domain frequency limited/ mode=backoff
    reply /550 Connection denied/ mode=backoff
    reply /550 Sender frequency limited/ mode=backoff
    reply /550 Mail content denied./ mode=backoff
    reply /550 Mail is rejected by recipients./ mode=backoff
    reply /550 Suspected spam ip/ mode=backoff
    #
    # 163 邮箱错误
    #
    reply /554 DT:SPM 163/ mode=backoff
    #
    # 新浪邮箱错误
    #
    reply /554 Rejected due to the sending MTA's poor reputation/ mode=backoff
    reply /550 Your access to submit messages to this e-mail system has been rejected/ mode=backoff
    #
    # 搜狐邮箱错误
    #
    reply /553 5.7.0 IP REJECT/ mode=backoff
    reply /503 5.5.0 unknown/ mode=backoff
    reply /553 5.7.3 CONTENT REJCT/ mode=backoff
    reply /553 5.7.4 HELOIP REJECT/ mode=backoff
</smtp-pattern-list>


############################################################################
# 退信分类规则
# 将不同的退信原因精确分类，便于查看报表和针对性优化
############################################################################

<bounce-category-patterns>
    # 垃圾邮件相关
    /spam/ spam-related
    /junk mail/ spam-related
    /blacklist/ spam-related
    /blocked/ spam-related
    /\bU\.?C\.?E\.?\b/ spam-related
    /\bAdv(ertisements?)?\b/ spam-related
    /unsolicited/ spam-related
    /\b(open)?RBL\b/ spam-related
    /realtime blackhole/ spam-related
    /http:\/\/basic.wirehub.nl\/blackholes.html/ spam-related
    /DNSBL/ spam-related
    /service provider since part of their network is on our block list/ spam-related

    # 病毒相关
    /\bvirus\b/ virus-related

    # 内容相关
    /message +content/ content-related
    /content +rejected/ content-related
    /Invalid 7bit DATA/ content-related

    # 邮箱容量问题
    /quota/ quota-issues
    /limit exceeded/ quota-issues
    /mailbox +(is +)?full/ quota-issues
    /\bstorage\b/ quota-issues

    # 发件人无效
    /sender ((verify|verification) failed|could not be verified|address rejected|domain must exist)/ invalid-sender
    /unable to verify sender/ invalid-sender
    /requires valid sender domain/ invalid-sender
    /bad sender's system address/ invalid-sender
    /No MX for envelope sender domain/ invalid-sender
    /no mail hosts for domain/ invalid-sender
    /Your domain has no(t)? DNS\/MX entries/ invalid-sender
    /REQUESTED ACTION NOT TAKEN: DNS FAILURE/ invalid-sender
    /Domain of sender address/ invalid-sender
    /return MX does not exist/ invalid-sender
    /Invalid sender domain/ invalid-sender
    /Verification failed/ invalid-sender

    # 不活跃邮箱
    /(user|mailbox|recipient|rcpt|local part|address|account|mail drop|ad(d?)ressee) (has|has been|is)? *(currently|temporarily+)?(disabled|expired|inactive|not activated)/ inactive-mailbox
    /(conta|usu.rio) inativ(a|o)/ inactive-mailbox
    /Account Inactive/ inactive-mailbox

    # 无效邮箱
    /Too many (bad|invalid|unknown|illegal|unavailable) (user|mailbox|recipient|rcpt|local part|address|account|mail drop|ad(d?)ressee)/ other
    /(No such|bad|invalid|unknown|illegal|unavailable) (local +)?(user|mailbox|recipient|rcpt|local part|address|account|mail drop|ad(d?)ressee)/ bad-mailbox
    /(user|mailbox|recipient|rcpt|local part|address|account|mail drop|ad(d?)ressee) +(\S+@\S+ +)?(not (a +)?valid|not known|not here|not found|does not exist|bad|invalid|unknown|illegal|unavailable)/ bad-mailbox
    /\S+@\S+ +(is +)?(not (a +)?valid|not known|not here|not found|does not exist|bad|invalid|unknown|illegal|unavailable)/ bad-mailbox
    /no mailbox here by that name/ bad-mailbox
    /my badrcptto list/ bad-mailbox
    /not our customer/ bad-mailbox
    /no longer (valid|available)/ bad-mailbox
    /have a \S+ account/ bad-mailbox
    /Recipient address rejected/ invalid-mailbox
    /no valid recipie/ invalid-mailbox
    /ccount has been disabled or discontinued/ bad-mailbox

    # 中继问题
    /\brelay(ing)?/ relaying-issues

    # 域名问题
    /domain (retired|bad|invalid|unknown|illegal|unavailable)/ bad-domain
    /domain no longer in use/ bad-domain
    /domain (\S+ +)?(is +)?obsolete/ bad-domain

    # 策略拒绝
    /denied/ policy-related
    /prohibit/ policy-related
    /refused/ policy-related
    /allowed/ policy-related
    /banned/ policy-related
    /policy/ policy-related
    /suspicious activity/ policy-related
    /DYN:T1/ policy-related
    /Service unavailable/ policy-related
    /oo many recip/ policy-related

    # 协议错误
    /bad sequence/ protocol-errors
    /syntax error/ protocol-errors

    # 路由错误
    /^[45]\.4\.4/ routing-errors
    /\broute\b/ routing-errors
    /\bunroutable\b/ routing-errors
    /\bunrouteable\b/ routing-errors

    # 增强状态码匹配
    /^2.\d+.\d+;/ success
    /^[45]\.1\.[1346];/ bad-mailbox
    /^[45]\.1\.2/ bad-domain
    /^[45]\.1\.[78];/ invalid-sender
    /^[45]\.2\.0;/ bad-mailbox
    /^[45]\.2\.1;/ inactive-mailbox
    /^[45]\.2\.2;/ quota-issues
    /^[45]\.3\.3;/ content-related
    /^[45]\.3\.5;/ bad-configuration
    /^[45]\.4\.1;/ no-answer-from-host
    /^[45]\.4\.2;/ bad-connection
    /^[45]\.4\.[36];/ routing-errors
    /^[45]\.4\.7;/ message-expired
    /^[45]\.5\.3;/ policy-related
    /^[45]\.5\.\d+;/ protocol-errors
    /^[45]\.6\.\d+;/ content-related
    /^[45]\.7\.[012];/ policy-related
    /^[45]\.7\.7;/ content-related

    # 兜底规则（未匹配到以上任何规则的退信）
    // other
</bounce-category-patterns>
EOFCONFIG

chmod 644 /etc/pmta/config

# 停掉其他邮局，释放 25/465/587/2525（否则 PMTA 会 EADDRINUSE）
echo "停止其他邮局..."
for svc in haraka postfix sendmail exim4 exim; do
    systemctl stop "$svc" 2>/dev/null || true
    systemctl disable "$svc" 2>/dev/null || true
done
pkill -f 'node haraka.js' 2>/dev/null || true
sleep 2
for p in 25 465 587 2525; do
    fuser -k "${p}/tcp" 2>/dev/null || true
done
sleep 1

# 启动PowerMTA服务（使用原生 systemd 单元避免 SysV/pmtawatch 缺失导致启动失败）
echo "配置并启动 PowerMTA systemd 服务..."
cat > /etc/systemd/system/pmta.service << 'PMTASVCEOF'
[Unit]
Description=Port25 PowerMTA Message Transfer Agent
After=network.target network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/sbin/pmtad
Restart=always
RestartSec=5
LimitNOFILE=1000000
LimitNPROC=32768
User=root
Group=root

[Install]
WantedBy=multi-user.target
PMTASVCEOF
chmod 644 /etc/systemd/system/pmta.service

sudo systemctl daemon-reload 2>/dev/null
sudo systemctl enable pmta 2>/dev/null || true
sudo systemctl enable pmtahttp 2>/dev/null || true
sudo systemctl restart pmta 2>/dev/null
sudo systemctl restart pmtahttp 2>/dev/null || true

# Telegram: remote MX accept only (acct type=d). Inject/queue 250 is not counted.
mkdir -p /opt/pmta/tg/data
base64 -d > /opt/pmta/tg/pmta_tg_push.py << 'EOFPMTATG'
{{PMTA_TG_PUSH_B64}}
EOFPMTATG
chmod 755 /opt/pmta/tg/pmta_tg_push.py
cat > /etc/systemd/system/pmta-tg.service << 'EOF'
[Unit]
Description=PowerMTA Telegram delivered archive
After=pmta.service
Wants=pmta.service

[Service]
Type=simple
ExecStart=/usr/bin/python3 /opt/pmta/tg/pmta_tg_push.py
Restart=always
RestartSec=3
WorkingDirectory=/opt/pmta/tg

[Install]
WantedBy=multi-user.target
EOF
sudo systemctl daemon-reload
sudo systemctl enable pmta-tg 2>/dev/null || true
sudo systemctl restart pmta-tg 2>/dev/null || true

# RFC 8058 / RFC 2369 One-Click Unsubscribe Web Service for PowerMTA
echo "部署 PowerMTA RFC 8058 退订服务..."
mkdir -p /opt/pmta/unsub/logs
cat > /opt/pmta/unsub/unsub_service.py << 'EOFPYUNSUB'
import sys, os, time, datetime, urllib.parse
from http.server import HTTPServer, BaseHTTPRequestHandler

LOG_DIR = "/opt/pmta/unsub/logs"
CSV_FILE = os.path.join(LOG_DIR, "unsubscribed.csv")

def ensure_log():
    try:
        os.makedirs(LOG_DIR, exist_ok=True)
        if not os.path.exists(CSV_FILE):
            with open(CSV_FILE, "w", encoding="utf-8") as f:
                f.write("TimeISO,Email,IP,Method,UserAgent\n")
    except Exception:
        pass

def record_unsub(email, ip, method, ua):
    if not email or "@" not in email:
        return
    clean_email = email.strip().lower()
    try:
        ensure_log()
        ts = datetime.datetime.utcnow().isoformat() + "Z"
        line = f'"{ts}","{clean_email.replace(\'"\', \'""\')}","{ip}","{method}","{ua.replace(\'"\', \'""\')}"\n'
        with open(CSV_FILE, "a", encoding="utf-8") as f:
            f.write(line)
    except Exception:
        pass

HTML_TEMPLATE = """<!DOCTYPE html>
<html lang="ja">
<head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>配信停止の手続き完了 - Unsubscribed</title>
    <style>
        body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", "Hiragino Kaku Gothic ProN", "Hiragino Sans", "BIZ UDPGothic", Meiryo, sans-serif; background: #0b0f19; color: #f1f5f9; display: flex; align-items: center; justify-content: center; min-height: 100vh; margin: 0; padding: 20px; box-sizing: border-box; }
        .card { background: #161e2e; border: 1px solid #283548; border-radius: 16px; padding: 40px 32px; max-width: 480px; width: 100%; text-align: center; box-shadow: 0 25px 50px -12px rgba(0, 0, 0, 0.6); }
        .icon { width: 64px; height: 64px; background: rgba(34, 197, 94, 0.15); color: #22c55e; border-radius: 50%; display: inline-flex; align-items: center; justify-content: center; font-size: 30px; margin-bottom: 20px; }
        h1 { font-size: 20px; font-weight: 600; margin: 0 0 6px 0; color: #ffffff; letter-spacing: 0.02em; }
        .sub { font-size: 13px; color: #64748b; margin: 0 0 18px 0; font-weight: 500; }
        p { font-size: 14px; color: #94a3b8; line-height: 1.7; margin: 0 0 16px 0; }
        .email-badge { display: inline-block; background: #0f172a; border: 1px solid #334155; color: #38bdf8; padding: 6px 14px; border-radius: 9999px; font-size: 13px; font-family: ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, monospace; margin-bottom: 18px; word-break: break-all; }
        .note { font-size: 12px; color: #94a3b8; line-height: 1.6; margin-top: 18px; text-align: left; background: rgba(15, 23, 42, 0.6); padding: 12px 14px; border-radius: 8px; border-left: 3px solid #38bdf8; }
        .footer { font-size: 11px; color: #475569; border-top: 1px solid #283548; padding-top: 16px; margin-top: 24px; }
    </style>
</head>
<body>
    <div class="card">
        <div class="icon">&#10003;</div>
        <h1>配信停止の手続きが完了しました</h1>
        <div class="sub">Unsubscription Completed</div>
        <p>お客様のメールアドレスへのご案内メールの配信を停止いたしました。<br>これ以降、本配信リストからのメールは届きません。</p>
        __BADGE__
        <div class="note">※ 反映に数時間程度かかる場合がございます。万が一メールが届いた場合は、お手数ですが再度ご連絡ください。</div>
        <div class="footer">RFC 8058 One-Click List-Unsubscribe Service</div>
    </div>
</body>
</html>"""

class UnsubHandler(BaseHTTPRequestHandler):
    def log_message(self, format, *args):
        pass

    def do_GET(self):
        parsed = urllib.parse.urlparse(self.path)
        qs = urllib.parse.parse_qs(parsed.query)
        email = qs.get("email", [""])[0] or qs.get("addr", [""])[0] or qs.get("id", [""])[0]
        ip = self.headers.get("X-Forwarded-For", self.client_address[0]).split(",")[0].strip()
        ua = self.headers.get("User-Agent", "")
        if email:
            record_unsub(email, ip, "GET", ua)
        badge = f'<div class="email-badge">{email}</div>' if email and "@" in email else ""
        content = HTML_TEMPLATE.replace("__BADGE__", badge).encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(content)))
        self.send_header("X-Robots-Tag", "noindex, nofollow")
        self.end_headers()
        self.wfile.write(content)

    def do_POST(self):
        content_len = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(content_len).decode("utf-8", errors="ignore") if content_len > 0 else ""
        parsed = urllib.parse.urlparse(self.path)
        qs = urllib.parse.parse_qs(parsed.query)
        post_data = urllib.parse.parse_qs(body)
        email = qs.get("email", [""])[0] or post_data.get("email", [""])[0] or qs.get("id", [""])[0]
        ip = self.headers.get("X-Forwarded-For", self.client_address[0]).split(",")[0].strip()
        ua = self.headers.get("User-Agent", "")
        if email:
            record_unsub(email, ip, "POST", ua)
        msg = b"Unsubscribed successfully\r\n"
        self.send_response(200)
        self.send_header("Content-Type", "text/plain; charset=utf-8")
        self.send_header("Content-Length", str(len(msg)))
        self.end_headers()
        self.wfile.write(msg)

if __name__ == "__main__":
    ensure_log()
    import threading
    def run_server(port):
        try:
            s = HTTPServer(("0.0.0.0", port), UnsubHandler)
            s.serve_forever()
        except Exception:
            pass
    t = threading.Thread(target=run_server, args=(80,), daemon=True)
    t.start()
    run_server(9091)
EOFPYUNSUB
chmod 755 /opt/pmta/unsub/unsub_service.py

cat > /etc/systemd/system/pmta-unsub.service << 'EOF'
[Unit]
Description=PowerMTA RFC 8058 One-Click Unsubscribe Service
After=network.target

[Service]
Type=simple
ExecStart=/usr/bin/python3 /opt/pmta/unsub/unsub_service.py
Restart=always
RestartSec=3
WorkingDirectory=/opt/pmta/unsub

[Install]
WantedBy=multi-user.target
EOF
sudo systemctl daemon-reload
sudo systemctl enable pmta-unsub 2>/dev/null || true
sudo systemctl restart pmta-unsub 2>/dev/null || true

# 配置防火墙
echo "配置防火墙规则..."
sudo iptables -A INPUT -m state --state NEW -p tcp -m multiport --dports 25,80,587,2525,9091 -j ACCEPT
sudo iptables -A INPUT -p tcp --dport 1983 ! -s 127.0.0.1 -j DROP 2>/dev/null || true
which ufw >/dev/null 2>&1 && sudo ufw deny 1983/tcp 2>/dev/null || true
which ufw >/dev/null 2>&1 && sudo ufw allow 80/tcp 2>/dev/null || true
which ufw >/dev/null 2>&1 && sudo ufw allow 9091/tcp 2>/dev/null || true
sudo netfilter-persistent save 2>/dev/null || true

# 验证PowerMTA服务状态
echo "验证PowerMTA服务状态..."
sleep 2
if systemctl is-active --quiet pmta; then
    echo "PowerMTA服务已成功启动...正在重启服务器，请稍等片刻..."
else
    echo "PowerMTA服务启动可能有问题，请检查日志"
fi




echo "PowerMTA安装完成..."
echo 'CONFIGURE_OK' > /tmp/configure.result
echo 'CONFIGURE_OK'
