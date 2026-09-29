# PowerMTA 自动部署模块 (纯净安全版)

本仓库提供 PowerMTA 企业级邮局自动化安装、配置与管理资源。
所有后门、Telegram 凭证外发及遥测代码已彻底清除。

## 包含文件
- `configure_pmta.sh`: PowerMTA 自动化安装配置脚本
- `pmta_tg_push.py`: 纯净本地空转占位服务（Telegram 外发已完全禁用）
- `repack_pmta_bundle.py`: 离线 Bundle 打包工具
- `bundle_pmta.txt`: 离线包元数据与 SHA256 校验和

## Release 离线安装包
预编译并清理完毕的离线包 `pmta-bundle-v1.4.tar.gz` 存放在本仓库的 [Releases](../../releases) 页面中。
