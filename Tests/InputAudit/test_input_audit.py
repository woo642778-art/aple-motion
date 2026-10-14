import hashlib
import importlib.util
import json
from pathlib import Path
import struct
import tempfile
import unittest
from unittest import mock
import warnings
import zipfile

SCRIPT = Path(__file__).resolve().parents[2] / 'scripts' / 'audit-aple-input.py'


class InputAuditTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.output = self.root / 'report'
        self.manifest = self.root / 'manifest(1).json'
        self.assertTrue(SCRIPT.is_file(), 'The read-only archive audit is not implemented')
        spec = importlib.util.spec_from_file_location('aple_input_audit', SCRIPT)
        self.module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.module)

    def fixture(self, data=None, chunks=None, archive_name='Part_001(1).zip'):
        if data is None:
            data = struct.pack('<IiiIIIII', 0xfeedfacf, 0x0100000c, 0, 2, 0, 0, 0, 0)
        chunks = chunks if chunks is not None else [data]
        path = 'Payload/Aple_motion.app/AlightMotion'
        pieces = []
        with zipfile.ZipFile(self.root / archive_name, 'w') as archive:
            for index, chunk in enumerate(chunks):
                member = path if len(chunks) == 1 else f'__IPA_UPLOAD_CHUNKS_/piece{index}'
                archive.writestr(member, chunk)
                pieces.append({'archive': 'Part_001.zip', 'member': member,
                               'bytes': len(chunk), 'sha256': hashlib.sha256(chunk).hexdigest()})
        document = {'format': 'ipa-upload-parts-v1', 'source_name': 'test.ipa', 'files': [
            {'path': path, 'bytes': len(data), 'kind': 'file', 'unix_mode': 33261,
             'split': len(chunks) > 1, 'pieces': pieces,
             'sha256': hashlib.sha256(data).hexdigest()}]}
        self.manifest.write_text(json.dumps(document), encoding='utf-8')
        return document

    def rewrite(self, document):
        self.manifest.write_text(json.dumps(document), encoding='utf-8')

    def audit(self, **kwargs):
        return self.module.run_audit(self.manifest, self.root, self.output, **kwargs)

    def assert_rejected(self):
        with self.assertRaises(self.module.AuditError):
            self.audit()
        self.assertFalse(self.output.exists(), 'A failed audit must not leave a success report')

    def test_uploaded_suffix_and_original_unchanged(self):
        self.fixture()
        original = (self.root / 'Part_001(1).zip').read_bytes()
        result = self.audit()
        self.assertEqual(result['verified_files'], 1)
        self.assertEqual(result['native_binary_count'], 1)
        self.assertFalse(result['native_metadata_collected'])
        self.assertFalse(result['host_binding_verified'])
        self.assertFalse(result['ipa_generated'])
        self.assertEqual(original, (self.root / 'Part_001(1).zip').read_bytes())
        self.assertTrue((self.output / 'audit.json').is_file())

    def test_piece_order_and_split_magic(self):
        data = struct.pack('<IiiIIIII', 0xfeedfacf, 0x0100000c, 0, 2, 0, 0, 0, 0)
        self.fixture(data=data, chunks=[data[:2], data[2:13], data[13:]])
        result = self.audit()
        self.assertEqual(result['native_binary_count'], 1)
        self.assertEqual(result['verified_bytes'], len(data))

    def test_piece_hash_mismatch(self):
        doc = self.fixture()
        doc['files'][0]['pieces'][0]['sha256'] = '0' * 64
        self.rewrite(doc)
        self.assert_rejected()

    def test_assembled_hash_mismatch(self):
        doc = self.fixture()
        doc['files'][0]['sha256'] = '0' * 64
        self.rewrite(doc)
        self.assert_rejected()

    def test_declared_size_mismatch(self):
        doc = self.fixture()
        doc['files'][0]['bytes'] += 1
        self.rewrite(doc)
        self.assert_rejected()

    def test_missing_piece(self):
        doc = self.fixture()
        doc['files'][0]['pieces'][0]['member'] = 'missing'
        self.rewrite(doc)
        self.assert_rejected()

    def test_duplicate_zip_members(self):
        self.fixture()
        with warnings.catch_warnings():
            warnings.simplefilter('ignore')
            with zipfile.ZipFile(self.root / 'Part_001(1).zip', 'a') as archive:
                archive.writestr('Payload/Aple_motion.app/AlightMotion', b'other')
        self.assert_rejected()

    def test_manifest_path_traversal(self):
        doc = self.fixture()
        doc['files'][0]['path'] = '../escape'
        self.rewrite(doc)
        self.assert_rejected()
        self.assertFalse((self.root.parent / 'escape').exists())

    def test_zip_path_traversal_even_when_unreferenced(self):
        self.fixture()
        with zipfile.ZipFile(self.root / 'Part_001(1).zip', 'a') as archive:
            archive.writestr('../escape', b'bad')
        self.assert_rejected()

    def test_duplicate_manifest_paths(self):
        doc = self.fixture()
        doc['files'].append(dict(doc['files'][0]))
        self.rewrite(doc)
        self.assert_rejected()

    def test_ambiguous_parts(self):
        self.fixture()
        (self.root / 'Part_001(2).zip').write_bytes((self.root / 'Part_001(1).zip').read_bytes())
        self.assert_rejected()

    def test_report_archive_has_no_payload_or_binaries(self):
        self.fixture()
        self.audit()
        with zipfile.ZipFile(self.output / 'Aple-editor-audit.zip') as report:
            self.assertEqual(set(report.namelist()), {'audit.json'})
        self.assertEqual({p.name for p in self.output.iterdir()}, {'audit.json', 'Aple-editor-audit.zip'})

    def test_non_native_file_is_verified_but_not_exported(self):
        self.fixture(data=b'not a native executable')
        result = self.audit()
        self.assertEqual(result['native_binary_count'], 0)
        self.assertEqual(result['verified_files'], 1)

    def test_existing_output_is_not_replaced(self):
        self.fixture()
        self.output.mkdir()
        marker = self.output / 'keep.txt'
        marker.write_text('keep')
        with self.assertRaises(self.module.AuditError):
            self.audit()
        self.assertEqual(marker.read_text(), 'keep')

    def test_missing_native_tools_cannot_claim_native_inspection(self):
        self.fixture()
        with mock.patch.object(self.module.shutil, 'which', return_value=None):
            with self.assertRaises(self.module.AuditError):
                self.audit(native_tools=True)
        self.assertFalse(self.output.exists())

    def test_native_tool_failure_cannot_leave_success(self):
        self.fixture()
        with mock.patch.object(self.module.shutil, 'which', return_value='/usr/bin/xcrun'):
            with mock.patch.object(self.module.subprocess, 'run', side_effect=OSError('tool failure')):
                with self.assertRaises(self.module.AuditError):
                    self.audit(native_tools=True)
        self.assertFalse(self.output.exists())


if __name__ == '__main__':
    unittest.main()
