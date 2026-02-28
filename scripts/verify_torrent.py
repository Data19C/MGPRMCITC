#!/usr/bin/env python3
"""
种子文件验证脚本
功能：验证.torrent文件的完整性和关联文件的可用性
用法：python verify_torrent.py <torrent文件路径> [--check-files]
"""

import os
import sys
import json
import hashlib
import struct
import argparse
from pathlib import Path
from urllib.parse import urlparse
from datetime import datetime
from typing import Dict, List, Tuple, Optional, Any

try:
    import bencodepy
    HAS_BENCODE = True
except ImportError:
    HAS_BENCODE = False
    print("警告：未安装bencodepy库，使用备用解析器（功能受限）")


class TorrentVerifier:
    """种子文件验证器"""
    
    def __init__(self, torrent_path: str):
        self.torrent_path = torrent_path
        self.torrent_data = None
        self.info = None
        self.info_hash = None
        self.files = []
        self.total_size = 0
        
    def load_torrent(self) -> bool:
        """加载并解析种子文件"""
        try:
            if not os.path.exists(self.torrent_path):
                print(f"错误：文件不存在 - {self.torrent_path}")
                return False
                
            with open(self.torrent_path, 'rb') as f:
                data = f.read()
                
            # 解析种子文件
            if HAS_BENCODE:
                self.torrent_data = bencodepy.decode(data)
            else:
                self.torrent_data = self._decode_bencode(data)
                
            if not self.torrent_data:
                print("错误：无法解析种子文件")
                return False
                
            # 提取info字典
            if b'info' not in self.torrent_data:
                print("错误：种子文件缺少info字典")
                return False
                
            self.info = self.torrent_data[b'info']
            
            # 计算info_hash (SHA1)
            if HAS_BENCODE:
                info_bencoded = bencodepy.encode(self.info)
            else:
                info_bencoded = self._encode_bencode(self.info)
                
            self.info_hash = hashlib.sha1(info_bencoded).hexdigest()
            
            # 提取文件信息
            self._extract_file_info()
            
            return True
            
        except Exception as e:
            print(f"解析种子文件时出错: {e}")
            return False
    
    def _extract_file_info(self):
        """提取种子中的文件信息"""
        info = self.info
        
        # 单文件模式
        if b'files' not in info:
            self.files.append({
                'path': info.get(b'name', b'').decode('utf-8', errors='ignore'),
                'length': info.get(b'length', 0),
                'piece_length': info.get(b'piece length', 0)
            })
            self.total_size = info.get(b'length', 0)
        # 多文件模式
        else:
            base_path = info.get(b'name', b'').decode('utf-8', errors='ignore')
            for file_info in info[b'files']:
                path_parts = [p.decode('utf-8', errors='ignore') 
                            for p in file_info[b'path']]
                full_path = os.path.join(base_path, *path_parts)
                
                self.files.append({
                    'path': full_path,
                    'length': file_info[b'length'],
                    'piece_length': info.get(b'piece length', 0)
                })
                self.total_size += file_info[b'length']
    
    def verify_files_exist(self, base_dir: str = '.') -> Dict:
        """验证关联文件是否存在且大小正确"""
        results = {
            'missing': [],
            'size_mismatch': [],
            'valid': []
        }
        
        for file_info in self.files:
            file_path = os.path.join(base_dir, file_info['path'])
            
            if not os.path.exists(file_path):
                results['missing'].append({
                    'path': file_path,
                    'expected_size': file_info['length']
                })
                continue
                
            actual_size = os.path.getsize(file_path)
            if actual_size != file_info['length']:
                results['size_mismatch'].append({
                    'path': file_path,
                    'expected_size': file_info['length'],
                    'actual_size': actual_size
                })
            else:
                results['valid'].append({
                    'path': file_path,
                    'size': file_info['length']
                })
                
        return results
    
    def generate_magnet_link(self) -> str:
        """生成磁力链接"""
        if not self.info_hash:
            return ""
            
        # 获取文件名
        if self.files:
            name = self.files[0]['path']
            if len(self.files) > 1:
                name = os.path.dirname(name) if '/' in name else name
        else:
            name = "unknown"
            
        # 添加tracker（如果存在）
        trackers = []
        if b'announce' in self.torrent_data:
            announce = self.torrent_data[b'announce']
            if announce:
                trackers.append(announce.decode('utf-8', errors='ignore'))
        
        if b'announce-list' in self.torrent_data:
            for tracker_group in self.torrent_data[b'announce-list']:
                for tracker in tracker_group:
                    if tracker:
                        tracker_str = tracker.decode('utf-8', errors='ignore')
                        if tracker_str not in trackers:
                            trackers.append(tracker_str)
        
        # 构建磁力链接
        magnet = f"magnet:?xt=urn:btih:{self.info_hash}"
        magnet += f"&dn={name}"
        
        for tracker in trackers[:5]:  # 最多添加5个tracker
            magnet += f"&tr={tracker}"
            
        return magnet
    
    def get_tracker_list(self) -> List[str]:
        """获取tracker列表"""
        trackers = []
        
        if b'announce' in self.torrent_data:
            announce = self.torrent_data[b'announce']
            if announce:
                trackers.append(announce.decode('utf-8', errors='ignore'))
        
        if b'announce-list' in self.torrent_data:
            for tracker_group in self.torrent_data[b'announce-list']:
                for tracker in tracker_group:
                    if tracker:
                        tracker_str = tracker.decode('utf-8', errors='ignore')
                        if tracker_str not in trackers:
                            trackers.append(tracker_str)
        
        return trackers
    
    def print_summary(self, check_files: bool = False, base_dir: str = '.'):
        """打印种子文件摘要信息"""
        print("=" * 60)
        print(f"种子文件: {os.path.basename(self.torrent_path)}")
        print("=" * 60)
        
        if not self.info_hash:
            print("错误：无法获取种子信息")
            return
            
        print(f"信息哈希: {self.info_hash}")
        print(f"文件数量: {len(self.files)}")
        print(f"总大小: {self._format_size(self.total_size)}")
        
        if self.files:
            print("\n文件列表:")
            for i, file_info in enumerate(self.files, 1):
                print(f"  {i:2d}. {file_info['path']} "
                      f"({self._format_size(file_info['length'])})")
        
        # 显示tracker
        trackers = self.get_tracker_list()
        if trackers:
            print(f"\nTracker服务器 ({len(trackers)}个):")
            for i, tracker in enumerate(trackers[:10], 1):  # 最多显示10个
                print(f"  {i:2d}. {tracker}")
            if len(trackers) > 10:
                print(f"  ... 还有{len(trackers)-10}个")
        
        # 显示创建信息
        if b'creation date' in self.torrent_data:
            timestamp = self.torrent_data[b'creation date']
            if isinstance(timestamp, (int, bytes)):
                if isinstance(timestamp, bytes):
                    timestamp = int(timestamp)
                created = datetime.fromtimestamp(timestamp)
                print(f"\n创建时间: {created}")
        
        if b'created by' in self.torrent_data:
            creator = self.torrent_data[b'created by']
            if isinstance(creator, bytes):
                print(f"创建工具: {creator.decode('utf-8', errors='ignore')}")
        
        if b'comment' in self.torrent_data:
            comment = self.torrent_data[b'comment']
            if isinstance(comment, bytes) and comment.strip():
                print(f"注释: {comment.decode('utf-8', errors='ignore')}")
        
        # 验证文件
        if check_files:
            print("\n" + "=" * 60)
            print("文件验证:")
            results = self.verify_files_exist(base_dir)
            
            if results['valid']:
                print(f"✓ 找到 {len(results['valid'])} 个文件，大小正确")
            
            if results['missing']:
                print(f"✗ 缺失 {len(results['missing'])} 个文件:")
                for f in results['missing']:
                    print(f"  - {f['path']} (期望: {self._format_size(f['expected_size'])})")
            
            if results['size_mismatch']:
                print(f"⚠  {len(results['size_mismatch'])} 个文件大小不匹配:")
                for f in results['size_mismatch']:
                    print(f"  - {f['path']}")
                    print(f"    期望: {self._format_size(f['expected_size'])}")
                    print(f"    实际: {self._format_size(f['actual_size'])}")
        
        # 显示磁力链接
        magnet = self.generate_magnet_link()
        if magnet:
            print("\n" + "=" * 60)
            print("磁力链接:")
            print(magnet[:100] + "..." if len(magnet) > 100 else magnet)
    
    def _format_size(self, size_bytes: int) -> str:
        """格式化文件大小"""
        for unit in ['B', 'KB', 'MB', 'GB', 'TB']:
            if size_bytes < 1024.0:
                return f"{size_bytes:.2f} {unit}"
            size_bytes /= 1024.0
        return f"{size_bytes:.2f} PB"
    
    # 备用bencode编解码器（如果bencodepy不可用）
    def _decode_bencode(self, data: bytes, decode_strings: bool = False):
        """简单的bencode解码器"""
        def decode_string(x, i):
            colon = x.find(b':', i)
            if colon == -1:
                raise ValueError("无效的bencode字符串")
            length = int(x[i:colon])
            start = colon + 1
            end = start + length
            if end > len(x):
                raise ValueError("字符串长度超出范围")
            s = x[start:end]
            return (s.decode('utf-8', errors='ignore') if decode_strings else s, end)
        
        def decode_int(x, i):
            i += 1
            end = x.find(b'e', i)
            if end == -1:
                raise ValueError("无效的bencode整数")
            return (int(x[i:end]), end + 1)
        
        def decode_list(x, i):
            i += 1
            result = []
            while i < len(x) and x[i] != ord('e'):
                item, i = decode(x, i)
                result.append(item)
            return (result, i + 1)
        
        def decode_dict(x, i):
            i += 1
            result = {}
            while i < len(x) and x[i] != ord('e'):
                key, i = decode_string(x, i)
                val, i = decode(x, i)
                result[key] = val
            return (result, i + 1)
        
        def decode(x, i):
            if i >= len(x):
                raise ValueError("意外的bencode结束")
            
            c = x[i]
            if c == ord('d'):
                return decode_dict(x, i)
            elif c == ord('l'):
                return decode_list(x, i)
            elif c == ord('i'):
                return decode_int(x, i)
            elif 48 <= c <= 57:  # 数字0-9
                return decode_string(x, i)
            else:
                raise ValueError(f"无效的bencode标记: {chr(c)}")
        
        try:
            result, _ = decode(data, 0)
            return result
        except Exception as e:
            print(f"备用解码器错误: {e}")
            return None
    
    def _encode_bencode(self, obj):
        """简单的bencode编码器（仅用于计算hash）"""
        if isinstance(obj, bytes):
            return str(len(obj)).encode() + b':' + obj
        elif isinstance(obj, str):
            obj_bytes = obj.encode('utf-8')
            return str(len(obj_bytes)).encode() + b':' + obj_bytes
        elif isinstance(obj, int):
            return b'i' + str(obj).encode() + b'e'
        elif isinstance(obj, list):
            return b'l' + b''.join(self._encode_bencode(item) for item in obj) + b'e'
        elif isinstance(obj, dict):
            # 字典必须按键排序
            items = []
            for key in sorted(obj.keys()):
                items.append(self._encode_bencode(key))
                items.append(self._encode_bencode(obj[key]))
            return b'd' + b''.join(items) + b'e'
        else:
            raise TypeError(f"不支持的类型: {type(obj)}")


def main():
    parser = argparse.ArgumentParser(description='验证.torrent种子文件')
    parser.add_argument('torrent_file', help='.torrent文件路径')
    parser.add_argument('--check-files', action='store_true', 
                       help='检查关联文件是否存在')
    parser.add_argument('--base-dir', default='.', 
                       help='文件基础目录（默认当前目录）')
    parser.add_argument('--install-bencode', action='store_true',
                       help='自动安装bencodepy库')
    
    args = parser.parse_args()
    
    # 自动安装依赖
    if args.install_bencode and not HAS_BENCODE:
        print("正在安装bencodepy库...")
        import subprocess
        subprocess.check_call([sys.executable, '-m', 'pip', 'install', 'bencodepy'])
        print("安装完成，请重新运行脚本")
        return
    
    if not HAS_BENCODE:
        print("警告：未找到bencodepy库，使用有限功能解析")
        print("      使用 --install-bencode 自动安装 或运行: pip install bencodepy")
    
    # 验证种子
    verifier = TorrentVerifier(args.torrent_file)
    
    if not verifier.load_torrent():
        print("无法加载种子文件")
        return 1
    
    verifier.print_summary(args.check_files, args.base_dir)
    
    return 0


if __name__ == '__main__':
    sys.exit(main())