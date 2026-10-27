#!/usr/bin/env python3
"""
数据一致性三级校验

L1 总行数比对      —— 漏导、重复导入
L2 关键字段 checksum —— 字段错位、类型转换错误
L3 抽样逐字段核对   —— 精度丢失、空值处理、编码问题

为什么分三级：全量逐字段核对要 40 分钟，超出割接窗口。
三级递进能在 23 分钟内达到 99% 的把握。

用法:
  python3 04_verify.py --level all
  python3 04_verify.py --level L1
"""
import argparse
import csv
import hashlib
import os
import random
import sys

EXPORT_DIR = os.path.join(os.path.dirname(__file__), '..', 'export')

TABLES = ['ACCOUNT_SUBJECT', 'VOUCHER', 'BALANCE', 'PARTNER', 'DEPARTMENT', 'CURRENCY']

# 每张表参与 checksum 的关键字段
# 必须显式指定顺序，不能依赖 SELECT *（踩过坑：列顺序不同导致 checksum 对不上）
KEY_FIELDS = {
    'ACCOUNT_SUBJECT': ['SUBJECT_CODE', 'SUBJECT_NAME', 'SUBJECT_TYPE'],
    'VOUCHER': ['VOUCHER_NO', 'VOUCHER_DATE', 'AMOUNT', 'SUBJECT_CODE'],
    'BALANCE': ['SUBJECT_CODE', 'PERIOD', 'BEGIN_BALANCE', 'END_BALANCE'],
    'PARTNER': ['PARTNER_CODE', 'PARTNER_NAME', 'TAX_NO'],
    'DEPARTMENT': ['DEPT_CODE', 'DEPT_NAME', 'PARENT_CODE'],
    'CURRENCY': ['CURRENCY_CODE', 'CURRENCY_NAME', 'RATE'],
}

SAMPLE_SIZE = 200


def read_csv(path):
    if not os.path.exists(path):
        return None, []
    with open(path, encoding='utf-8-sig', newline='') as f:
        rows = list(csv.reader(f))
    if not rows:
        return None, []
    return [h.upper().strip() for h in rows[0]], rows[1:]


def normalize(v):
    """
    归一化值，消除源库和目标库的表示差异

    - 空串 -> ''（Oracle 把 '' 当 NULL，MySQL 区分两者）
    - 数字去尾零
    - 日期截到日
    """
    if v is None:
        return ''
    s = str(v).strip()
    if s == '' or s.upper() == 'NULL':
        return ''

    # 日期
    if len(s) >= 10 and s[4] == '-' and s[7] == '-':
        return s[:10]

    # 数字
    try:
        f = float(s)
        if f == int(f):
            return str(int(f))
        return f'{f:.6f}'.rstrip('0').rstrip('.')
    except ValueError:
        return s


def checksum(rows, idxs):
    h = hashlib.md5()
    for r in rows:
        for i in idxs:
            if i < len(r):
                h.update(normalize(r[i]).encode('utf-8'))
                h.update(b'|')
    return h.hexdigest()


def verify_table(table, mysql_dir, level):
    src_p = os.path.join(EXPORT_DIR, f'{table}.csv')
    dst_p = os.path.join(mysql_dir, f'{table}.csv')

    sh, srows = read_csv(src_p)
    dh, drows = read_csv(dst_p)

    if sh is None:
        return False, '源 CSV 不存在'
    if dh is None:
        return False, f'目标 CSV 不存在（需先从 MySQL 导出到 {mysql_dir}）'

    lines = []

    # ---- L1 行数 ----
    l1 = len(srows) == len(drows)
    lines.append(f'  L1 行数:     源 {len(srows):>8,}  目标 {len(drows):>8,}  '
                 f'{"PASS" if l1 else "FAIL"}')
    if not l1:
        lines.append(f'               差异 {len(drows) - len(srows):+,} 行')
        return False, '\n'.join(lines)

    if level == 'L1':
        return True, '\n'.join(lines)

    # ---- L2 checksum ----
    fields = KEY_FIELDS.get(table, [])
    if not fields:
        lines.append('  L2 checksum: 跳过（未配置关键字段）')
        return True, '\n'.join(lines)

    fup = [f.upper() for f in fields]
    si = [sh.index(f) for f in fup if f in sh]
    di = [dh.index(f) for f in fup if f in dh]

    if len(si) != len(fields) or len(di) != len(fields):
        lines.append(f'  L2 checksum: 字段缺失（期望 {len(fields)}，'
                     f'源 {len(si)}，目标 {len(di)}）')
        return False, '\n'.join(lines)

    s_sum = checksum(srows, si)
    d_sum = checksum(drows, di)
    l2 = s_sum == d_sum
    lines.append(f'  L2 checksum: {"PASS" if l2 else "FAIL"}  '
                 f'{s_sum[:10]}... / {d_sum[:10]}...')
    if not l2:
        return False, '\n'.join(lines)

    if level == 'L2':
        return True, '\n'.join(lines)

    # ---- L3 抽样 ----
    n = min(SAMPLE_SIZE, len(srows))
    random.seed(42)
    sample = random.sample(range(len(srows)), n)

    mismatches = []
    for i in sample:
        sr, dr = srows[i], drows[i]
        for f in fup:
            if f not in sh or f not in dh:
                continue
            a = normalize(sr[sh.index(f)]) if sh.index(f) < len(sr) else ''
            b = normalize(dr[dh.index(f)]) if dh.index(f) < len(dr) else ''
            if a != b:
                mismatches.append((i + 2, f, a, b))

    l3 = not mismatches
    lines.append(f'  L3 抽样({n}): {"PASS" if l3 else f"{len(mismatches)} 处不一致"}')
    if mismatches:
        lines.append('               前 5 处:')
        for row, f, a, b in mismatches[:5]:
            lines.append(f'                行{row} {f}: 源="{a}" 目标="{b}"')

    return l1 and l2 and l3, '\n'.join(lines)


def main():
    p = argparse.ArgumentParser(description='三级一致性校验')
    p.add_argument('--level', default='all', choices=['L1', 'L2', 'all'])
    p.add_argument('--mysql-dir', default=os.path.join(EXPORT_DIR, 'mysql'))
    args = p.parse_args()

    print('=' * 70)
    print('  数据一致性校验')
    print('=' * 70)
    print(f'  级别:     {args.level}')
    print(f'  源:       {EXPORT_DIR}')
    print(f'  目标:     {args.mysql_dir}')
    print('=' * 70)
    print()

    if not os.path.isdir(args.mysql_dir):
        print(f'[!] MySQL 导出目录不存在: {args.mysql_dir}')
        print()
        print('    需要先从 MySQL 导出 CSV。示例：')
        print()
        print("    mysql -uroot -p finance -e \"")
        print('      SELECT SUBJECT_CODE, SUBJECT_NAME, SUBJECT_TYPE FROM ACCOUNT_SUBJECT')
        print("      INTO OUTFILE '/tmp/ACCOUNT_SUBJECT.csv'")
        print('      FIELDS TERMINATED BY \',\' ENCLOSED BY \'\"\';"')
        print()
        sys.exit(1)

    results = []
    all_ok = True

    for t in TABLES:
        print(f'--- {t} ---')
        ok, detail = verify_table(t, args.mysql_dir, args.level)
        print(detail)
        print()
        results.append((t, ok))
        if not ok:
            all_ok = False

    print('=' * 70)
    print('  汇总')
    print('=' * 70)
    for t, ok in results:
        print(f'  {t:<22} {"PASS" if ok else "FAIL"}')
    print()

    if all_ok:
        print('[+] 全部通过，可以进入割接阶段')
        sys.exit(0)
    else:
        print('[!] 存在不一致，禁止割接。请先排查')
        sys.exit(1)


if __name__ == '__main__':
    main()
