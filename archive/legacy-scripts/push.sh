#!/bin/bash
# 用法: ./push.sh 镜像文件 设备列表文件

IMAGE=$1
DEVICES=$2
USER=""

[ $# -ne 2 ] && { echo "用法: $0 <镜像文件> <设备列表文件>"; exit 1; }
[ ! -f "$IMAGE" ] && { echo "镜像不存在"; exit 1; }
[ ! -f "$DEVICES" ] && { echo "设备列表不存在"; exit 1; }

# 检查 sshpass
command -v sshpass >/dev/null || { echo "请先装 sshpass: yum install -y sshpass 或 apt install -y sshpass"; exit 1; }

read -p "用户名: " USER
read -s -p "密码: " PASS; echo ""

while read -r IP PATH DESC; do
    [ -z "$IP" ] && continue
    [[ "$IP" =~ ^# ]] && continue
    REMOTE="${PATH:-flash:}/$(basename "$IMAGE")"
    
    echo ""
    echo "设备: $IP ${DESC:+(}$DESC)}"
    echo "目标: $REMOTE"
    read -p "确认推送? [Y/n] " OK
    [[ "$OK" =~ ^[Nn]$ ]] && { echo "跳过"; continue; }
    
    sshpass -p "$PASS" scp -O \
        -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null \
        -o ConnectTimeout=10 \
        -o LogLevel=ERROR \
        "$IMAGE" "${USER}@${IP}:${REMOTE}" \
    && echo "✓ 成功" || echo "✗ 失败"
done < "$DEVICES"
