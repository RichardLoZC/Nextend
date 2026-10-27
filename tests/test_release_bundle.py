import base64, json, shutil, subprocess, sys, tempfile, unittest
from pathlib import Path
from unittest.mock import patch
ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT/'ops'))
import release_bundle as release

class ReleaseTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory(dir=ROOT/'work', prefix='release-tests-'); cls.base = Path(cls.temp.name)
        cls.key = cls.base/'key.pem'; cls.public = cls.base/'public.pem'
        subprocess.run(['openssl','genpkey','-algorithm','RSA','-pkeyopt','rsa_keygen_bits:2048','-out',str(cls.key)],check=True,capture_output=True)
        subprocess.run(['openssl','pkey','-in',str(cls.key),'-pubout','-out',str(cls.public)],check=True,capture_output=True)
    @classmethod
    def tearDownClass(cls): cls.temp.cleanup()
    def setUp(self): self.dir=Path(tempfile.mkdtemp(dir=self.base)); self.live=self.dir/'public'; self.state=self.dir/'state'
    def bundle(self, build, content=b'APK', output='bundle'):
        apk=self.dir/f'input-{output}';apk.write_bytes(content)
        spec={'application':'dev.test.app','channel':'stable','notes':'test','platforms':{'android':{'build':build,'version':f'1.0.{build}','path':f'updates/Test-{build}.apk','file':str(apk)}}}
        spec_file=self.dir/f'{output}.json';spec_file.write_text(json.dumps(spec))
        dest=self.dir/output;release.prepare(spec_file,self.key,self.public,dest);return dest
    def commit(self,bundle): return release.commit(bundle,self.live,self.state,self.public,'dev.test.app')
    def test_idempotent_publish_and_version_guard(self):
        first=self.bundle(2); self.commit(first)
        before=(self.live/'updates/manifest.json').read_bytes();self.commit(first)
        self.assertEqual(before,(self.live/'updates/manifest.json').read_bytes())
        for bundle in [self.bundle(1,output='older'),self.bundle(2,b'changed',output='collision')]:
            with self.assertRaises(ValueError): self.commit(bundle)
        self.assertEqual(before,(self.live/'updates/manifest.json').read_bytes())
    def test_tampering_and_wrong_app_rejected(self):
        bundle=self.bundle(1)
        with self.assertRaises(ValueError): release.verify_bundle(bundle,self.public,'another.app')
        (bundle/'updates/Test-1.apk').write_bytes(b'bad')
        with self.assertRaises(ValueError): self.commit(bundle)
        self.assertFalse((self.live/'updates/manifest.json').exists())
    def test_bad_signature_rejected(self):
        bundle=self.bundle(1);p=bundle/'updates/manifest.json';j=json.loads(p.read_text());j['payload']=base64.b64encode(b'{}').decode();p.write_text(json.dumps(j))
        with self.assertRaises(subprocess.CalledProcessError): self.commit(bundle)
    def test_copy_failure_keeps_old_feed(self):
        self.commit(self.bundle(1)); old=(self.live/'updates/manifest.json').read_bytes();next=self.bundle(2,output='next')
        actual=release.copy_atomic
        def fail(source,target):
            if Path(target).name=='Test-2.apk':raise OSError('disk full')
            actual(source,target)
        with patch.object(release,'copy_atomic',fail):
            with self.assertRaises(OSError):self.commit(next)
        self.assertEqual(old,(self.live/'updates/manifest.json').read_bytes())
        self.commit(next)
        self.assertEqual(2,release.verify_bundle(self.live,self.public,'dev.test.app')[0]['platforms']['android']['build'])
    def test_path_traversal_and_symlink_rejected(self):
        bundle=self.bundle(1);j=release.verify_bundle(bundle,self.public)[0];j['platforms']['android']['path']='updates/../private.apk'
        with self.assertRaises(ValueError):release.checked_manifest(j)
        artifact=bundle/'updates/Test-1.apk';artifact.unlink();artifact.symlink_to(self.dir/'input-bundle')
        with self.assertRaises(ValueError):self.commit(bundle)
    def test_concurrent_publish_never_regresses(self):
        import concurrent.futures
        a=self.bundle(1,output='a');b=self.bundle(2,output='b')
        with concurrent.futures.ThreadPoolExecutor(2) as pool:
            futures=[pool.submit(self.commit,x) for x in (a,b)]
            for f in futures:
                try:f.result()
                except ValueError as e:self.assertIn('rollback',str(e))
        self.assertEqual(2,release.verify_bundle(self.live,self.public)[0]['platforms']['android']['build'])
if __name__=='__main__':unittest.main()
