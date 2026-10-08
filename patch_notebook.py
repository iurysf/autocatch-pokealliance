"""Instala o AutoCatch PKA sobre os clientes oficiais de 26/09 e 28/09/2026."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import shutil
import sys
import tempfile
from pathlib import Path, PurePosixPath


PACKAGE_DIR = Path(__file__).resolve().parent
BUILD_TAG = "20261007"


class PatchError(RuntimeError):
    pass


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def load_json(path: Path) -> dict:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise PatchError(f"Nao foi possivel ler {path.name}: {exc}") from exc


def is_within(root: Path, path: Path) -> bool:
    root_text = os.path.normcase(str(root.resolve()))
    path_text = os.path.normcase(str(path.resolve()))
    try:
        return os.path.commonpath((root_text, path_text)) == root_text
    except ValueError:
        return False


def safe_relative_path(value: str) -> Path:
    posix = PurePosixPath(value)
    if posix.is_absolute() or not posix.parts or any(part in ("", ".", "..") for part in posix.parts):
        raise PatchError(f"Caminho inseguro no manifesto: {value}")
    return Path(*posix.parts)


def load_payload(target_root: Path, manifest: dict) -> list[dict]:
    entries = manifest.get("files")
    if not isinstance(entries, list) or not entries:
        raise PatchError("O manifesto de modulos esta vazio ou invalido.")

    planned = []
    seen = set()
    for entry in entries:
        relative = safe_relative_path(entry.get("path", ""))
        key = os.path.normcase(str(relative))
        if key in seen:
            raise PatchError(f"Arquivo duplicado no manifesto: {relative}")
        seen.add(key)

        source = PACKAGE_DIR / relative
        destination = target_root / relative
        if not is_within(PACKAGE_DIR, source) or not source.is_file():
            raise PatchError(f"Arquivo do pacote ausente: {relative}")
        if not is_within(target_root, destination):
            raise PatchError(f"Destino fora da pasta do cliente: {relative}")

        content = source.read_bytes()
        if len(content) != entry.get("size") or sha256(content) != entry.get("sha256"):
            raise PatchError(f"Arquivo do pacote foi alterado ou esta incompleto: {relative}")
        if destination.exists() and not destination.is_file():
            raise PatchError(f"O destino nao e um arquivo regular: {relative}")

        old_content = destination.read_bytes() if destination.is_file() else None
        action = "skip" if old_content == content else "copy"
        planned.append({
            "relative": relative,
            "destination": destination,
            "content": content,
            "old_content": old_content,
            "action": action,
        })
    return planned


def select_build(name: str, original: bytes, specs) -> tuple[dict, str]:
    """Returns the build spec matching the file and whether it is already patched."""
    if isinstance(specs, dict):
        specs = [specs]
    current_hash = sha256(original)
    for spec in specs:
        if len(original) != spec.get("size"):
            continue
        if current_hash == spec.get("patchedSha256"):
            return spec, "patched"
        if current_hash == spec.get("officialSha256"):
            return spec, "official"
    builds = ", ".join(str(spec.get("build", "?")) for spec in specs)
    raise PatchError(f"Build nao suportado para {name} (aceitos: {builds}); aguarde um patch compativel.")


def prepare_executables(target_root: Path, build: dict) -> list[dict]:
    planned = []
    for name, specs in build.get("executables", {}).items():
        path = target_root / name
        if not path.exists():
            if name == "PokeAlliance_gl.exe":
                raise PatchError(f"Executavel obrigatorio nao encontrado: {name}")
            print(f"[i] {name} ausente; DX sera ignorado.")
            continue
        if not path.is_file():
            raise PatchError(f"O destino nao e um arquivo regular: {name}")

        original = path.read_bytes()
        spec, state = select_build(name, original, specs)
        current_hash = sha256(original)
        print(f"[i] {name}: build oficial {spec.get('build', '?')} ({'ja patchado' if state == 'patched' else 'original'}).")
        if state == "patched":
            planned.append({"path": path, "name": name, "action": "skip", "old": original})
            continue

        patched = bytearray(original)
        for item in spec.get("patches", []):
            offset = item.get("offset")
            expected = bytes.fromhex(item.get("expected", ""))
            replacement = bytes.fromhex(item.get("replacement", ""))
            if not isinstance(offset, int) or offset < 0 or not expected or len(expected) != len(replacement):
                raise PatchError(f"Delta binario invalido para {name}.")
            end = offset + len(expected)
            if end > len(patched) or bytes(patched[offset:end]) != expected:
                raise PatchError(f"Assinatura inesperada em {name} no offset 0x{offset:X}.")
            patched[offset:end] = replacement

        result = bytes(patched)
        if sha256(result) != spec.get("patchedSha256"):
            raise PatchError(f"Verificacao final do patch falhou para {name}; nada foi gravado.")
        planned.append({
            "path": path,
            "name": name,
            "action": "patch",
            "old": original,
            "content": result,
            "inputSha256": current_hash,
        })
    return planned


def unique_backup_path(path: Path, suffix: str, expected_hash: str) -> Path | None:
    first = path.with_name(path.name + suffix)
    if not first.exists():
        return first
    if first.is_file() and sha256(first.read_bytes()) == expected_hash:
        return None
    index = 2
    while True:
        candidate = path.with_name(path.name + suffix + f"-{index}")
        if not candidate.exists():
            return candidate
        if candidate.is_file() and sha256(candidate.read_bytes()) == expected_hash:
            return None
        index += 1


def module_backup_path(target_root: Path, relative: Path, content: bytes) -> Path | None:
    backup = target_root / "_pka_patch_backup" / BUILD_TAG / relative
    if not backup.exists():
        return backup
    if backup.is_file() and sha256(backup.read_bytes()) == sha256(content):
        return None
    index = 2
    while True:
        candidate = backup.with_name(backup.name + f"-{index}")
        if not candidate.exists():
            return candidate
        if candidate.is_file() and sha256(candidate.read_bytes()) == sha256(content):
            return None
        index += 1


def save_backup(source: Path, backup: Path | None) -> None:
    if backup is None:
        return
    backup.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(source, backup)


def atomic_write(path: Path, content: bytes) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, temporary_name = tempfile.mkstemp(prefix=path.name + ".", suffix=".pka-tmp", dir=str(path.parent))
    try:
        with os.fdopen(fd, "wb") as stream:
            stream.write(content)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary_name, path)
    except Exception:
        try:
            os.unlink(temporary_name)
        except OSError:
            pass
        raise


def rollback(written: list[tuple[Path, bytes | None]]) -> list[str]:
    failures = []
    for path, old_content in reversed(written):
        try:
            if old_content is None:
                path.unlink(missing_ok=True)
            else:
                atomic_write(path, old_content)
        except OSError as exc:
            failures.append(f"{path}: {exc}")
    return failures


def default_target_dir() -> Path | None:
    current = Path.cwd()
    if (current / "PokeAlliance_gl.exe").is_file():
        return current
    local_app_data = os.environ.get("LOCALAPPDATA")
    if local_app_data:
        candidate = Path(local_app_data) / "PokeAlliance Games" / "PokeAlliance"
        if (candidate / "PokeAlliance_gl.exe").is_file():
            return candidate
    return None


def create_desktop_shortcut(target_exe: Path) -> bool:
    """Cria 'PokeAlliance AutoCatch.lnk' na Area de Trabalho (falha nao interrompe a instalacao)."""
    import subprocess
    script = (
        "$shell = New-Object -ComObject WScript.Shell; "
        "$link = $shell.CreateShortcut([IO.Path]::Combine([Environment]::GetFolderPath('Desktop'), 'PokeAlliance AutoCatch.lnk')); "
        f"$link.TargetPath = '{target_exe}'; "
        f"$link.WorkingDirectory = '{target_exe.parent}'; "
        "$link.Description = 'PokeAlliance com AutoCatch'; "
        "$link.Save()"
    )
    try:
        subprocess.run(["powershell", "-NoProfile", "-Command", script], check=True,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        print("[OK] Atalho 'PokeAlliance AutoCatch' criado na Area de Trabalho.")
        return True
    except (OSError, subprocess.CalledProcessError):
        print("[i] Nao foi possivel criar o atalho; abra PokeAlliance_gl.exe diretamente.")
        return False


def main() -> int:
    parser = argparse.ArgumentParser(description="Instalador do AutoCatch PKA")
    parser.add_argument("--target-dir", help="Pasta do cliente que contem PokeAlliance_gl.exe")
    parser.add_argument("--dry-run", action="store_true", help="Verifica os arquivos sem alterar o cliente")
    parser.add_argument("--sem-atalho", action="store_true", help="Nao cria o atalho na Area de Trabalho")
    args = parser.parse_args()

    target_root = Path(args.target_dir).expanduser().resolve() if args.target_dir else default_target_dir()
    if target_root is None:
        entered = input("Informe a pasta do cliente que contem PokeAlliance_gl.exe: ").strip().strip('"')
        target_root = Path(entered).expanduser().resolve()
    if not target_root.is_dir():
        print("[ERRO] Pasta do cliente invalida.")
        return 1

    try:
        build = load_json(PACKAGE_DIR / "binary_patch.json")
        manifest = load_json(PACKAGE_DIR / "files_manifest.json")
        if build.get("buildTag") != BUILD_TAG or manifest.get("buildTag") != BUILD_TAG:
            raise PatchError("Os manifestos nao correspondem ao build deste instalador.")
        executable_plan = prepare_executables(target_root, build)
        module_plan = load_payload(target_root, manifest)
    except (PatchError, OSError, ValueError) as exc:
        print(f"[ERRO] {exc}")
        return 1

    exe_patches = [item for item in executable_plan if item["action"] == "patch"]
    module_copies = [item for item in module_plan if item["action"] == "copy"]
    print(f"Cliente: {target_root}")
    print(f"Executaveis a patchar: {len(exe_patches)}; modulos a copiar: {len(module_copies)} de {len(module_plan)} arquivos.")
    if args.dry_run:
        print("[OK] Preflight concluido; nenhum arquivo foi alterado.")
        return 0

    # Gera todos os backups antes da primeira alteracao.
    try:
        for item in exe_patches:
            backup = unique_backup_path(item["path"], ".original", sha256(item["old"]))
            save_backup(item["path"], backup)
        for item in module_copies:
            if item["old_content"] is None:
                continue
            backup = module_backup_path(target_root, item["relative"], item["old_content"])
            if backup is not None:
                backup.parent.mkdir(parents=True, exist_ok=True)
                backup.write_bytes(item["old_content"])
    except OSError as exc:
        print(f"[ERRO] Falha ao criar backup; o cliente nao foi alterado: {exc}")
        return 1

    written: list[tuple[Path, bytes | None]] = []
    try:
        for item in module_copies:
            path = item["destination"]
            previous = item["old_content"]
            if previous is None:
                if path.exists():
                    raise PatchError(f"Arquivo apareceu durante a instalacao: {item['relative']}")
            elif not path.is_file() or sha256(path.read_bytes()) != sha256(previous):
                raise PatchError(f"Arquivo mudou durante a instalacao: {item['relative']}")
            atomic_write(path, item["content"])
            written.append((path, previous))

        for item in exe_patches:
            path = item["path"]
            if not path.is_file() or sha256(path.read_bytes()) != item["inputSha256"]:
                raise PatchError(f"{item['name']} mudou durante a instalacao.")
            atomic_write(path, item["content"])
            written.append((path, item["old"]))
    except Exception as exc:
        failures = rollback(written)
        print(f"[ERRO] Instalacao interrompida: {exc}")
        if failures:
            print("[FATAL] Nao foi possivel restaurar todos os arquivos:")
            for failure in failures:
                print("  " + failure)
        else:
            print("[OK] Arquivos alterados nesta tentativa foram restaurados.")
        return 1

    print("[OK] AutoCatch instalado.")
    print("[i] Backups dos modulos: _pka_patch_backup\\" + BUILD_TAG)
    if not args.sem_atalho:
        create_desktop_shortcut(target_root / "PokeAlliance_gl.exe")
    print("[i] Abra o jogo pelo atalho 'PokeAlliance AutoCatch' ou pelo PokeAlliance_gl.exe;")
    print("    nao use o launcher oficial, que restaura os arquivos originais.")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except KeyboardInterrupt:
        print("\n[ERRO] Instalacao cancelada.")
        raise SystemExit(130)
