"""
Patcher Automatico para PokeAlliance - Versao Notebook
Aplica o patch de AES-256 e Unencrypted Fallback diretamente no executavel oficial.
Permite carregar o modulo AutoCatch sem precisar descompactar os 2 GB de sprites.

Build suportado: executaveis oficiais de 20/09/2026
  PokeAlliance_gl.exe  36.114.480 bytes
  PokeAlliance_dx.exe  35.881.008 bytes

Patches aplicados em cada executavel:
  discoverWorkDir   -> mov al, 1; ret   (aceita a pasta de trabalho sem validar AES)
  moduleManager     -> mov al, 1; ret   (aceita modulos em texto puro)
  log_branch        -> jmp               (evita crash de rotacao de log com varios clientes)
  _k_xcd            -> injeta a chave AES-256 extraida do cliente oficial
  extension_check   -> jmp               (le arquivos sem assinatura PKA1 como texto puro)
  v3_fallback       -> mov r8d, 14 + string "PokeAllianceV3" no lugar de "otclientv8"
                       (mantem contas, hotkeys e perfis em %APPDATA%\\PokeAlliance\\PokeAllianceV3)
"""

import os
import sys
import struct
import shutil
import hashlib

BUILD_TAG = '20260920'

def log(msg):
    print(f"[*] {msg}")

def error(msg):
    print(f"[!] ERRO: {msg}")

def success(msg):
    print(f"[+] SUCESSO: {msg}")

def has_autocatch_module(directory):
    return bool(directory) and os.path.isdir(os.path.join(directory, 'modules', 'game_autocatch'))

def find_source_dir():
    script_dir = os.path.dirname(os.path.abspath(__file__))
    parent_dir = os.path.dirname(script_dir)
    candidates = [
        os.environ.get('AUTOCATCH_PACKAGE_DIR'),
        script_dir,
        os.path.join(parent_dir, 'autocatch-pka'),
        os.path.join(parent_dir, 'PACOTE_NOTEBOOK_AUTOCATCH'),
        os.path.join(os.getcwd(), 'autocatch-pka'),
        os.path.join(os.getcwd(), 'PACOTE_NOTEBOOK_AUTOCATCH')
    ]
    seen = set()
    for candidate in candidates:
        if not candidate:
            continue
        resolved = os.path.abspath(candidate)
        key = os.path.normcase(resolved)
        if key in seen:
            continue
        seen.add(key)
        if has_autocatch_module(resolved):
            return resolved
    return None

def get_official_dir():
    current_dir = os.path.abspath('.')
    if os.path.exists(os.path.join(current_dir, 'PokeAlliance_gl.exe')):
        return current_dir

    local_app_data = os.environ.get('LOCALAPPDATA', '')
    if local_app_data:
        pka_dir = os.path.join(local_app_data, 'PokeAlliance Games', 'PokeAlliance')
        if os.path.exists(pka_dir) and os.path.exists(os.path.join(pka_dir, 'PokeAlliance_gl.exe')):
            return pka_dir

    return None

def build_key_payload():
    KEY_HEX = '4134b92fc9efc14977d582971a767931889000d4456c2443eb1b40732c60cd3e'
    key_bytes = bytes.fromhex(KEY_HEX)
    p1, p2, p3, p4 = struct.unpack('<QQQQ', key_bytes)

    payload = bytearray()
    payload += bytes([0xc6, 0x81, 0xb8, 0x00, 0x00, 0x00, 0x01])
    payload += bytes([0x48, 0xb8]) + struct.pack('<Q', p1)
    payload += bytes([0x48, 0x89, 0x81, 0xb9, 0x00, 0x00, 0x00])
    payload += bytes([0x48, 0x89, 0x02])
    payload += bytes([0x48, 0xb8]) + struct.pack('<Q', p2)
    payload += bytes([0x48, 0x89, 0x81, 0xc1, 0x00, 0x00, 0x00])
    payload += bytes([0x48, 0x89, 0x42, 0x08])
    payload += bytes([0x48, 0xb8]) + struct.pack('<Q', p3)
    payload += bytes([0x48, 0x89, 0x81, 0xc9, 0x00, 0x00, 0x00])
    payload += bytes([0x48, 0x89, 0x42, 0x10])
    payload += bytes([0x48, 0xb8]) + struct.pack('<Q', p4)
    payload += bytes([0x48, 0x89, 0x81, 0xd1, 0x00, 0x00, 0x00])
    payload += bytes([0x48, 0x89, 0x42, 0x18])
    payload += bytes([0xb0, 0x01, 0xc3])
    return bytes(payload)

# Patches comuns aos dois executaveis (bytes identicos, offsets diferentes).
RET_TRUE = b'\xb0\x01\xc3'                                  # mov al, 1; ret
LOG_BRANCH_ORIG = bytes.fromhex('0f86cf030000')             # jbe rel32
LOG_BRANCH_PATCH = bytes.fromhex('e9ff03000090')            # jmp rel32; nop
EXT_CHECK_PATCH = bytes.fromhex('e91c0300009090')           # jmp rel32; nop; nop
V3_MOV_ORIG = bytes.fromhex('41b80a000000')                 # mov r8d, 10  (len "otclientv8")
V3_MOV_PATCH = bytes.fromhex('41b80e000000')                # mov r8d, 14  (len "PokeAllianceV3")
V3_STR_ORIG = b'otclientv8\x00\x00\x00\x00\x00\x00'
V3_STR_PATCH = b'PokeAllianceV3\x00\x00'

def patch_binary(target_path, backup_path, label, expected_size, patches):
    """Patch only the known executable build and verify every replacement."""
    log(f"Lendo {label}...")
    try:
        with open(target_path, 'rb') as f:
            current = bytearray(f.read())
    except OSError as exc:
        error(f"Nao foi possivel ler {label}: {exc}")
        return False

    if len(current) != expected_size:
        error(f"Build desconhecido para {label}: tamanho {len(current)} (esperado {expected_size}, build {BUILD_TAG}). Nenhum patch aplicado.")
        return False

    already_patched = all(
        current[offset:offset + len(replacement)] == replacement
        for offset, expected, replacement in patches
    )
    if already_patched:
        log(f"{label} ja esta patchado e sera preservado.")
        return True

    mismatches = [
        f"0x{offset:X}"
        for offset, expected, replacement in patches
        if current[offset:offset + len(expected)] != expected
    ]
    if mismatches:
        error(f"Build desconhecido para {label}; assinaturas invalidas em {', '.join(mismatches)}. Nenhum patch aplicado.")
        return False

    if not os.path.exists(backup_path):
        log(f"Criando backup em: {backup_path}")
        try:
            shutil.copy2(target_path, backup_path)
        except OSError as exc:
            error(f"Nao foi possivel criar backup de {label}: {exc}")
            return False
    else:
        try:
            with open(backup_path, 'rb') as f:
                backup = f.read()
            if backup != bytes(current):
                # O backup .original pertence a um build anterior (o launcher atualizou o cliente).
                # Guarda tambem uma copia intacta deste build para nunca perder o original.
                versioned_backup = f"{backup_path}-{BUILD_TAG}"
                log(f"Aviso: backup existente de {label} pertence a outro build; guardando copia original em: {versioned_backup}")
                if not os.path.exists(versioned_backup):
                    shutil.copy2(target_path, versioned_backup)
        except OSError as exc:
            error(f"Nao foi possivel validar backup de {label}: {exc}")
            return False

    data = bytearray(current)
    log(f"Aplicando patches em {label} (AES Key + Fallback de arquivos abertos + pasta PokeAllianceV3)...")
    for offset, expected, replacement in patches:
        data[offset:offset + len(replacement)] = replacement

    if not all(
        data[offset:offset + len(replacement)] == replacement
        for offset, expected, replacement in patches
    ):
        error(f"Falha na verificacao dos patches de {label}; arquivo nao sera gravado.")
        return False

    try:
        with open(target_path, 'wb') as f:
            f.write(data)
    except PermissionError:
        error(f"Nao foi possivel escrever no {label}. Certifique-se de que o jogo esta FECHADO antes de rodar o patcher!")
        return False
    except OSError as exc:
        error(f"Nao foi possivel escrever no {label}: {exc}")
        return False

    digest = hashlib.sha256(bytes(data)).hexdigest()[:16]
    success(f"{label} patchado com sucesso! SHA-256 inicial: {digest}...")
    return True

def patch_gl(target_dir):
    gl_path = os.path.join(target_dir, "PokeAlliance_gl.exe")
    if not os.path.exists(gl_path):
        error(f"PokeAlliance_gl.exe nao encontrado em {target_dir}")
        return False

    backup_path = os.path.join(target_dir, "PokeAlliance_gl.exe.original")
    key_payload = build_key_payload()
    # Build oficial de 20/09/2026 (36.114.480 bytes)
    patches = [
        (0x593f20, bytes.fromhex('48895c'), RET_TRUE),                       # discoverWorkDir
        (0x594070, bytes.fromhex('4c8bdc'), RET_TRUE),                       # moduleManager
        (0x584b27, LOG_BRANCH_ORIG, LOG_BRANCH_PATCH),                       # log_branch (multi-cliente)
        (0x595b70, bytes.fromhex('48895c241848897424205557415441564157488d6c24c94881ec00010000488b05abe8a7014833c448894527488bfa488bd94533e444896424204c8d79684c897d8f498bcfe8d6791b0185c00f85a30800008b83b40000003dffffff7f'), key_payload),  # _k_xcd
        (0x597d8d, bytes.fromhex('488d15fc281f03'), EXT_CHECK_PATCH),        # extension_check (plaintext)
        (0x58ff02, V3_MOV_ORIG, V3_MOV_PATCH),                               # v3_fallback: tamanho do APP_NAME
        (0x1ddcdc0, V3_STR_ORIG, V3_STR_PATCH),                              # v3_fallback: "PokeAllianceV3"
    ]
    return patch_binary(gl_path, backup_path, 'PokeAlliance_gl.exe', 36114480, patches)

def patch_dx(target_dir):
    dx_path = os.path.join(target_dir, "PokeAlliance_dx.exe")
    if not os.path.exists(dx_path):
        log("PokeAlliance_dx.exe nao encontrado; patch DX ignorado.")
        return True

    backup_path = os.path.join(target_dir, "PokeAlliance_dx.exe.original")
    key_payload = build_key_payload()
    # Build oficial de 20/09/2026 (35.881.008 bytes)
    patches = [
        (0x512d80, bytes.fromhex('48895c'), RET_TRUE),                       # discoverWorkDir
        (0x512ed0, bytes.fromhex('4c8bdc'), RET_TRUE),                       # moduleManager
        (0x507837, LOG_BRANCH_ORIG, LOG_BRANCH_PATCH),                       # log_branch (multi-cliente)
        (0x5149d0, bytes.fromhex('48895c241848897424205557415441564157488d6c24c94881ec00010000488b054bbaac014833c448894527488bfa488bd94533e444896424204c8d79684c897d8f498bcfe8e6cb210185c00f85a30800008b83b40000003dffffff7f'), key_payload),  # _k_xcd
        (0x51fa3d, bytes.fromhex('488d155cd12203'), EXT_CHECK_PATCH),        # extension_check (plaintext)
        (0x50ed42, V3_MOV_ORIG, V3_MOV_PATCH),                               # v3_fallback: tamanho do APP_NAME
        (0x1da55e8, V3_STR_ORIG, V3_STR_PATCH),                              # v3_fallback: "PokeAllianceV3"
    ]
    return patch_binary(dx_path, backup_path, 'PokeAlliance_dx.exe', 35881008, patches)

def copy_autocatch(source_dir, target_dir):
    src_mod = os.path.join(source_dir, "modules", "game_autocatch")
    if not os.path.exists(src_mod):
        error(f"Modulo game_autocatch nao encontrado em: {src_mod}")
        return False

    dst_mod = os.path.join(target_dir, "modules", "game_autocatch")
    if os.path.normcase(os.path.abspath(src_mod)) == os.path.normcase(os.path.abspath(dst_mod)):
        log("Modulo AutoCatch ja esta na pasta do jogo; nenhuma copia necessaria.")
        return True
    log(f"Copiando modulo AutoCatch para {dst_mod}...")
    if os.path.exists(dst_mod):
        shutil.rmtree(dst_mod)
    shutil.copytree(src_mod, dst_mod)
    success("Modulo AutoCatch copiado com sucesso!")

    src_buffs = os.path.join(source_dir, "modules", "game_buffs", "playerbuffs.lua")
    if os.path.exists(src_buffs):
        dst_buffs_dir = os.path.join(target_dir, "modules", "game_buffs")
        os.makedirs(dst_buffs_dir, exist_ok=True)
        shutil.copy2(src_buffs, os.path.join(dst_buffs_dir, "playerbuffs.lua"))
        success("API de buffs do Auto Item copiada com sucesso!")
    return True

def create_desktop_shortcut(target_exe):
    try:
        import win32com.client
        desktop = os.path.join(os.environ['USERPROFILE'], 'Desktop')
        shortcut_path = os.path.join(desktop, "PokeAlliance AutoCatch.lnk")
        shell = win32com.client.Dispatch("WScript.Shell")
        shortcut = shell.CreateShortCut(shortcut_path)
        shortcut.TargetPath = target_exe
        shortcut.WorkingDirectory = os.path.dirname(target_exe)
        shortcut.Description = "PokeAlliance com AutoCatch"
        shortcut.save()
        success(f"Atalho criado na Area de Trabalho: {shortcut_path}")
        return True
    except Exception:
        import subprocess
        ps_script = f'''
        $WshShell = New-Object -comObject WScript.Shell
        $Shortcut = $WshShell.CreateShortcut("$([Environment]::GetFolderPath('Desktop'))\\PokeAlliance AutoCatch.lnk")
        $Shortcut.TargetPath = "{target_exe}"
        $Shortcut.WorkingDirectory = "{os.path.dirname(target_exe)}"
        $Shortcut.Description = "PokeAlliance com AutoCatch"
        $Shortcut.Save()
        '''
        try:
            subprocess.run(["powershell", "-Command", ps_script], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            success("Atalho criado na Area de Trabalho via PowerShell!")
            return True
        except Exception:
            return False

def main():
    print("=" * 65)
    print("    INSTALADOR LEVE DO AUTOCATCH PKA PARA WINDOWS")
    print(f"    Compativel com o cliente oficial de 20/09/2026 (build {BUILD_TAG})")
    print("=" * 65)

    target_dir = get_official_dir()
    if not target_dir:
        print("\n[?] Pasta oficial do PokeAlliance nao encontrada automaticamente.")
        target_dir = input("Digite o caminho completo da pasta do jogo (onde esta o PokeAlliance_gl.exe): ").strip('"')
        if not os.path.exists(os.path.join(target_dir, 'PokeAlliance_gl.exe')):
            error("Diretorio invalido ou PokeAlliance_gl.exe nao encontrado.")
            sys.exit(1)

    base_dir = find_source_dir()
    if not base_dir:
        print("\n[?] Pasta do pacote AutoCatch nao encontrada automaticamente.")
        base_dir = input("Digite o caminho completo da pasta do pacote (a pasta que contem modules\\game_autocatch): ").strip().strip('"')
        if not has_autocatch_module(base_dir):
            error("Origem invalida ou modules\\game_autocatch nao encontrado.")
            sys.exit(1)

    base_dir = os.path.abspath(base_dir)

    log(f"Diretorio do jogo oficial detectado:\n    {target_dir}\n")

    ok_gl = patch_gl(target_dir)
    patch_dx(target_dir)

    if not ok_gl:
        error("Falha ao aplicar o patch.")
        sys.exit(1)

    ok_mod = copy_autocatch(base_dir, target_dir)
    if not ok_mod:
        error("Falha ao copiar o modulo do AutoCatch.")
        sys.exit(1)

    target_exe = os.path.join(target_dir, "PokeAlliance_gl.exe")
    create_desktop_shortcut(target_exe)

    print("\n" + "=" * 65)
    success("INSTALACAO CONCLUIDA COM SUCESSO!")
    print("=" * 65)
    print("\nCOMO USAR:")
    print("1. Inicie o jogo pelo atalho 'PokeAlliance AutoCatch' na sua Area de Trabalho.")
    print("2. AVISO: NAO abra pelo Launcher oficial, pois o Launcher restaurara os arquivos originais.")
    print("3. O AutoCatch estara ativo e pronto para uso no topo da tela do jogo.")
    print("=" * 65)

if __name__ == '__main__':
    main()
