# GOST Port Forwarder

一个简单的 GOST TCP/UDP 端口转发一键安装脚本，适合把公网服务器端口转发到内网 `10.0.0.x` 机器。

## 默认转发规则

- SSH：`10002 -> 10.0.0.2:22`，一直到 `10099 -> 10.0.0.99:22`
- TCP 业务端口：每台机器 10 个端口
  - `20020-20029 -> 10.0.0.2:20020-20029`
  - `20030-20039 -> 10.0.0.3:20030-20039`
  - ...
  - `20990-20999 -> 10.0.0.99:20990-20999`
- UDP 业务端口：默认同样开启

## 一键安装

```bash
wget -O install_gost_forward.sh https://raw.githubusercontent.com/xihuan0526/gost-port-forwarder/main/install_gost_forward.sh
chmod +x install_gost_forward.sh
sudo ./install_gost_forward.sh
```

## 自定义参数

可以通过环境变量调整：

```bash
sudo IP_PREFIX=10.0.0 IP_START=2 IP_END=99 ENABLE_UDP=1 ./install_gost_forward.sh
```

常用变量：

- `IP_PREFIX`：目标 IP 前缀，默认 `10.0.0`
- `IP_START` / `IP_END`：目标 IP 末位范围，默认 `2` 到 `99`
- `SSH_BASE_PORT`：SSH 映射基础端口，默认 `10000`
- `BUSINESS_BASE_PORT`：业务端口基础值，默认 `20000`
- `PORTS_PER_IP`：每个 IP 分配业务端口数量，默认 `10`
- `ENABLE_UDP`：是否启用 UDP，默认 `1`
- `LOG_RATE_INTERVAL`：systemd 日志限流时间窗口，默认 `30s`
- `LOG_RATE_BURST`：systemd 日志限流条数，默认 `500`

## 管理服务

```bash
systemctl status gost-forward --no-pager
journalctl -u gost-forward -n 100 --no-pager
systemctl restart gost-forward
```

## 说明

脚本会自动：

1. 安装基础依赖；
2. 识别 CPU 架构；
3. 从 GOST GitHub Release 下载最新 Linux 版本；
4. 生成 `/root/gost/start.sh`；
5. 创建并启动 `gost-forward.service`。
