"""Сборка воспроизводимого code-only ZIP без конфигурации, ключей и рабочих данных."""

import argparse
import hashlib
import json
import zipfile
from pathlib import Path


def payload_files(star_citizen: Path) -> dict[str, Path]:
    """Возвращает закрытый набор исходников и документов из трёх соседних модулей."""
    result = {}
    modules = {"SC_Discord_Trader": "trader", "SC_Patch_Alerts": "patch_alerts", "SC_Companion": "companion"}
    for folder, package in modules.items():
        root = star_citizen / folder
        for path in sorted((root / package).rglob("*")):
            if path.is_file() and "__pycache__" not in path.parts and path.suffix in {".py", ".html", ".css", ".js"}:
                result[path.relative_to(root).as_posix()] = path
        for name in ("README.md", "DEPLOYMENT.md", "LICENSE", "LICENSE-SCOPE.md", "BRANDING.md", "THIRD_PARTY_NOTICES.md", "SECURITY.md"):
            path = root / name
            if path.exists():
                result[f"component-docs/{folder}/{name}"] = path
    companion = star_citizen / "SC_Companion"
    for name in ("app.py", "README.md", "DEPLOYMENT.md", "patches-config.example.json"):
        result[name] = companion / name
    result["requirements.txt"] = star_citizen / "SC_Discord_Trader/requirements.lock"
    result["LICENSE"] = star_citizen / "SC_Discord_Trader/LICENSE"
    return result


def build(destination: Path) -> dict:
    """Создаёт новый destination ZIP с фиксированными именами/временем и SHA256-манифестом."""
    files = payload_files(Path(__file__).resolve().parent.parent)
    contents = {name: path.read_bytes() for name, path in files.items()}
    manifest = {name: hashlib.sha256(data).hexdigest() for name, data in contents.items()}
    material = json.dumps(manifest, sort_keys=True, separators=(",", ":")).encode()
    fingerprint = hashlib.sha256(material).hexdigest()
    contents["release-manifest.json"] = json.dumps({"release": "SC Companion 0.1.0", "code_only": True,
        "payload_fingerprint": fingerprint, "files": manifest}, ensure_ascii=False, indent=2).encode()
    destination.parent.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(destination, "x", compression=zipfile.ZIP_DEFLATED, compresslevel=9) as archive:
        for name, data in sorted(contents.items()):
            info = zipfile.ZipInfo(name, date_time=(2026, 11, 13, 0, 0, 0))
            info.compress_type = zipfile.ZIP_DEFLATED
            info.external_attr = 0o100644 << 16
            archive.writestr(info, data)
    return {"path": str(destination), "files": len(contents), "bytes": destination.stat().st_size,
            "sha256": hashlib.sha256(destination.read_bytes()).hexdigest(), "payload_fingerprint": fingerprint}


def main() -> None:
    """Принимает новый --out путь вне репозитория и печатает только публичные метаданные."""
    parser = argparse.ArgumentParser(description="Сборка code-only поставки SC Companion")
    parser.add_argument("--out", required=True, type=Path)
    args = parser.parse_args()
    print(json.dumps(build(args.out.resolve()), ensure_ascii=False))


if __name__ == "__main__":
    main()
