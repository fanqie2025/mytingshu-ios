#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""按 iOS App 的 Codable schema 校验订阅书源文件。

为什么需要它
------------
书源侧是用 **Python 复刻引擎**（`mytingshu-sources/tools/rule_engine.py`）验通全部源的，
但 Python 的宽松度和 Swift 的 `JSONDecoder` 不一样。真实事故：
`ListRule.list` 在 Swift 里被声明成**必填**，而 3 个 JSON 模式的源（酷我/书音FM/29听）
根本不写 `list`（它们用 `items`）—— 结果在 App 里**整份订阅导入失败**
（`keyNotFound("list")`，因为 `parseRules` 是整体 decode，一个源抛错 → 一个都写不进去）。
Python 侧当时全绿，完全看不出这个问题。

做法
----
**直接从 `Sources/RuleSource.swift` 解析 schema**，不手抄字段表：
Swift 侧增删字段、改可选性，这个检查自动跟着变，不会漂移。

用法
----
    python3 tools/audit_subscription.py ../sources-private/subscription/sources.json
    python3 tools/audit_subscription.py https://cdn.jsdelivr.net/gh/fanqie2025/mytingshu-sources@main/subscription/sources.json
    python3 tools/audit_subscription.py sources.json --strict     # 未知字段也算失败
    python3 tools/audit_subscription.py sources.json --swift Sources/RuleSource.swift

退出码：0 = 通过；1 = 有必填缺失 / 类型不符（`--strict` 下未知字段也算）。
"""

from __future__ import annotations

import argparse
import json
import re
import sys
import urllib.request
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]
DEFAULT_SWIFT = REPO_ROOT / "Sources" / "RuleSource.swift"
UA = "mytingshu-ios-schema-audit/1.0"


# --------------------------------------------------------------------------
# 1. 从 Swift 源码解析 schema
# --------------------------------------------------------------------------

def classify(swift_type: str):
    """Swift 类型 -> (kind, optional, ref)

    kind: string | bool | int | dict | array | array2 | object | unknown
    ref : object/array 元素所指的 struct 名
    """
    t = swift_type.strip().rstrip("{").strip()
    optional = t.endswith("?")
    if optional:
        t = t[:-1].strip()

    if t == "String":
        return "string", optional, None
    if t == "Bool":
        return "bool", optional, None
    if t == "Int":
        return "int", optional, None
    if t.startswith("[String: String]"):
        return "dict", optional, None
    if t.startswith("[["):
        return "array2", optional, None
    m = re.fullmatch(r"\[(\w+)\]", t)
    if m:
        return "array", optional, m.group(1)
    m = re.fullmatch(r"(\w+)", t)
    if m:
        return "object", optional, m.group(1)
    return "unknown", optional, None


def parse_swift_schema(path: Path):
    """返回 (schema, unknown_types)

    schema = { structName: { fieldName: (kind, optional, ref) } }
    """
    text = path.read_text(encoding="utf-8")
    text = re.sub(r"/\*.*?\*/", "", text, flags=re.S)          # 去块注释

    schema: dict[str, dict[str, tuple]] = {}
    unknown: list[str] = []
    stack: list[str] = []

    for raw in text.splitlines():
        line = raw.split("//")[0].strip()                       # 去行注释
        if not line:
            continue

        m = re.match(r"^(?:public\s+|private\s+|internal\s+)?struct\s+(\w+)", line)
        if m:
            name = m.group(1)
            schema.setdefault(name, {})
            if "{" in line:
                stack.append(name)
            continue

        if line.startswith("}"):
            if stack:
                stack.pop()
            continue

        m = re.match(r"^(?:var|let)\s+(`?\w+`?)\s*:\s*(.+)$", line)
        if m and stack:
            field = m.group(1).strip("`")
            kind, optional, ref = classify(m.group(2))
            if kind == "unknown":
                unknown.append(f"{stack[-1]}.{field}: {m.group(2).strip()}")
            schema[stack[-1]][field] = (kind, optional, ref)

    return schema, unknown


# --------------------------------------------------------------------------
# 2. 校验
# --------------------------------------------------------------------------

def kind_ok(kind: str, value) -> bool:
    if kind == "string":
        return isinstance(value, str)
    if kind == "bool":
        return isinstance(value, bool)
    if kind == "int":
        # 注意：Python 里 bool 是 int 的子类，JSON 的 true 不能当数字
        return isinstance(value, int) and not isinstance(value, bool)
    if kind in ("dict", "object"):
        return isinstance(value, dict)
    if kind in ("array", "array2"):
        return isinstance(value, list)
    return True


class Audit:
    def __init__(self, schema: dict, strict: bool):
        self.schema = schema
        self.strict = strict
        self.problems: list[str] = []
        self.warnings: list[str] = []

    # 单个对象（对应一个 struct）
    def check_object(self, obj: dict, struct: str, where: str):
        fields = self.schema.get(struct)
        if fields is None:
            self.warnings.append(f"{where}: Swift 里没有 struct {struct}（跳过）")
            return

        for key, (kind, optional, ref) in fields.items():
            if key not in obj:
                if not optional:
                    self.problems.append(f"{where}: 缺必填字段 {struct}.{key}")
                continue

            value = obj[key]
            if value is None:
                continue

            if not kind_ok(kind, value):
                self.problems.append(
                    f"{where}: {struct}.{key} 类型不符 —— 期望 {kind}，实际 "
                    f"{type(value).__name__}（{json.dumps(value, ensure_ascii=False)[:60]}）"
                )
                continue

            if kind == "object":
                self.check_object(value, ref, f"{where}.{key}")
            elif kind == "array":
                for i, item in enumerate(value):
                    if isinstance(item, dict):
                        self.check_object(item, ref, f"{where}.{key}[{i}]")
            elif kind == "dict":
                for k, v in value.items():
                    if not isinstance(v, str):
                        self.problems.append(
                            f"{where}: {struct}.{key}.{k} 的值必须是字符串，实际 {type(v).__name__}"
                        )
            elif kind == "array2":
                for i, row in enumerate(value):
                    if not isinstance(row, list) or not all(isinstance(x, str) for x in row):
                        self.problems.append(
                            f"{where}: {struct}.{key}[{i}] 必须是字符串数组"
                        )

        # 未知字段：Codable 会静默忽略，通常意味着**拼写错误**
        for key in obj:
            if key not in fields:
                self.warnings.append(f"{where}: 未知字段 {struct}.{key}（Swift 会忽略它，八成是拼错了）")


def load_json(source: str):
    if re.match(r"^https?://", source):
        req = urllib.request.Request(source, headers={"User-Agent": UA})
        with urllib.request.urlopen(req, timeout=30) as resp:
            return json.loads(resp.read().decode("utf-8"))
    return json.loads(Path(source).read_text(encoding="utf-8"))


def main() -> int:
    ap = argparse.ArgumentParser(description="按 iOS Codable schema 校验订阅书源")
    ap.add_argument("sources", help="sources.json 的路径或 URL")
    ap.add_argument("--swift", default=str(DEFAULT_SWIFT), help="RuleSource.swift 路径")
    ap.add_argument("--strict", action="store_true", help="未知字段也算失败")
    args = ap.parse_args()

    swift_path = Path(args.swift)
    if not swift_path.exists():
        print(f"❌ 找不到 {swift_path}（用 --swift 指定）", file=sys.stderr)
        return 2

    schema, unknown_types = parse_swift_schema(swift_path)
    if "SourceRule" not in schema:
        print("❌ 没能从 Swift 里解析出 SourceRule —— 解析规则可能要跟着源码更新", file=sys.stderr)
        return 2

    try:
        data = load_json(args.sources)
    except Exception as e:                                     # noqa: BLE001
        print(f"❌ 读取书源失败：{e}", file=sys.stderr)
        return 2

    # 裸数组 或 {"sources": [...]}
    if isinstance(data, dict):
        rules = data.get("sources") or data.get("rules") or []
    else:
        rules = data

    if not isinstance(rules, list) or not rules:
        print("❌ 没解析到任何书源条目", file=sys.stderr)
        return 2

    audit = Audit(schema, args.strict)
    for i, rule in enumerate(rules):
        if not isinstance(rule, dict):
            audit.problems.append(f"[{i}]: 条目不是对象")
            continue
        label = f"[{i}]{rule.get('id', '?')}"
        audit.check_object(rule, "SourceRule", label)

    print(f"检查 {len(rules)} 个源（schema 来自 {swift_path.name}）")
    if unknown_types:
        print(f"  （schema 里有 {len(unknown_types)} 个未识别的 Swift 类型，已跳过：{', '.join(unknown_types)}）")

    for w in audit.warnings:
        print(f"  ⚠️  {w}")
    for p in audit.problems:
        print(f"  ❌ {p}")

    if audit.problems or (args.strict and audit.warnings):
        print(f"\n❌ 不通过：{len(audit.problems)} 个必填/类型问题，{len(audit.warnings)} 个可疑字段")
        return 1

    print(f"\n✅ 通过：{len(rules)} 个源都能被 App 的 JSONDecoder 解出来"
          f"（{len(audit.warnings)} 个可疑字段未阻塞）")
    return 0


if __name__ == "__main__":
    sys.exit(main())
