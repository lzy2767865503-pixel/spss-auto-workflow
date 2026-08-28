from pathlib import Path


repo = Path(SPECPATH).parent
backend = repo / "backend"
frontend = repo / "frontend" / "dist"

if not (frontend / "index.html").is_file():
    raise SystemExit("Build frontend/dist before running PyInstaller.")

a = Analysis(
    [str(backend / "server.py")],
    pathex=[str(backend)],
    binaries=[],
    datas=[(str(frontend), "frontend/dist")],
    hiddenimports=["openpyxl", "pypdf", "pyreadstat", "waitress", "xlrd"],
    hookspath=[],
    hooksconfig={},
    runtime_hooks=[],
    excludes=[],
    noarchive=False,
    optimize=1,
)
pyz = PYZ(a.pure)

exe = EXE(
    pyz,
    a.scripts,
    [],
    exclude_binaries=True,
    name="statflow-backend",
    debug=False,
    bootloader_ignore_signals=False,
    strip=False,
    upx=False,
    console=True,
    disable_windowed_traceback=False,
)
coll = COLLECT(
    exe,
    a.binaries,
    a.datas,
    strip=False,
    upx=False,
    name="statflow-backend",
)
