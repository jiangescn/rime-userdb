#!/usr/bin/env python3
"""macOS/Linux Rime synchronization. Standard library only; never copies live DBs into Git."""
import argparse
import datetime
import hashlib
import json
import os
import pathlib
import re
import shutil
import subprocess
import sys
import tempfile
import urllib.request
import uuid
import zipfile


class DictionaryRollbackError(RuntimeError):
    pass


OFFICIAL_DICTIONARIES = {
    'cn_dicts/41448.dict.yaml', 'cn_dicts/8105.dict.yaml',
    'cn_dicts/base.dict.yaml', 'cn_dicts/ext.dict.yaml',
    'cn_dicts/others.dict.yaml', 'cn_dicts/tencent.dict.yaml',
    'en_dicts/cn_en_abc.txt', 'en_dicts/cn_en_double_pinyin.txt',
    'en_dicts/cn_en_flypy.txt', 'en_dicts/cn_en_jiajia.txt',
    'en_dicts/cn_en_mspy.txt', 'en_dicts/cn_en_sogou.txt',
    'en_dicts/cn_en_ziguang.txt', 'en_dicts/cn_en.txt',
    'en_dicts/en_ext.dict.yaml', 'en_dicts/en.dict.yaml',
}


def validate_personal_table(path):
    parts = re.split(r'^\.\.\.\s*$', path.read_text(encoding='utf-8-sig'), maxsplit=1, flags=re.M)
    if len(parts) != 2 or not re.search(r'^name:\s*xhup\.user(?:\.top)?\s*$', parts[0], re.M):
        raise RuntimeError(f'Invalid Xiaohe personal table header: {path}')
    for line in parts[1].splitlines():
        if line.strip() and not line.lstrip().startswith('#') and not re.fullmatch(r"[^\t]+\t[a-z;']{1,4}(\t[0-9]+)?\s*", line):
            raise RuntimeError(f'Invalid Xiaohe personal entry: {path}')


def file_hash(path):
    data = path.read_bytes()
    if path.suffix.lower() not in ('.ico', '.ocd2'):
        data = data.decode('utf-8-sig').replace('\r\n', '\n').encode('utf-8')
    return hashlib.sha256(data).hexdigest().upper()


def write_json(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')


def checked_path(root, relative):
    if not re.fullmatch(r'[A-Za-z0-9_./-]+', relative) or relative.startswith('/') or '..' in pathlib.PurePosixPath(relative).parts:
        raise RuntimeError(f'Unsafe managed path: {relative}')
    path = root / relative
    if not path.resolve().is_relative_to(root.resolve()):
        raise RuntimeError(f'Path escapes its managed directory: {relative}')
    return path


class FileSync:
    def __init__(self, repo, user, platform):
        self.repo, self.user, self.platform = pathlib.Path(repo), pathlib.Path(user), platform
        self.manifest = json.loads((self.repo / 'rime-files.json').read_text(encoding='utf-8-sig'))
        if self.manifest['version'] != 1:
            raise RuntimeError('Unsupported file manifest')
        self.common = self.manifest['common_files']
        self.platform_files = self.manifest['platform_files'][platform]
        self.appearance = self.manifest['appearance_files'][platform]
        for name in self.common + self.platform_files:
            if not checked_path(self.repo, name).is_file():
                raise RuntimeError(f'Required repository file missing: {name}')
        self.user.mkdir(parents=True, exist_ok=True)
        installation = self.user / 'installation.yaml'
        if not installation.exists():
            installation.write_text(f'installation_id: "{uuid.uuid4()}"\n', encoding='utf-8')
        match = re.search(r'^\s*installation_id:\s*[\"\']?([A-Za-z0-9_.-]+)[\"\']?\s*$', installation.read_text(encoding='utf-8-sig'), re.M)
        if not match or match[1] in ('.', '..'):
            raise RuntimeError('Invalid or missing installation_id')
        self.device = match[1]
        self.prefix = f'devices/{self.device}/appearance/'
        state = self.user / '.rime-sync-state.json'
        self.state = json.loads(state.read_text(encoding='utf-8-sig')) if state.exists() else {'files': {}}
        self.commit_created = False
        sync_match = re.search(r'^\s*sync_dir:\s*(.+?)\s*$', installation.read_text(encoding='utf-8-sig'), re.M)
        self.sync_dir = pathlib.Path(sync_match[1].strip('\"\'' )).expanduser() if sync_match else self.user / 'sync'
        if not self.sync_dir.is_absolute():
            self.sync_dir = self.user / self.sync_dir

    def baseline(self, name):
        return self.state['files'].get(name, self.manifest['initial_hashes'].get(name))

    def paths(self):
        return self.common + [p for p in self.platform_files if p not in self.appearance] + [self.prefix + p for p in self.appearance] + [f'devices/{self.device}/device.json']

    def save_local(self):
        pending = []
        for name in self.common + [p for p in self.platform_files if p not in self.appearance]:
            live, repo = checked_path(self.user, name), checked_path(self.repo, name)
            if name in ('xhup_dicts/xhup.user.dict.yaml', 'xhup_dicts/xhup.user.top.dict.yaml'):
                validate_personal_table(repo)
                if live.exists():
                    validate_personal_table(live)
            if not live.exists():
                continue
            a, b = file_hash(live), file_hash(repo)
            if a == b:
                continue
            baseline = self.baseline(name)
            if baseline is None:
                raise RuntimeError(f'Existing local file differs without a sync baseline; preserve and merge both copies: {name}')
            if a != baseline:
                if b != baseline:
                    raise RuntimeError(f'File changed in both locations; preserve and merge both copies: {name}')
                pending.append((live, repo, name))
        for name in self.appearance:
            live, profile = checked_path(self.user, name), checked_path(self.repo, self.prefix + name)
            if live.exists():
                if profile.exists():
                    a, b = file_hash(live), file_hash(profile)
                    if a == b:
                        continue
                    baseline = self.baseline(name)
                    if baseline is None:
                        raise RuntimeError(f'Device appearance differs without a sync baseline: {name}')
                    if a == baseline:
                        continue
                    if b != baseline:
                        raise RuntimeError(f'Device appearance changed in both locations: {name}')
                source = live
            else:
                if profile.exists():
                    continue
                source = self.repo / name
            pending.append((source, profile, self.prefix + name))
        for source, destination, _ in pending:
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(source, destination)
        metadata = self.repo / f'devices/{self.device}/device.json'
        if not metadata.exists():
            write_json(metadata, {'platform': self.platform, 'appearance': 'appearance/'})
        return [p for _, _, p in pending]

    def install(self):
        for name in self.common + [p for p in self.platform_files if p not in self.appearance]:
            target = checked_path(self.user, name)
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(checked_path(self.repo, name), target)
        for name in self.appearance:
            shutil.copy2(checked_path(self.repo, self.prefix + name), checked_path(self.user, name))
        for device in (self.repo / 'sync').glob('*'):
            if not device.is_dir() or not re.fullmatch(r'[A-Za-z0-9_.-]+', device.name) or device.name in ('.', '..'):
                continue
            for database in self.manifest['frequency_databases']:
                snapshot = device / f'{database}.userdb.txt'
                if snapshot.is_file():
                    target = self.sync_dir / device.name / snapshot.name
                    target.parent.mkdir(parents=True, exist_ok=True)
                    shutil.copy2(snapshot, target)

    def finish(self):
        write_json(self.user / '.rime-sync-state.json', {'version': 1, 'files': {name: file_hash(self.user / name) for name in self.common + self.platform_files}})


def git(repo, *args, capture=False):
    result = subprocess.run(['git', '-C', str(repo), *args], check=True, text=True, encoding='utf-8', stdout=subprocess.PIPE if capture else None)
    return result.stdout.strip() if capture else ''


def pull(sync, local_only):
    dirty = git(sync.repo, 'diff', '--name-only', 'HEAD', '--', capture=True).splitlines()
    allowed = set(sync.paths())
    if set(dirty) - allowed:
        raise RuntimeError('Repository has unrelated tracked changes; commit or stash them first')
    new = git(sync.repo, 'ls-files', '--others', '--exclude-standard', '--', *sync.paths(), capture=True).splitlines()
    changed = dirty + new
    if changed:
        if local_only:
            print('Local settings saved; pull skipped in LocalOnly mode.')
            return
        git(sync.repo, 'add', '--', *changed)
        git(sync.repo, 'commit', '-m', 'sync personal Rime settings', '--', *changed)
        sync.commit_created = True
    git(sync.repo, 'pull', '--no-rebase', '--no-edit', 'origin', 'main')


def update_dictionaries(repo, backup_root):
    manifest_path = repo / 'rime-ice-update.json'
    old = json.loads(manifest_path.read_text(encoding='utf-8-sig'))
    if old['source'] != 'https://github.com/iDvel/rime-ice' or old['hashFormat'] != 'sha256-utf8-lf' or set(old['files']) != OFFICIAL_DICTIONARIES:
        raise RuntimeError('Invalid official dictionary manifest')
    for name, expected in old['files'].items():
        if not name.startswith(('cn_dicts/', 'en_dicts/')) or file_hash(checked_path(repo, name)) != expected:
            raise RuntimeError(f'Hand-edited dictionary preserved; official update skipped: {name}')
    request = urllib.request.Request('https://api.github.com/repos/iDvel/rime-ice/commits/HEAD', headers={'User-Agent': 'RimeDictionarySync'})
    with urllib.request.urlopen(request, timeout=30) as response:
        head = json.load(response)
    revision = head['sha']
    if not re.fullmatch('[0-9a-f]{40}', revision):
        raise RuntimeError('Invalid upstream revision')
    if revision == old['commit']:
        return [], None
    with tempfile.TemporaryDirectory(prefix='rime-dicts-') as temporary:
        temporary = pathlib.Path(temporary)
        request = urllib.request.Request(f'https://codeload.github.com/iDvel/rime-ice/zip/{revision}', headers={'User-Agent': 'RimeDictionarySync'})
        with urllib.request.urlopen(request, timeout=90) as response, (temporary / 'upstream.zip').open('wb') as output:
            shutil.copyfileobj(response, output)
        hashes, changed = {}, []
        with zipfile.ZipFile(temporary / 'upstream.zip') as archive:
            for name, old_hash in old['files'].items():
                info = archive.getinfo(f'rime-ice-{revision}/{name}')
                if not 100 <= info.file_size <= 100 * 1024 * 1024:
                    raise RuntimeError(f'Unexpected dictionary size: {name}')
                content = archive.read(info).decode('utf-8-sig')
                if name.endswith('.dict.yaml'):
                    expected_name = pathlib.PurePosixPath(name).name.removesuffix('.dict.yaml')
                    header = content.split('\n...\n', 1)[0]
                    if not re.search(r'^name:\s*[\"\']?' + re.escape(expected_name) + r'[\"\']?\s*$', header, re.M) or '\n...\n' not in content:
                        raise RuntimeError(f'Invalid dictionary header: {name}')
                elif '\t' not in content:
                    raise RuntimeError(f'Invalid tab-separated dictionary: {name}')
                target = temporary / name
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_text(content.replace('\r\n', '\n'), encoding='utf-8')
                hashes[name] = file_hash(target)
                if hashes[name] != old_hash:
                    changed.append(name)
        write_json(temporary / manifest_path.name, {**old, 'commit': revision, 'files': hashes})
        (temporary / 'RIME_ICE_VERSION.md').write_text(f'# Rime Ice dictionary version\n\n- Source: {old["source"]}\n- Upstream commit: `{revision}`\n- Scope: the 16 allowlisted dictionaries. Schemas, Lua and personal data are preserved.\n', encoding='utf-8')
        changed += ['rime-ice-update.json', 'RIME_ICE_VERSION.md']
        backup = backup_root / ('official-' + uuid.uuid4().hex)
        for name in changed:
            destination = backup / name
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(repo / name, destination)
            if file_hash(repo / name) != file_hash(destination):
                raise RuntimeError('Official dictionary backup failed')
        try:
            for name in changed:
                shutil.copy2(temporary / name, repo / name)
        except BaseException:
            try:
                for name in changed:
                    shutil.copy2(backup / name, repo / name)
            except BaseException as error:
                raise DictionaryRollbackError(f'Dictionary rollback failed; stop and restore backup: {backup}') from error
            raise
    return changed, backup


class NativeTools:
    def __init__(self, user, repo, platform, shared_support=None):
        self.user, self.repo, self.platform = user, repo, platform
        self.squirrel = pathlib.Path('/Library/Input Methods/Squirrel.app/Contents/MacOS/Squirrel')
        support = pathlib.Path(shared_support) if shared_support else pathlib.Path('/Library/Input Methods/Squirrel.app/Contents/SharedSupport')
        self.manager = str(support / 'rime_dict_manager') if platform == 'macos' else shutil.which('rime_dict_manager')
        self.deployer = str(support / 'rime_deployer') if platform == 'macos' else shutil.which('rime_deployer')
        for path in (self.manager, self.deployer):
            if not path or not pathlib.Path(path).is_file():
                raise RuntimeError('Install Rime with Lua support and native rime_dict_manager/rime_deployer tools first.')

    def pause(self):
        if self.platform == 'macos':
            subprocess.run([str(self.squirrel), '--quit'], check=True)
            import time
            for _ in range(100):
                if subprocess.run(['pgrep', '-x', 'Squirrel'], stdout=subprocess.DEVNULL).returncode:
                    return
                time.sleep(0.1)
            raise RuntimeError('Squirrel did not exit; synchronization stopped.')

    def resume(self):
        if self.platform == 'macos':
            subprocess.run(['open', '-g', '-a', '/Library/Input Methods/Squirrel.app'], check=True)

    def sync(self):
        subprocess.run([self.manager, '--sync'], cwd=self.user, check=True)

    def restore(self, path):
        subprocess.run([self.manager, '--restore', str(path)], cwd=self.user, check=True)

    def deploy(self):
        subprocess.run([self.deployer, '--build', str(self.user), str(self.repo), str(self.user / 'build')], cwd=self.user, check=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--rime-dir', type=pathlib.Path)
    parser.add_argument('--frontend', choices=('fcitx5', 'ibus'), default='fcitx5')
    parser.add_argument('--shared-support', help='macOS Squirrel SharedSupport path')
    parser.add_argument('--skip-pull', action='store_true')
    parser.add_argument('--skip-dictionary-update', action='store_true')
    parser.add_argument('--local-only', action='store_true')
    parser.add_argument('--dry-run', action='store_true')
    args = parser.parse_args()
    if sys.platform == 'win32':
        parser.error('On Windows use the existing sync-rime.ps1 entry.')
    platform = 'macos' if sys.platform == 'darwin' else 'linux'
    repo = pathlib.Path(__file__).resolve().parent
    default_user = pathlib.Path.home() / ('Library/Rime' if platform == 'macos' else ('.local/share/fcitx5/rime' if args.frontend == 'fcitx5' else '.config/ibus/rime'))
    user = (args.rime_dir or default_user).expanduser().resolve()
    if repo == user or repo.is_relative_to(user) or user.is_relative_to(repo):
        parser.error('Keep the Git checkout and Rime user directory separate.')
    manifest = json.loads((repo / 'rime-files.json').read_text(encoding='utf-8-sig'))
    if args.dry_run:
        print(json.dumps({'platform': platform, 'userDirectory': str(user), 'managedFiles': len(manifest['common_files']) + len(manifest['platform_files'][platform]), 'appearance': 'device-local; repository defaults on first use', 'writes': False}, ensure_ascii=False))
        return
    native = NativeTools(user, repo, platform, args.shared_support)
    user.mkdir(parents=True, exist_ok=True)
    import fcntl
    lock = (user / '.rime-sync.lock').open('a')
    fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    backup_root = pathlib.Path.home() / ('Library/Application Support/RimeBackups' if platform == 'macos' else '.local/share/RimeBackups')
    backup = backup_root / ('sync-' + datetime.datetime.now().strftime('%Y%m%d-%H%M%S') + '-' + uuid.uuid4().hex[:8])
    if backup.resolve().is_relative_to(user):
        raise RuntimeError('The backup directory must be outside the Rime user directory.')
    native.pause()
    try:
        shutil.copytree(user, backup, symlinks=True)
        sync = FileSync(repo, user, platform)
        sync.save_local()
        if not args.skip_pull:
            pull(sync, args.local_only)
        native.sync()
        changed, official_backup = [], None
        if not args.local_only and not args.skip_dictionary_update:
            if git(repo, 'status', '--porcelain', '--untracked-files=no', capture=True):
                print('Official dictionary update skipped because the checkout has tracked local changes.')
            else:
                try:
                    changed, official_backup = update_dictionaries(repo, backup_root)
                except DictionaryRollbackError:
                    raise
                except Exception as error:
                    print(f'Official update skipped; keeping existing dictionaries: {error}', file=sys.stderr)
        try:
            sync.install()
            native.deploy()
            # Restore portable snapshots explicitly on a fresh device before export.
            for snapshot in sorted(sync.sync_dir.glob('*/rime_ice.userdb.txt')):
                native.restore(snapshot)
            native.sync()
            native.deploy()
        except BaseException:
            if official_backup:
                for name in changed:
                    shutil.copy2(official_backup / name, repo / name)
            # Restore prior managed files; keep all current databases and snapshots.
            for name in sync.common + sync.platform_files:
                if (backup / name).exists():
                    (user / name).parent.mkdir(parents=True, exist_ok=True)
                    shutil.copy2(backup / name, user / name)
            raise
        sync.finish()
        if not args.local_only:
            relative = f'sync/{sync.device}/rime_ice.userdb.txt'
            snapshot = sync.sync_dir / sync.device / 'rime_ice.userdb.txt'
            if not snapshot.exists():
                raise RuntimeError('No rime_ice snapshot was exported. Use the double-pinyin schema once, then synchronize again.')
            (repo / relative).parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(snapshot, repo / relative)
            paths = sync.paths() + changed + [relative]
            git(repo, 'add', '--', *paths)
            diff = subprocess.run(['git', '-C', str(repo), 'diff', '--cached', '--quiet', '--exit-code', '--', *paths]).returncode
            if diff == 1:
                git(repo, 'commit', '-m', 'sync Rime personal data and device appearance', '--', *paths)
            elif diff != 0:
                raise RuntimeError('Unable to inspect staged synchronization changes')
            if diff == 1 or sync.commit_created:
                git(repo, 'push', 'origin', 'main')
        print(f'Rime synchronization completed. Backup: {backup}')
    finally:
        native.resume()
        lock.close()


if __name__ == '__main__':
    try:
        main()
    except (RuntimeError, OSError, subprocess.CalledProcessError) as error:
        print(f'Rime synchronization stopped: {error}', file=sys.stderr)
        sys.exit(1)
