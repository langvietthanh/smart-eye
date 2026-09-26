"""Tải dataset từ Mendeley Data qua API công khai, giữ nguyên cấu trúc thư mục.

    python training/scripts/fetch_mendeley.py rgymy6dwdd --out datasets/mendeley_bpid
    python training/scripts/fetch_mendeley.py rgymy6dwdd --out /tmp/bpid_labels --only .txt .json   # chỉ tải nhãn

Ví dụ đã kiểm tra: Bandung Pothole Image Dataset (BPID), DOI 10.17632/rgymy6dwdd.1, giấy phép CC BY 4.0 —
khi dùng phải ghi nguồn (xem training/README.md mục "Nguồn dữ liệu").
"""
from __future__ import annotations

import argparse
import json
import urllib.request
from pathlib import Path

API = 'https://data.mendeley.com/public-api/datasets'
# Mendeley trả 403 với User-Agent mặc định của Python
HEADERS = {'User-Agent': 'Mozilla/5.0 (smart-eye dataset fetch)'}


def open_url(url: str, timeout: int = 60):
    return urllib.request.urlopen(urllib.request.Request(url, headers=HEADERS), timeout=timeout)


def get_json(url: str):
    with open_url(url) as r:
        return json.load(r)


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('dataset_id', help='VD rgymy6dwdd (trong link data.mendeley.com/datasets/<id>/<version>)')
    ap.add_argument('--version', type=int, default=1)
    ap.add_argument('--out', required=True)
    ap.add_argument('--only', nargs='*', default=None, help='Chỉ tải file có đuôi này (VD .txt .json)')
    args = ap.parse_args()

    folders = get_json(f'{API}/{args.dataset_id}/folders/{args.version}')
    by_id = {f['id']: f for f in folders}

    def folder_path(fid: str | None) -> Path:
        parts = []
        while fid:
            parts.append(by_id[fid]['name'])
            fid = by_id[fid].get('parent_id')
        return Path(*reversed(parts)) if parts else Path()

    out = Path(args.out)
    total = done = size = 0
    for fid in [None, *by_id]:
        query = f'folder_id={fid}&' if fid else ''
        files = get_json(f'{API}/{args.dataset_id}/files?{query}version={args.version}')
        if not isinstance(files, list):  # thư mục gốc có thể trả về dạng khác khi không có file lẻ
            continue
        for f in files:
            name = f['filename']
            if args.only and not name.lower().endswith(tuple(e.lower() for e in args.only)):
                continue
            total += 1
            dest = out / folder_path(fid) / name
            if dest.exists() and dest.stat().st_size == f.get('size'):
                continue
            dest.parent.mkdir(parents=True, exist_ok=True)
            with open_url(f['content_details']['download_url'], timeout=120) as r:
                dest.write_bytes(r.read())
            done += 1
            size += f.get('size', 0)
            if done % 20 == 0:
                print(f'  {done} file, {size / 1e6:.1f} MB...', flush=True)
    print(f'Xong: {total} file ({done} mới tải, {size / 1e6:.1f} MB) → {out}')


if __name__ == '__main__':
    main()
