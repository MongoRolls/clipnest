#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
/usr/bin/python3 - <<'PY'
import ast
import collections
import json
import pathlib
import re
import subprocess
import sys

# 由 Swift 解析注释、转义与多行字面量，再取出 L 的首个实参。
reference = re.compile(r'\(unresolved_decl_ref_expr [^\n]*\bname="L"[^\n]*\n')
literal = re.compile(r'\s*\(argument_list[^\n]*\n\s*\(argument\s*\n\s*\(string_literal_expr [^\n]*?\bvalue=("(?:\\.|[^"\\])*")')
keys = set()
for source in sorted(pathlib.Path("macOS/Sources").rglob("*.swift")):
    parsed = subprocess.run(["xcrun", "swiftc", "-frontend", "-dump-parse", source], capture_output=True, text=True)
    if parsed.stderr.strip():
        print(parsed.stderr.strip(), file=sys.stderr)
    parsed.check_returncode()
    tree = parsed.stdout
    for call in reference.finditer(tree):
        match = literal.match(tree, call.end())
        if not match:
            sys.exit(f"{source} 中 L 的首个参数必须是静态文本，请将变量通过格式参数传入。")
        keys.add(ast.literal_eval(match[1]))
if not keys:
    sys.exit("未从源码中读取到本地化文案。")

table = "macOS/Resources/en.lproj/Localizable.strings"
translations = json.loads(subprocess.check_output(["plutil", "-convert", "json", "-o", "-", table]))
specifier = re.compile(r'%(?:([1-9]\d*)\$)?[-+ #0]*\d*(?:\.\d+)?((?:hh|ll|[hlLzjt])?[@diuoxXfFeEgGaAcCsSp])')

def parameters(value):
    result = collections.Counter()
    offset = 0
    implicit = 0
    while (pos := value.find("%", offset)) >= 0:
        if value.startswith("%%", pos):
            offset = pos + 2
            continue
        match = specifier.match(value, pos)
        if not match:
            raise ValueError(f"无效的格式参数：{value!r}")
        implicit += 1
        result[(int(match[1] or implicit), match[2])] += 1
        offset = match.end()
    return result

errors = [f"缺少英文翻译：{key!r}" for key in sorted(keys - translations.keys())]
errors += [f"多余的英文翻译：{key!r}" for key in sorted(translations.keys() - keys)]
for key in sorted(keys & translations.keys()):
    translation = translations[key]
    if not isinstance(translation, str) or not translation.strip():
        errors.append(f"英文翻译为空：{key!r}")
    elif parameters(key) != parameters(translation):
        errors.append(f"英文格式参数不匹配：{key!r} → {translation!r}")
if errors:
    sys.exit("\n".join(errors))
print(f"已核对 {len(keys)} 条英文翻译及格式参数。")
PY
