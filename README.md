# MGPRMCiI
- 项目英文全称：Mobile Game Performance Review: Manufacturers' Cheating is Insane!
- 视频标题：手机游戏性能大横评：厂商作弊太疯狂！
- 视频作者：极客湾Geekerwan
- 做种者：一名手持国产安卓手机的热心网友
<br><br>

### 极客湾“手机游戏性能大横评”视频备份与技术分析
#### 项目目的
1. 备份极客湾于2026年2月15日发布、2月22日被下架的视频《手机游戏性能大横评：厂商作弊太疯狂！》
2. 技术分析视频编码、BT协议实现等相关技术
3. 研究数字内容在审查环境下的分布式存储方案
#### 授权依据
##### 极客湾已在B站动态中明确授权：
> “将视频开源传播，允许任何平台、任何人随便转载、分发，不用授权、不用署名”
#### 免责声明
- 本项目仅用于技术研究、数字备份和协议学习
- 视频内容版权归极客湾所有，传播已获作者明确授权
- 不鼓励任何商业用途或恶意传播
<br><br>

### 安装和使用说明
#### 1. 安装 依赖
##### 安装Python依赖
`pip install bencodepy`
<br><br>

###### 或使用脚本自动安装
`python verify_torrent.py --install-bencode`
<br><br>

##### 确保系统有curl、dig、nc等工具
##### Ubuntu/Debian:
`sudo apt-get install curl dnsutils netcat-openbsd`
<br><br>

##### CentOS/RHEL:
`sudo yum install curl bind-utils nmap-ncat`
<br><br>

#### 2. 设置可执行权限
`chmod +x tracker_check.sh`
`chmod +x verify_torrent.py`
<br><br>

#### 3. 使用示例
##### 验证种子文件：
`python verify_torrent.py 手机游戏性能大横评：厂商作弊太疯狂！.torrent`
<br><br>

##### 验证种子并检查关联文件
`python verify_torrent.py 手机游戏性能大横评：厂商作弊太疯狂！.torrent --check-files`
<br><br>

### 指定文件基础目录
`python verify_torrent.py 手机游戏性能大横评：厂商作弊太疯狂！.torrent --check-files --base-dir /path/to/files`
<br><br>

### 检查Tracker：
##### 检查种子文件中的tracker
`./tracker_check.sh 手机游戏性能大横评：厂商作弊太疯狂！.torrent`
<br><br>

### 检查磁力链接中的tracker
`./tracker_check.sh "magnet:?xt=urn:btih:..."`
<br><br>

### 检查tracker列表文件
`./tracker_check.sh trackers.txt`
<br><br>

### 更新tracker列表
`./tracker_check.sh --update-list`
<br><br>

### JSON格式输出
`./tracker_check.sh 手机游戏性能大横评：厂商作弊太疯狂！.torrent --json`
<br><br>

### 详细输出
`./tracker_check.sh 手机游戏性能大横评：厂商作弊太疯狂！.torrent --verbose`
<br><br>

#### 4. 在项目中使用的建议
#####  脚本使用说明
##### verify_torrent.py
##### 用于验证.torrent文件的完整性和关联文件状态。
<br><br>

**功能：**
- 解析torrent文件结构
- 计算info_hash（用于生成磁力链接）
- 列出包含的文件和大小
- 提取tracker服务器列表
- 验证本地文件是否存在和大小匹配
- 生成磁力链接
<br><br>

输出示例：  

============================================================  

种子文件: 手机游戏性能大横评：厂商作弊太疯狂！.torrent  

信息哈希: c79836d3ea84caefb4f57c6c7308ab68dc801bcd  

文件数量: 1  

总大小: 2.15 GB  

文件列表: ...  

Tracker服务器 (8个): ...  

磁力链接: magnet:?xt=urn:btih:...  
<br><br>

### tracker_check.sh
用于检查tracker服务器的可用性和响应时间。
<br><br>

**功能：**
- 从多种来源获取tracker（磁链、种子、列表文件）
- 并行检查多个tracker状态
- 支持HTTP/HTTPS/UDP协议
- 自动更新tracker列表
- 彩色输出和JSON格式支持
- DNS解析和连接测试
<br><br>

输出示例：  

找到 15 个tracker，开始检查...  

超时: 5秒 | 并发: 10  

检查进度: [#################### ] 8/15 (在线: 5)  

✓ udp://tracker.opentrackr.org:1337/announce  

状态: 在线 | 响应: 45ms  

========== 检查完成 ==========  

总计: 15 个tracker  

在线: 9  

离线: 6  

在线率: 60.0%
