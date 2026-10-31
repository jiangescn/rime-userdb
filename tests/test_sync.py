import importlib.util
import json
import pathlib
import re
import tempfile
import unittest
import io
import shutil
import zipfile
from unittest import mock

ROOT = pathlib.Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('rime_sync', ROOT / 'rime_sync.py')
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class FileSyncTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='rime-test-', dir=ROOT.parent)
        assert pathlib.Path(self.temp.name).resolve().is_relative_to(ROOT.parent.resolve())
        self.addCleanup(self.temp.cleanup)
        self.root = pathlib.Path(self.temp.name)
        self.repo = self.root / 'repo'
        self.repo.mkdir()
        (self.repo / 'settings.yaml').write_text('option: original\n', encoding='utf-8')
        (self.repo / 'weasel.custom.yaml').write_text('font: default-windows\n', encoding='utf-8')
        (self.repo / 'squirrel.custom.yaml').write_text('font: default-macos\n', encoding='utf-8')
        module.write_json(self.repo / 'rime-files.json', {
            'version': 1, 'common_files': ['settings.yaml'],
            'platform_files': {'windows': ['weasel.custom.yaml'], 'macos': ['squirrel.custom.yaml'], 'linux': []},
            'appearance_files': {'windows': ['weasel.custom.yaml'], 'macos': ['squirrel.custom.yaml'], 'linux': []},
            'initial_hashes': {}, 'frequency_databases': ['rime_ice'],
        })

    def device(self, name, platform):
        sync = module.FileSync(self.repo, self.root / name, platform)
        sync.save_local()
        sync.install()
        sync.finish()
        return sync

    def test_fresh_default_and_unique_identity(self):
        a, b = self.device('a', 'windows'), self.device('b', 'macos')
        self.assertNotEqual(a.device, b.device)
        self.assertEqual((a.user / 'weasel.custom.yaml').read_text(), 'font: default-windows\n')
        self.assertEqual((b.user / 'squirrel.custom.yaml').read_text(), 'font: default-macos\n')
        self.assertEqual(module.FileSync(self.repo, a.user, 'windows').device, a.device)

    def test_appearance_changes_do_not_cross_devices_or_change_defaults(self):
        a, b = self.device('a', 'windows'), self.device('b', 'windows')
        (a.user / 'weasel.custom.yaml').write_text('font: my-device\n')
        a = module.FileSync(self.repo, a.user, 'windows')
        a.save_local()
        a.install()
        a.finish()
        b = module.FileSync(self.repo, b.user, 'windows')
        b.save_local()
        b.install()
        self.assertEqual((b.user / 'weasel.custom.yaml').read_text(), 'font: default-windows\n')
        self.assertEqual((self.repo / 'weasel.custom.yaml').read_text(), 'font: default-windows\n')
        self.assertEqual((self.repo / a.prefix / 'weasel.custom.yaml').read_text(), 'font: my-device\n')

    def test_common_local_edit_round_trip(self):
        a, b = self.device('a', 'windows'), self.device('b', 'macos')
        (a.user / 'settings.yaml').write_text('option: personal\n')
        module.FileSync(self.repo, a.user, 'windows').save_local()
        b = module.FileSync(self.repo, b.user, 'macos')
        b.save_local()
        b.install()
        self.assertEqual((b.user / 'settings.yaml').read_text(), 'option: personal\n')

    def test_conflict_preserves_both_files_and_appearance(self):
        a = self.device('a', 'windows')
        (a.user / 'settings.yaml').write_text('option: local\n')
        (self.repo / 'settings.yaml').write_text('option: remote\n')
        (a.user / 'weasel.custom.yaml').write_text('font: changed\n')
        with self.assertRaisesRegex(RuntimeError, 'both locations'):
            module.FileSync(self.repo, a.user, 'windows').save_local()
        self.assertEqual((self.repo / 'settings.yaml').read_text(), 'option: remote\n')
        self.assertEqual((a.user / 'settings.yaml').read_text(), 'option: local\n')
        self.assertEqual((self.repo / a.prefix / 'weasel.custom.yaml').read_text(), 'font: default-windows\n')

    def test_unknown_existing_config_is_not_overwritten(self):
        user = self.root / 'existing'
        user.mkdir()
        (user / 'settings.yaml').write_text('option: unknown-existing\n')
        with self.assertRaisesRegex(RuntimeError, 'without a sync baseline'):
            module.FileSync(self.repo, user, 'windows').save_local()
        self.assertEqual((user / 'settings.yaml').read_text(), 'option: unknown-existing\n')

    def test_crlf_and_bom_are_equivalent(self):
        a = self.root / 'a.yaml'
        b = self.root / 'b.yaml'
        a.write_bytes(b'\xef\xbb\xbfkey: value\r\n')
        b.write_bytes(b'key: value\n')
        self.assertEqual(module.file_hash(a), module.file_hash(b))

    def test_unsafe_paths_rejected(self):
        for path in ('../file', '/absolute', 'x/../../file', 'C:/file'):
            with self.assertRaises(RuntimeError):
                module.checked_path(self.repo, path)


class RuntimeCompletenessTests(unittest.TestCase):
    def test_current_dependency_closure_is_present(self):
        manifest = json.loads((ROOT / 'rime-files.json').read_text(encoding='utf-8'))
        paths = set(manifest['common_files'])
        for name in paths:
            self.assertTrue((ROOT / name).is_file(), name)
        for name in (p for p in paths if p.endswith('.schema.yaml')):
            source = (ROOT / name).read_text(encoding='utf-8-sig')
            for dictionary in re.findall(r'^\s*dictionary:\s*[\"\']?([A-Za-z0-9_./-]+)', source, re.M):
                self.assertIn(dictionary + '.dict.yaml', paths, f'{name}: dictionary {dictionary}')
            for mod in re.findall(r'lua_(?:filter|processor|translator)@\*([A-Za-z0-9_/]+)', source):
                self.assertIn('lua/' + mod + '.lua', paths, f'{name}: Lua {mod}')
            for config in re.findall(r'^\s*opencc_config:\s*([A-Za-z0-9_.-]+)', source, re.M):
                self.assertIn('opencc/' + config, paths, f'{name}: OpenCC {config}')
        for name in (p for p in paths if p.startswith('opencc/') and p.endswith('.json')):
            source = json.loads((ROOT / name).read_text(encoding='utf-8-sig'))
            def inspect(node):
                if isinstance(node, dict):
                    if 'file' in node:
                        self.assertIn('opencc/' + node['file'], paths, name)
                    for item in node.values():
                        inspect(item)
                elif isinstance(node, list):
                    for item in node:
                        inspect(item)
            inspect(source)


class DictionaryUpdateTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='rime-update-test-', dir=ROOT.parent)
        assert pathlib.Path(self.temp.name).resolve().is_relative_to(ROOT.parent.resolve())
        self.addCleanup(self.temp.cleanup)
        self.root = pathlib.Path(self.temp.name)
        self.repo = self.root / 'repo'
        self.repo.mkdir()
        self.hashes = {}
        for name in module.OFFICIAL_DICTIONARIES:
            path = self.repo / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(self.content(name, 'old'), encoding='utf-8')
            self.hashes[name] = module.file_hash(path)
        module.write_json(self.repo / 'rime-ice-update.json', {'source':'https://github.com/iDvel/rime-ice','commit':'a'*40,'hashFormat':'sha256-utf8-lf','files':self.hashes})
        (self.repo / 'RIME_ICE_VERSION.md').write_text('old version\n')
        self.backup = self.root / 'backups'

    @staticmethod
    def content(name, label):
        if name.endswith('.dict.yaml'):
            stem = pathlib.PurePosixPath(name).name.removesuffix('.dict.yaml')
            return '# source dictionary\n' * 5 + f'---\nname: {stem}\nversion: {label}\n...\nWORD\tci\t1\n'
        return '# source table\n' * 10 + f'WORD_{label}\tcode\n'

    def network(self, revision='b'*40):
        archive = io.BytesIO()
        with zipfile.ZipFile(archive, 'w') as output:
            for name in module.OFFICIAL_DICTIONARIES:
                output.writestr(f'rime-ice-{revision}/{name}', self.content(name, 'new'))
        def response(request, timeout):
            if '/commits/HEAD' in request.full_url:
                return io.BytesIO(json.dumps({'sha':revision}).encode())
            return io.BytesIO(archive.getvalue())
        return response

    def test_first_update_and_pinned_metadata(self):
        with mock.patch.object(module.urllib.request, 'urlopen', side_effect=self.network()):
            changed, backup = module.update_dictionaries(self.repo, self.backup)
        self.assertEqual(len(changed), 18)
        self.assertTrue(backup.is_dir())
        self.assertEqual(json.loads((self.repo/'rime-ice-update.json').read_text())['commit'], 'b'*40)
        for name, old_hash in self.hashes.items():
            self.assertEqual(module.file_hash(backup/name), old_hash)

    def test_network_failure_keeps_all_files(self):
        with mock.patch.object(module.urllib.request, 'urlopen', side_effect=OSError('offline')):
            with self.assertRaises(OSError):
                module.update_dictionaries(self.repo, self.backup)
        self.assertEqual({name:module.file_hash(self.repo/name) for name in self.hashes}, self.hashes)

    def test_hand_edit_skips_network(self):
        path = self.repo / 'cn_dicts/base.dict.yaml'
        path.write_text(path.read_text()+'MY_WORD\tci\t9\n')
        with mock.patch.object(module.urllib.request, 'urlopen') as network:
            with self.assertRaisesRegex(RuntimeError, 'Hand-edited'):
                module.update_dictionaries(self.repo, self.backup)
            network.assert_not_called()
        self.assertIn('MY_WORD', path.read_text())

    def test_partial_replacement_restores_old_files(self):
        original = shutil.copy2
        count = 0
        def copy(source, destination):
            nonlocal count
            source, destination = pathlib.Path(source), pathlib.Path(destination)
            if destination.is_relative_to(self.repo) and 'official-' not in str(source):
                count += 1
                if count == 3:
                    raise OSError('simulated replacement failure')
            return original(source,destination)
        with mock.patch.object(module.urllib.request, 'urlopen', side_effect=self.network()), mock.patch.object(module.shutil, 'copy2', side_effect=copy):
            with self.assertRaises(OSError):
                module.update_dictionaries(self.repo,self.backup)
        self.assertEqual({name:module.file_hash(self.repo/name) for name in self.hashes}, self.hashes)


if __name__ == '__main__':
    unittest.main()
