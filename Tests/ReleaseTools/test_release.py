"""Offline release acceptance tests adapted from VocalisBook/BitSkim (MIT)."""
import contextlib
import copy
import hashlib
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tarfile
import tempfile
import unittest
from unittest.mock import patch
sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'scripts'))
import build_provenance as provenance
import release
import source_release

class FakeAPI:
    def __init__(self, service, manifest):
        self.service, self.manifest = service, manifest
        self.host = 'api.github.com' if service == 'github' else 'gitlab.test'
        self.calls, self.assets, self.packages = [], {}, {}
        self.release = None
        self.fail_upload = False
        self.wrong_digest = False
        self.base, self.path = release.release_paths(service, manifest)

    def request(self, method, path, body=None, file=None, optional=False, hash_body=False, host=None):
        self.calls.append((method, path, copy.deepcopy(body)))
        if method == 'GET' and path == self.base:
            return {'full_name': 'org/vocalisbook', 'permissions': {'push': True}} if self.service == 'github' else {
                'path_with_namespace': 'group/subgroup/vocalisbook', 'permissions': {'project_access': {'access_level': 40}}}
        if method == 'GET' and path == self.path:
            return copy.deepcopy(self.release)
        if '/packages/generic/' in path:
            if method == 'GET':
                return self.packages.get(path)
            if self.fail_upload:
                raise RuntimeError('simulated upload interruption')
            self.packages[path] = release.digest(file)
            return {'message': '201 Created'}
        if method == 'POST' and path == self.base + '/releases':
            self.release = {'id': 7, 'tag_name': body['tag_name'], 'body': body.get('body'),
                            'description': body.get('description'), 'draft': body.get('draft', False),
                            'upload_url': 'https://uploads.github.com' + self.base + '/releases/7/assets{?name,label}',
                            'assets': body.get('assets', {'links': []})}
            return copy.deepcopy(self.release)
        if method == 'GET' and '/assets?per_page=' in path:
            return list(self.assets.values())
        if method == 'POST' and '/assets?name=' in path:
            if self.fail_upload:
                raise RuntimeError('simulated upload interruption')
            name = file.name
            value = {'name': name, 'digest': 'sha256:' + ('0' * 64 if self.wrong_digest else release.digest(file))}
            self.assets[name] = value
            return value
        if method == 'PATCH':
            self.release.update(body)
            return copy.deepcopy(self.release)
        if method == 'POST' and path.endswith('/assets/links'):
            self.release['assets']['links'].append(copy.deepcopy(body))
            return body
        raise AssertionError((method, path))


class ReleaseTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        for folder in ('Apps', 'Core', 'Platform', 'Config', 'Docs', 'Tests', 'public-web/screenshots', 'scripts'):
            (self.root / folder).mkdir(parents=True)
        files = {'VERSION': '1.0.0\n', 'Makefile': 'all:\n', 'LICENSE': 'GPL fixture',
                 'Core/main.swift': '// fixture', 'Docs/RELEASE-NOTES.md': 'Release notes',
                 '.gitignore': 'build/\noutputs/\nwork/\n__pycache__/\n**/.build/\n*.xcodeproj/\n',
                 'public-web/index.php': '<?php echo "fixture";', 'public-web/style.css': 'body{}',
                 'public-web/screenshots/test.jpg': 'image fixture'}
        for platform in ('iOS', 'macOS', 'tvOS'):
            files['Config/' + platform + '.xcconfig'] = 'MARKETING_VERSION = 1.0.0\n'
        for name, data in files.items():
            (self.root / name).write_text(data)
        self.config = {'github': 'https://github.com/org/vocalisbook', 'github_git': 'git@github.com:org/vocalisbook.git',
                       'gitlab': 'https://gitlab.test/group/subgroup/vocalisbook',
                       'gitlab_git': 'git@gitlab.test:group/subgroup/vocalisbook.git', 'env': {}}
        for args in (['git', 'init', '-q', '--initial-branch=main'], ['git', 'config', 'user.name', 'Release Test'],
                     ['git', 'config', 'user.email', 'test@example.invalid'], ['git', 'add', '.'],
                     ['git', 'commit', '-qm', 'Fixture']):
            subprocess.run(args, cwd=self.root, check=True, capture_output=True)
        self.addCleanup(patch.stopall)
        patch('http.client.HTTPSConnection', side_effect=AssertionError('Real networking is forbidden in tests')).start()
        patch.dict(os.environ, {'GITHUB_TOKEN': 'mock-github-credential', 'GITLAB_TOKEN': 'mock-gitlab-credential'}).start()
        self.make_artifacts()

    def make_artifacts(self):
        folder = release.output(self.root)
        folder.mkdir(parents=True, exist_ok=True)
        n = release.names(self.root)
        release.create_website(folder / n['website'], self.root)
        record = {'version': '1.0.0', 'platform_versions': release.platform_versions(self.root),
                  'commit': provenance.commit(self.root), 'source_sha256': provenance.source_hash(self.root),
                  'distribution': 'source-and-website',
                  'artifacts': {n['website']: release.digest(folder / n['website'])}}
        provenance.write_json(folder / n['record'], record)
        source_release.create(folder / n['source'], self.root, (folder / n['record']).read_bytes())
        self.write_sums()


    def write_sums(self):
        folder = release.output(self.root)
        (folder / 'SHA256SUMS').write_text(''.join(release.digest(folder / name) + '  ' + name + '\n'
                                                for name in sorted(release.names(self.root).values())))

    def manifest(self):
        with contextlib.redirect_stdout(io.StringIO()):
            return release.prepare(self.config, self.root / 'Docs/RELEASE-NOTES.md', self.root)

    def service_setup(self):
        manifest = self.manifest()
        apis = {s: FakeAPI(s, manifest) for s in release.SERVICES}
        remotes = {}
        def api(host, token, github=False): return apis['github' if github else 'gitlab']
        def remote(url, tag, root): return remotes.get(url)
        def run(args, root, capture=False, env=None):
            if args[:2] == ['git', 'push']:
                remotes[args[3] if args[2] == '--no-follow-tags' else args[2]] = manifest['commit']
                return None
            return provenance.run(args, root, capture, env)
        patch('release.API', side_effect=api).start()
        patch('release.remote_tag', side_effect=remote).start()
        patch('release.run', side_effect=run).start()
        return manifest, apis, remotes

    def test_valid_inventory_and_matching_source(self):
        self.assertEqual(set(release.check(self.root)), set(release.names(self.root).values()) | {'SHA256SUMS'})

    def test_modified_source_blocks_check(self):
        (self.root / 'Core/main.swift').write_text('changed')
        with self.assertRaisesRegex(ValueError, 'Source changed'): release.check(self.root)

    def test_missing_and_unexpected_inventory(self):
        file = release.output(self.root) / 'unexpected'
        file.write_bytes(b'extra')
        with self.assertRaisesRegex(ValueError, 'inventory'): release.inventory(self.root)
        file.unlink()
        (release.output(self.root) / release.names(self.root)['website']).unlink()
        with self.assertRaisesRegex(ValueError, 'inventory'): release.inventory(self.root)

    def test_duplicate_checksum_rejected(self):
        sums = release.output(self.root) / 'SHA256SUMS'
        sums.write_text(sums.read_text() + sums.read_text().splitlines()[0] + '\n')
        with self.assertRaisesRegex(ValueError, 'duplicate'): release.inventory(self.root)

    def test_symlinked_asset_rejected(self):
        file = release.output(self.root) / release.names(self.root)['source']
        file.unlink(); file.symlink_to(self.root / 'LICENSE')
        with self.assertRaisesRegex(ValueError, 'symlinked'): release.inventory(self.root)

    def test_archive_contents_cannot_be_forged_by_rehashing(self):
        with tarfile.open(release.output(self.root) / release.names(self.root)['source'], 'w:gz'):
            pass
        self.write_sums()
        with self.assertRaisesRegex(ValueError, 'Source archive differs'): release.check(self.root)

    def test_extracted_source_can_prepare_but_not_publish(self):
        shutil = __import__('shutil')
        shutil.rmtree(self.root / '.git')
        self.make_artifacts()
        self.assertIsNone(self.manifest()['commit'])
        with self.assertRaisesRegex(ValueError, 'Git checkout'): release.publish(['github'], True, self.root)

    def test_dirty_and_ignored_source_block_publication(self):
        self.manifest()
        (self.root / 'Core/main.swift').write_text('changed')
        with self.assertRaisesRegex(ValueError, 'Commit all'): release.publish(['github'], True, self.root)
        subprocess.run(['git', 'checkout', '--', 'Core/main.swift'], cwd=self.root, check=True)
        with (self.root / '.git/info/exclude').open('a') as stream: stream.write('\nCore/ignored.swift\n')
        (self.root / 'Core/ignored.swift').write_text('hidden')
        with self.assertRaisesRegex(ValueError, 'ignored release input'): provenance.commit(self.root, clean=True)

    def test_untracked_source_blocks_publication(self):
        self.manifest(); (self.root / 'Core/new.swift').write_text('new')
        with self.assertRaisesRegex(ValueError, 'Commit all'): release.publish(['github'], True, self.root)

    def test_explicit_confirmation_required(self):
        with patch('release.API') as api:
            with self.assertRaisesRegex(ValueError, 'confirm-publish'): release.publish(['github'], False, self.root)
        api.assert_not_called()

    def test_repository_validation(self):
        for url in ['http://github.com/a/b', 'https://user:secret@github.com/a/b',
                    'https://github.com/a/../b', 'https://github.com/a/b?q=x',
                    'https://elsewhere.test/a/b', 'https://github.com/a/b/c']:
            with self.assertRaises(ValueError): release.repository(url, True)
        self.assertEqual(release.repository(self.config['gitlab']), ('gitlab.test', 'group/subgroup/vocalisbook'))
        bad = dict(self.config, github_git='git@github.com:wrong/project.git')
        with self.assertRaisesRegex(ValueError, 'must match'): release.git_destination(bad, 'github')

    def test_configuration_rejects_tokens(self):
        file = self.root / 'config.json'
        file.write_text(json.dumps({'env': {'GITHUB_TOKEN': 'bad'}}))
        with self.assertRaisesRegex(ValueError, 'Only PHP'): release.configuration(file)
        with self.assertRaisesRegex(ValueError, 'credential'): release.secret_check('mock-github-credential')

    def test_source_archive_excludes_local_config_and_caches(self):
        (self.root / 'work').mkdir()
        (self.root / 'work/release-config.json').write_text('local settings')
        path = self.root / 'test.tar.gz'
        source_release.create(path, self.root)
        with tarfile.open(path) as archive:
            self.assertFalse(any('/work/' in n or '/outputs/' in n or '/build/' in n for n in archive.getnames()))

    def test_missing_token_preflights_before_mutation(self):
        _, apis, remotes = self.service_setup()
        with patch.dict(os.environ, {'GITLAB_TOKEN': ''}):
            with self.assertRaisesRegex(ValueError, 'GITLAB_TOKEN'): release.publish(['github', 'gitlab'], True, self.root)
        self.assertFalse(remotes)
        self.assertFalse(any(c[0] != 'GET' for api in apis.values() for c in api.calls))

    def test_conflicting_remote_tag_stops_all_uploads(self):
        manifest, apis, remotes = self.service_setup()
        remotes[manifest['gitlab_git']] = 'f' * 40
        with self.assertRaisesRegex(ValueError, 'conflicting remote tag'): release.publish(['github', 'gitlab'], True, self.root)
        self.assertFalse(any(c[0] != 'GET' for api in apis.values() for c in api.calls))

    def test_annotated_remote_tags_resolve_to_commit(self):
        with patch('release.run', return_value='tagobject\trefs/tags/v1.0.0\ncommitobject\trefs/tags/v1.0.0^{}'):
            self.assertEqual(release.remote_tag('https://example.invalid/a/b', 'v1.0.0', self.root), 'commitobject')

    def test_github_draft_published_only_after_full_hashes(self):
        _, apis, _ = self.service_setup()
        with contextlib.redirect_stdout(io.StringIO()): release.publish(['github'], True, self.root)
        api = apis['github']
        self.assertFalse(api.release['draft'])
        last_upload = max(i for i,c in enumerate(api.calls) if c[0] == 'POST' and '/assets?name=' in c[1])
        patch_index = next(i for i,c in enumerate(api.calls) if c[0] == 'PATCH')
        self.assertGreater(patch_index, last_upload)
        receipt = provenance.read_json(self.root / 'outputs/release/receipt.json')
        self.assertIn('github', receipt['completed'])
        self.assertEqual(provenance.run(['git', 'cat-file', '-t', 'refs/tags/v1.0.0'], self.root, True), 'tag')

    def test_github_wrong_upload_digest_keeps_draft(self):
        _, apis, _ = self.service_setup(); apis['github'].wrong_digest = True
        with self.assertRaisesRegex(ValueError, 'upload digest differs'): release.publish(['github'], True, self.root)
        self.assertTrue(apis['github'].release['draft'])
        self.assertFalse(any(c[0] == 'PATCH' for c in apis['github'].calls))

    def test_existing_unknown_github_digest_stops(self):
        manifest, apis, _ = self.service_setup(); api = apis['github']
        api.release = {'id':7, 'tag_name':'v1.0.0','body':manifest['notes'],'draft':True}
        name = next(iter(manifest['files'])); api.assets[name] = {'name':name, 'digest':None}
        with self.assertRaisesRegex(ValueError, 'unknown digest'): release.publish(['github'], True, self.root)
        self.assertFalse(any(c[0] != 'GET' for c in api.calls))

    def test_matching_assets_resume_after_interruption(self):
        manifest, apis, _ = self.service_setup(); api = apis['github']
        api.fail_upload = True
        with self.assertRaises(RuntimeError): release.publish(['github'], True, self.root)
        api.fail_upload = False
        name, sha = next(iter(manifest['files'].items()))
        api.assets[name] = {'name':name,'digest':'sha256:'+sha}
        with contextlib.redirect_stdout(io.StringIO()): release.publish(['github'], True, self.root)
        posted = [c[1] for c in api.calls if c[0] == 'POST' and '/assets?name=' in c[1]]
        self.assertFalse(any(p.endswith('?name='+name) for p in posted[1:]))
        self.assertFalse(api.release['draft'])

    def test_gitlab_download_verification_precedes_release(self):
        manifest, apis, _ = self.service_setup()
        with contextlib.redirect_stdout(io.StringIO()): release.publish(['gitlab'], True, self.root)
        api = apis['gitlab']
        self.assertEqual(len(api.packages), len(manifest['files']))
        created = next(i for i,c in enumerate(api.calls) if c[0]=='POST' and c[1]==api.base+'/releases')
        self.assertTrue(all(i<created for i,c in enumerate(api.calls) if c[0]=='PUT'))
        self.assertEqual(len(api.release['assets']['links']),len(manifest['files']))

    def test_conflicting_gitlab_package_is_not_overwritten(self):
        manifest, apis, _ = self.service_setup(); api = apis['gitlab']
        name = next(iter(manifest['files'])); api.packages[release.package_path(api.base,manifest,name)]='0'*64
        with self.assertRaisesRegex(ValueError, 'package bytes differ'): release.publish(['gitlab'], True, self.root)
        self.assertFalse(any(c[0]=='PUT' for c in api.calls))

    def test_completed_destination_survives_later_failure(self):
        _, apis, _ = self.service_setup(); apis['gitlab'].fail_upload = True
        with self.assertRaises(RuntimeError), contextlib.redirect_stdout(io.StringIO()):
            release.publish(['github','gitlab'], True, self.root)
        receipt = provenance.read_json(self.root/'outputs/release/receipt.json')
        self.assertIn('github',receipt['completed']); self.assertNotIn('gitlab',receipt['completed'])
        self.assertFalse(apis['github'].release['draft'])
        apis['gitlab'].fail_upload = False
        before = len([c for c in apis['github'].calls if c[0]!='GET'])
        with contextlib.redirect_stdout(io.StringIO()): release.publish(['github','gitlab'], True, self.root)
        self.assertEqual(before,len([c for c in apis['github'].calls if c[0]!='GET']))

    def test_receipt_cannot_follow_another_manifest(self):
        manifest, _, _ = self.service_setup()
        path = self.root/'outputs/release/receipt.json'
        provenance.write_json(path, {'manifest_sha256':'0'*64,'completed':{}})
        with self.assertRaisesRegex(ValueError,'different manifest'): release.publish(['github'],True,self.root)
        with self.assertRaisesRegex(ValueError,'Source changed'):
            (self.root/'Docs/RELEASE-NOTES.md').write_text('changed')
            release.prepare(self.config,self.root/'Docs/RELEASE-NOTES.md',self.root)

    def test_destination_names_are_distinct_and_supported(self):
        for value in ['', 'github,github', 'other', 'github,gitlab,']:
            with self.assertRaises(ValueError): release.destinations(value)

    def extension_setup(self):
        import release_dmg
        manifest = dict(self.manifest(), tag='1.0.0')
        apis = {s: FakeAPI(s, manifest) for s in release.SERVICES}
        zipname = release.names(self.root)['source']
        sha = release.digest(release.output(self.root) / zipname)
        for service, api in apis.items():
            api.release = {'id': 7, 'tag_name': '1.0.0', 'draft': False, 'body': 'Keep notes',
                'upload_url': 'https://uploads.github.com' + api.base + '/releases/7/assets{?name,label}',
                'assets': {'links': []}}
            if service == 'github':
                api.assets[zipname] = {'name': zipname, 'digest': 'sha256:' + sha}
            else:
                package = release.package_path(api.base, manifest, zipname)
                api.packages[package] = sha
                api.release['assets']['links'] = [{'name': zipname, 'url': 'https://' + api.host + package}]
        patch('release.API', side_effect=lambda host, token, github=False: apis['github' if github else 'gitlab']).start()
        patch('release.remote_tag', return_value=manifest['commit']).start()
        def fake_run(args, root, capture=False):
            if args[:2] == ['git', 'rev-parse']: return manifest['commit']
            if args[:2] == ['git', 'show']: return '1.0.0'
            return provenance.run(args, root, capture)
        patch('release_dmg.run', side_effect=fake_run).start()
        patch('release_dmg.verify_app').start()
        patch('release_dmg.verify_dmg', return_value={'accepted': True}).start()
        def fake_build(app, image, identity, profile, v):
            image.write_bytes(b'signed disk image fixture')
            return {'accepted': True}
        patch('release_dmg.build_dmg', side_effect=fake_build).start()
        return release_dmg, apis, zipname

    def test_source_archive_is_deterministic(self):
        a, b = self.root / 'one.tar.gz', self.root / 'two.tar.gz'
        source_release.create(a, self.root); source_release.create(b, self.root)
        self.assertEqual(a.read_bytes(), b.read_bytes())

    def test_conflicting_notes_fail_before_tag_push(self):
        manifest, apis, remotes = self.service_setup()
        apis['github'].release = {'id':7, 'tag_name':'v1.0.0','body':'different notes','draft':True}
        with self.assertRaisesRegex(ValueError, 'release notes differ'): release.publish(['github'], True, self.root)
        self.assertFalse(remotes)

    def test_conflicting_gitlab_release_link_is_rejected(self):
        manifest, apis, remotes = self.service_setup(); api = apis['gitlab']
        name = next(iter(manifest['files']))
        api.release = {'tag_name':'v1.0.0','description':manifest['notes'],
                       'assets':{'links':[{'name':name, 'url':'https://elsewhere.invalid/file'}]}}
        with self.assertRaisesRegex(ValueError, 'link destination differs'): release.publish(['gitlab'], True, self.root)
        self.assertFalse(remotes)

    def test_local_conflicting_tag_does_not_push(self):
        manifest, apis, remotes = self.service_setup()
        provenance.run(['git','tag','-a','v1.0.0','-m','Fixture'], self.root)
        # A lightweight tag is refused even if its commit matches.
        provenance.run(['git','tag','-d','v1.0.0'], self.root, True)
        provenance.run(['git','tag','v1.0.0'], self.root)
        with self.assertRaisesRegex(ValueError, 'must be annotated'): release.publish(['github'], True, self.root)
        self.assertFalse(remotes)

    def test_completed_receipt_cannot_hide_deleted_release(self):
        _, apis, _ = self.service_setup()
        with contextlib.redirect_stdout(io.StringIO()): release.publish(['github'], True, self.root)
        apis['github'].release = None
        with self.assertRaisesRegex(ValueError, 'missing remotely'): release.publish(['github'], True, self.root)

    def test_api_does_not_follow_redirects_or_forward_tokens(self):
        from unittest.mock import Mock
        connection = Mock()
        response = Mock(status=302)
        connection.getresponse.return_value = response
        with patch('http.client.HTTPSConnection', return_value=connection):
            api = release.API('api.github.com', 'test-token', True)
            with self.assertRaisesRegex(ValueError, 'HTTP 302'): api.request('GET', '/repos/org/vocalisbook')
            with self.assertRaisesRegex(ValueError, 'Unexpected API host'):
                api.request('POST', '/upload', host='evil.invalid')
        self.assertEqual(connection.request.call_count, 1)

    def test_changed_staged_copy_blocks_publish(self):
        manifest, apis, remotes = self.service_setup()
        (release.publication_folder(self.root)/next(iter(manifest['files']))).write_bytes(b'changed stage')
        with self.assertRaisesRegex(ValueError,'Staged publication asset changed'):
            release.publish(['github'],True,self.root)
        self.assertFalse(remotes)
        self.assertFalse(apis['github'].calls)

    def test_custom_tag_and_annotation_are_frozen(self):
        with contextlib.redirect_stdout(io.StringIO()):
            manifest=release.prepare(self.config,self.root/'Docs/RELEASE-NOTES.md',self.root,
                                     tag='1.0.0',tag_message='VocalisBook 1.0.0 release')
        self.assertEqual(manifest['tag'],'1.0.0')
        self.assertEqual(manifest['tag_message'],'VocalisBook 1.0.0 release')
        with self.assertRaisesRegex(ValueError,'Tag differs'):
            release.publish(['github'],True,self.root,tag='other')
        with self.assertRaisesRegex(ValueError,'annotation differs'):
            release.publish(['github'],True,self.root,tag_message='changed')

    def test_invalid_tags_are_refused(self):
        from release_support import release_tag
        for tag in ('', '-option','bad..tag','bad tag','refs/../tag'):
            with self.assertRaises(ValueError): release_tag(tag)

    def test_configured_destinations_must_match_manifest(self):
        manifest, _, remotes = self.service_setup()
        changed=dict(self.config,github='https://github.com/org/other',github_git='git@github.com:org/other.git')
        with self.assertRaisesRegex(ValueError,'Destination changed'):
            release.publish(['github'],True,self.root,config=changed)
        self.assertFalse(remotes)

    def test_onepassword_credentials_are_captured_without_logging(self):
        import release_support as support
        from types import SimpleNamespace
        config={'credentials':{'github':{'provider':'1password','vault':'Test Vault','item':'github.com','field':'org/vocalisbook-rw'}}}
        result=SimpleNamespace(returncode=0,stdout=json.dumps({'label':'org/vocalisbook-rw','value':'opaque-mock-secret'}))
        with patch('release_support.subprocess.run',return_value=result) as command, contextlib.redirect_stdout(io.StringIO()) as out:
            token=support.credential('github',config)
        self.assertEqual(token,'opaque-mock-secret'); self.assertEqual(out.getvalue(),'')
        args=command.call_args.args[0]
        self.assertIn('label=org/vocalisbook-rw',args)
        self.assertNotIn('opaque-mock-secret',args)

    def test_onepassword_reference_and_failure_do_not_print_secret_output(self):
        import release_support as support
        from types import SimpleNamespace
        config={'credentials':{'gitlab':{'provider':'1password','reference':'op://Vault/Item/Field'}}}
        with patch('release_support.subprocess.run',return_value=SimpleNamespace(returncode=0,stdout='mock-value')) as command:
            self.assertEqual(support.credential('gitlab',config),'mock-value')
            self.assertEqual(command.call_args.args[0],['op','read','--no-newline','op://Vault/Item/Field'])
        with patch('release_support.subprocess.run',return_value=SimpleNamespace(returncode=1,stdout='sensitive stdout',stderr='sensitive stderr')):
            with self.assertRaises(ValueError) as error: support.credential('gitlab',config)
        self.assertNotIn('sensitive',str(error.exception))

    def test_onepassword_ambiguous_fields_are_refused(self):
        import release_support as support
        from types import SimpleNamespace
        config={'credentials':{'github':{'provider':'1password','vault':'V','item':'I','field':'F'}}}
        result=SimpleNamespace(returncode=0,stdout=json.dumps([{'label':'F','value':'a'},{'label':'F','value':'b'}]))
        with patch('release_support.subprocess.run',return_value=result):
            with self.assertRaisesRegex(ValueError,'ambiguous'): support.credential('github',config)

    def test_external_configuration_path_can_be_overridden(self):
        import release_support as support
        with patch.dict(os.environ,{'VOCALISBOOK_RELEASE_CONFIG':'~/release-settings.json'}):
            self.assertEqual(support.default_config_path(),Path.home()/'release-settings.json')

    def test_source_preflight_does_not_push_or_make_release_assets(self):
        import release_support as support
        calls=[]
        def run(args,root,capture=False,env=None):
            calls.append(args)
            if args[:2]==['git','push']: return ''
            return provenance.run(args,root,capture,env)
        with patch('release_support.run',side_effect=run), contextlib.redirect_stdout(io.StringIO()):
            support.push_source(self.config,['github','gitlab'],release.git_destination,dry_run=True,root=self.root)
        pushes=[a for a in calls if a[:2]==['git','push']]
        self.assertEqual(len(pushes),2)
        self.assertTrue(all('--dry-run' in a and '--no-follow-tags' in a for a in pushes))
        self.assertTrue(all('refs/heads/' in a[-1] and 'refs/tags/' not in a[-1] for a in pushes))

    def test_source_upload_requires_confirmation(self):
        import release_support as support
        with patch('release_support.run') as run:
            with self.assertRaisesRegex(ValueError,'confirm-push'):
                support.push_source(self.config,['github'],release.git_destination,root=self.root)
        run.assert_not_called()

    def test_source_preflights_all_destinations_before_push(self):
        import release_support as support
        calls=[]; revision=provenance.commit(self.root)
        def run(args,root,capture=False,env=None):
            calls.append(args)
            if args[:2]==['git','push']: return ''
            if args[:2]==['git','ls-remote']: return revision+'\trefs/heads/main'
            return provenance.run(args,root,capture,env)
        with patch('release_support.run',side_effect=run), contextlib.redirect_stdout(io.StringIO()):
            support.push_source(self.config,['github','gitlab'],release.git_destination,confirmed=True,root=self.root)
        pushes=[a for a in calls if a[:2]==['git','push']]
        self.assertTrue(all('--dry-run' in a for a in pushes[:2]))
        self.assertTrue(all('--dry-run' not in a for a in pushes[2:]))

    def test_initialization_refuses_remote_history_before_local_mutation(self):
        import release_support as support,shutil
        shutil.rmtree(self.root/'.git')
        with patch('release_support.run',return_value='commit\trefs/heads/main'):
            with self.assertRaisesRegex(ValueError,'Remote already has history'):
                support.initialize_source(self.config,['github'],release.git_destination,self.root)
        self.assertFalse((self.root/'.git').exists())

    def test_initialization_only_commits_allowlisted_source(self):
        import release_support as support,shutil
        shutil.rmtree(self.root/'.git')
        # A foreign local file is not staged, even when it is not ignored.
        (self.root/'unrelated-local.txt').write_text('local file')
        def run(args,root,capture=False,env=None):
            if args[:2]==['git','ls-remote']: return ''
            return provenance.run(args,root,capture,env)
        identity={'GIT_AUTHOR_NAME':'Release Test','GIT_AUTHOR_EMAIL':'test@example.invalid',
                  'GIT_COMMITTER_NAME':'Release Test','GIT_COMMITTER_EMAIL':'test@example.invalid'}
        with patch('release_support.run',side_effect=run),patch.dict(os.environ,identity),contextlib.redirect_stdout(io.StringIO()):
            support.initialize_source(self.config,['github'],release.git_destination,self.root)
        tracked=provenance.run(['git','ls-files'],self.root,True).splitlines()
        self.assertNotIn('unrelated-local.txt',tracked)
        self.assertIn('Core/main.swift',tracked)

    def test_combined_release_requires_confirmation_before_prepare(self):
        with patch('release.configuration',return_value=self.config),patch('release.prepare') as prepare,patch('release.publish') as publish:
            with self.assertRaisesRegex(ValueError,'confirm-publish'):
                release.main(['release','--config',str(self.root/'VERSION')])
        prepare.assert_not_called();publish.assert_not_called()

    def test_combined_release_validates_destinations_before_prepare(self):
        with patch('release.configuration',return_value=self.config),patch('release.prepare') as prepare:
            with self.assertRaisesRegex(ValueError,'distinct destinations'):
                release.main(['release','--config',str(self.root/'VERSION'),'--to','github,github','--confirm-publish'])
        prepare.assert_not_called()

    def test_combined_release_uses_prepared_tag_and_config(self):
        with patch('release.configuration',return_value=self.config),patch('release.prepare') as prepare,patch('release.publish') as publish:
            release.main(['release','--config',str(self.root/'VERSION'),'--tag','1.0.0','--tag-message','Release 1.0.0','--to','github','--confirm-publish'])
        self.assertEqual(prepare.call_args.kwargs,{'tag':'1.0.0','tag_message':'Release 1.0.0'})
        self.assertEqual(publish.call_args.args,(['github'],True))
        self.assertEqual(publish.call_args.kwargs,{'config':self.config,'tag':'1.0.0','tag_message':'Release 1.0.0'})

    def test_github_installation_accepts_listed_repo_despite_false_user_flags(self):
        from unittest.mock import Mock
        api=Mock()
        api.request.return_value={'repositories':[{'id':42,'full_name':'org/vocalisbook'}]}
        release.check_github_access({'id':42,'full_name':'org/vocalisbook','permissions':{'push':False}},
                                    'org/vocalisbook',api,'ghs_mock-installation')
        api.request.assert_called_once_with('GET','/installation/repositories?per_page=100&page=1')

    def test_github_installation_must_include_target(self):
        from unittest.mock import Mock
        api=Mock();api.request.return_value={'repositories':[]}
        with self.assertRaisesRegex(ValueError,'does not include'):
            release.check_github_access({'full_name':'org/vocalisbook'},'org/vocalisbook',api,'ghs_mock-installation')

    def test_github_installation_identity_is_not_relaxed(self):
        from unittest.mock import Mock
        api=Mock()
        with self.assertRaisesRegex(ValueError,'identity differs'):
            release.check_github_access({'full_name':'other/repo'},'org/vocalisbook',api,'ghs_mock-installation')
        api.request.assert_not_called()

    def test_github_installation_id_must_match(self):
        from unittest.mock import Mock
        api=Mock();api.request.return_value={'repositories':[{'id':7,'full_name':'org/vocalisbook'}]}
        with self.assertRaisesRegex(ValueError,'ID differs'):
            release.check_github_access({'id':42,'full_name':'org/vocalisbook'},'org/vocalisbook',api,'ghs_mock-installation')

    def test_github_user_token_still_requires_write_access(self):
        from unittest.mock import Mock
        api=Mock()
        for permissions in ({'push':False},{}):
            with self.assertRaisesRegex(ValueError,'does not report repository write'):
                release.check_github_access({'full_name':'org/vocalisbook','permissions':permissions},
                                            'org/vocalisbook',api,'github_pat_mock')
        api.request.assert_not_called()

    def test_github_installation_repository_listing_is_paginated(self):
        from unittest.mock import Mock
        api=Mock();api.request.side_effect=[{'repositories':[{'full_name':'other/repo'}]*100},
                                           {'repositories':[{'full_name':'org/vocalisbook'}]}]
        release.check_github_access({'full_name':'org/vocalisbook'},'org/vocalisbook',api,'ghs_mock-installation')
        self.assertEqual(api.request.call_count,2)

    def test_github_installation_lookup_failure_stops_preflight(self):
        from unittest.mock import Mock
        api=Mock();api.request.side_effect=ValueError('HTTP 403')
        with self.assertRaisesRegex(ValueError,'HTTP 403'):
            release.check_github_access({'full_name':'org/vocalisbook'},'org/vocalisbook',api,'ghs_mock-installation')

    def test_plan_is_offline_and_unsigned(self):
        with patch('release.run') as run, patch('release.API') as api, contextlib.redirect_stdout(io.StringIO()) as out:
            release.main(['plan', '--config', str(self.root / 'missing.json')])
        run.assert_not_called(); api.assert_not_called()
        self.assertIn('make check', out.getvalue())
        self.assertNotIn('notarytool', out.getvalue())

    def test_build_checks_once_and_strips_token_environment(self):
        import shutil
        shutil.rmtree(self.root / 'outputs')
        config = dict(self.config, env={'VOCALISBOOK_RELEASE_PYTHON': '/persistent/python'},
                      credentials={'gitlab': {'provider': 'env', 'variable': 'CUSTOM_TOKEN'}})
        observed = []
        def fake_run(args, root, capture=False, env=None):
            if env is not None:
                self.assertNotIn('GITHUB_TOKEN', env); self.assertNotIn('GITLAB_TOKEN', env)
                self.assertNotIn('CUSTOM_TOKEN', env)
                observed.append(args)
            return 'Swift fixture' if args == ['swift', '--version'] else None
        with patch.dict(os.environ, {'CUSTOM_TOKEN': 'private-fixture-token'}), patch('release.run', side_effect=fake_run):
            release.build(config, self.root)
        self.assertEqual(observed, release.build_commands(config))
        self.assertEqual(observed[0][0], '/persistent/python')
        self.assertEqual(len(observed), 4)
        release.check(self.root)

    def test_source_mutation_during_checks_blocks_packaging(self):
        import shutil
        shutil.rmtree(self.root / 'outputs')
        def fake_run(args, root, capture=False, env=None):
            if args == ['make', 'check']:
                (root / 'Core/main.swift').write_text('mutated')
        with patch('release.run', side_effect=fake_run):
            with self.assertRaisesRegex(ValueError, 'Source changed during build'):
                release.build(self.config, self.root)
        self.assertFalse(release.output(self.root).exists())

    def test_publication_contains_source_website_provenance_and_checksums(self):
        manifest = self.manifest()
        n = release.names(self.root)
        expected = set(n.values()) | {'SHA256SUMS', n['source'] + '.sha256', n['website'] + '.sha256'}
        self.assertEqual(set(manifest['files']), expected)
        self.assertFalse(any(name.endswith(('.dmg', '.ipa', '.app')) for name in manifest['files']))

    def test_xcode_and_swiftpm_products_are_not_source_inputs(self):
        for name in ('Core/.build/checkouts/Private.swift', 'Platform/.swiftpm/local',
                     'Apps/iOS/VocalisBook.xcodeproj/project.pbxproj', 'Apps/iOS/build.number'):
            path = self.root / name; path.parent.mkdir(parents=True, exist_ok=True); path.write_text('generated')
        files = {str(p.relative_to(self.root)) for p in provenance.source_files(self.root)}
        self.assertIn('Core/main.swift', files)
        self.assertFalse(any('.build' in p or '.swiftpm' in p or '.xcodeproj' in p or 'build.number' in p for p in files))

    def test_symlinked_source_directory_is_refused(self):
        outside = self.root / 'outside'; outside.mkdir()
        (self.root / 'Apps/linked').symlink_to(outside, target_is_directory=True)
        with self.assertRaisesRegex(ValueError, 'Symlinked source'):
            provenance.source_files(self.root)

    def test_private_environment_file_is_not_packaged(self):
        (self.root / 'Apps/.env').write_text('private')
        with self.assertRaisesRegex(ValueError, 'Private configuration'):
            provenance.source_files(self.root)

    def test_website_archive_is_reproducible_and_contains_license(self):
        a, b = self.root / 'web-a.tar.gz', self.root / 'web-b.tar.gz'
        release.create_website(a, self.root); release.create_website(b, self.root)
        self.assertEqual(a.read_bytes(), b.read_bytes())
        with tarfile.open(a) as archive:
            self.assertIn('LICENSE', archive.getnames())

    def test_corrupt_website_cannot_be_hidden_by_new_checksums(self):
        with tarfile.open(release.output(self.root) / release.names(self.root)['website'], 'w:gz'):
            pass
        self.write_sums()
        with self.assertRaises(ValueError): release.check(self.root)

    def test_platform_versions_are_preserved_independently(self):
        (self.root / 'Config/tvOS.xcconfig').write_text('MARKETING_VERSION = 2.0.0\n')
        versions = release.platform_versions(self.root)
        self.assertEqual(versions, {'iOS': '1.0.0', 'macOS': '1.0.0', 'tvOS': '2.0.0'})

    def test_custom_tags_use_separate_gitlab_package_versions(self):
        manifest = self.manifest()
        first = release.package_path('/api/v4/projects/test', manifest, 'asset')
        manifest['tag'] = 'macos/v1.0.0'
        second = release.package_path('/api/v4/projects/test', manifest, 'asset')
        self.assertNotEqual(first, second)
        self.assertIn('/tag-', second)
        self.assertNotIn('/macos/', second)

    def test_gitlab_nested_group_path_is_encoded(self):
        manifest = self.manifest()
        base, path = release.release_paths('gitlab', manifest)
        self.assertIn('group%2Fsubgroup%2Fvocalisbook', base)

    def test_known_credentials_in_configured_custom_environment_are_detected(self):
        path = self.root / 'settings.json'
        path.write_text(json.dumps({'credentials': {'gitlab': {'provider': 'env', 'variable': 'PRIVATE_RELEASE_TOKEN'}}}))
        with patch.dict(os.environ, {'PRIVATE_RELEASE_TOKEN': 'secret-custom-fixture'}):
            release.configuration(path)
            with self.assertRaisesRegex(ValueError, 'credential'):
                release.secret_check('secret-custom-fixture')

    def test_conflicting_existing_tag_annotation_blocks_remote_writes(self):
        manifest, apis, remotes = self.service_setup()
        provenance.run(['git', 'tag', '-a', manifest['tag'], '-m', 'Different annotation'], self.root)
        with self.assertRaisesRegex(ValueError, 'annotation differs'):
            release.publish(['github'], True, self.root)
        self.assertFalse(remotes)
        self.assertFalse(any(c[0] != 'GET' for api in apis.values() for c in api.calls))

    def test_multiline_tag_annotation_is_preserved(self):
        manifest, apis, remotes = self.service_setup()
        # Keep the same source snapshot but prepare a different local manifest.
        with contextlib.redirect_stdout(io.StringIO()):
            manifest = release.prepare(self.config, self.root / 'Docs/RELEASE-NOTES.md', self.root,
                                       tag_message='Release heading\n\n# Literal annotation line')
        provenance.run(['git', 'tag', '-a', '--cleanup=verbatim', manifest['tag'], '-m', manifest['tag_message']], self.root)
        release.validate_local_tag(manifest, self.root)



if __name__ == '__main__': unittest.main()
