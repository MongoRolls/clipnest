#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
/usr/bin/python3 - <<'PY'
import pathlib
import re
import sys

# 模块地图是维护者找代码的入口，文件增删或改名后必须同步，否则文档会悄悄过期。
agents = pathlib.Path("AGENTS.md").read_text(encoding="utf-8")
agents_text = re.sub(r"https?://\S+", "", agents)
sources = sorted(pathlib.Path("macOS/Sources").rglob("*.swift"))
names = {source.name for source in sources}
errors = []

for source in sources:
    if source.name not in agents_text:
        errors.append(f"{source} 未写入 AGENTS.md 的模块地图")

for mentioned in sorted(set(re.findall(r"[A-Za-z0-9_+]+\.swift", agents_text))):
    if mentioned not in names and not pathlib.Path(mentioned).exists() \
            and not list(pathlib.Path(".").glob(f"Tests/**/{mentioned}")) \
            and not list(pathlib.Path(".").glob(f"macOS/Tests/**/{mentioned}")):
        errors.append(f"AGENTS.md 提到的 {mentioned} 已不存在")

# 文件名应与其中的主要类型一致；`Type+Topic.swift` 放该类型的扩展。
# 以下文件不以单个类型为中心，集中放同一主题的几个小类型或定义领域命名。
exempt = {
    "main.swift", "AppResources.swift", "L10n.swift", "Models.swift",
    "PanelBackground.swift", "PanelCommands.swift"
}
declaration = r"(?:class|struct|enum|protocol|actor|extension)\s+{}\b"
for source in sources:
    if source.name in exempt:
        continue
    text = source.read_text(encoding="utf-8")
    type_name = source.stem.split("+")[0]
    if not re.search(declaration.format(re.escape(type_name)), text):
        errors.append(f"{source} 中没有名为 {type_name} 的类型或扩展，请让文件名与主要类型一致")

if errors:
    sys.exit("\n".join(errors))
print(f"文档检查通过：{len(sources)} 个源文件均已写入模块地图")
PY
