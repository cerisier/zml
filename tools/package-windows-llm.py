#!/usr/bin/env python3
"""Package the Windows LLM and CPU runfiles for native inference smoke tests."""

import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import tempfile
import zipfile


def sha256(path):
    with path.open('rb') as source:
        return hashlib.file_digest(source, 'sha256').hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--executable', type=Path, default=Path('bazel-bin/examples/llm/llm.exe'))
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    executable = args.executable.resolve(strict=True)
    manifest = executable.with_name(executable.name + '.runfiles_manifest')
    entries = dict(line.split(' ', 1) for line in manifest.read_text().splitlines())
    sandbox = Path(entries['_main/platforms/cpu/sandbox'])
    mapping = Path(entries['_repo_mapping'])
    plugin = sandbox / 'lib/libzml_cpu.dll'
    # Fail before producing an archive if required remote outputs are not materialized.
    for path in (executable, plugin, mapping):
        if not path.is_file():
            raise FileNotFoundError(path)

    with tempfile.TemporaryDirectory(prefix='zml-windows-package-') as temporary:
        root = Path(temporary)
        shutil.copyfile(executable, root / 'llm.exe')
        # Strip only the packaged copy; preserve Bazel's original output.
        subprocess.run(['llvm', 'strip', '--strip-debug', str(root / 'llm.exe')], check=True)
        runfiles = root / 'llm.exe.runfiles'
        (runfiles / '_main/platforms/cpu/sandbox/lib').mkdir(parents=True)
        shutil.copyfile(plugin, runfiles / '_main/platforms/cpu/sandbox/lib/libzml_cpu.dll')
        shutil.copyfile(mapping, runfiles / '_repo_mapping')
        source_diff = subprocess.check_output(['git', 'diff', 'HEAD', '--', '*.zig', '*.bzl', '*BUILD.bazel', 'MODULE.bazel'])
        info = {
            'source_head': subprocess.check_output(['git', 'rev-parse', 'HEAD'], text=True).strip(),
            'source_dirty': bool(subprocess.check_output(['git', 'status', '--porcelain'])),
            'tracked_source_diff_sha256': hashlib.sha256(source_diff).hexdigest(),
            'build_command': 'bash tools/build-windows-llm.sh',
            'build_type': 'cross-compiled experimental Windows port; prebuilt CPU PJRT DLL',
            'files': {str(p.relative_to(root)): sha256(p) for p in sorted(root.rglob('*')) if p.is_file()},
        }
        (root / 'build-info.json').write_text(json.dumps(info, indent=2) + '\n')
        args.output.parent.mkdir(parents=True, exist_ok=True)
        with zipfile.ZipFile(args.output, 'w', compression=zipfile.ZIP_DEFLATED, compresslevel=6) as archive:
            for path in sorted(root.rglob('*')):
                if path.is_file():
                    archive.write(path, path.relative_to(root))
    print(json.dumps({'archive': str(args.output), 'bytes': args.output.stat().st_size, 'sha256': sha256(args.output)}, indent=2))


if __name__ == '__main__':
    main()
