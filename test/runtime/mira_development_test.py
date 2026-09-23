import ast,unittest
from pathlib import Path
ROOT=Path(__file__).resolve().parents[2]
class DevelopmentTest(unittest.TestCase):
 def test_rails_wrapper_uses_environment_allowlist(self):
  source=(ROOT/'agent-runtime/mira-rails').read_text()
  ast.parse(source)
  self.assertNotIn('**os.environ',source)
  self.assertIn("environment not in ('development','test')",source)
  self.assertNotIn("'GH_CONFIG_DIR'",source)
  self.assertNotIn("'SOULSHOUSE_BEARER_TOKEN'",source)
 def test_private_database_has_no_tcp_listener(self):
  source=(ROOT/'agent-runtime/mira-dev-db').read_text()
  self.assertIn("listen_addresses=''",source)
  self.assertIn('--auth-host=reject',source)
  self.assertIn('--encoding=UTF8',source)
  self.assertNotIn('0.0.0.0',source)
 def test_wrapper_executes_test_with_only_test_key(self):
  import json,os,runpy,sys
  from unittest.mock import patch
  with patch.dict(os.environ,{'PATH':'/usr/bin','PGHOST':'/private/socket','SOULSHOUSE_BEARER_TOKEN':'fake-chat-token','OPENAI_API_KEY':'fake-provider-key'},clear=True), patch.object(sys,'argv',['mira-rails','test','test/example_test.rb']), patch.object(Path,'read_text',return_value=json.dumps({'development':'fake-dev','test':'fake-test'})), patch.object(os,'execve') as execute:
   runpy.run_path(str(ROOT/'agent-runtime/mira-rails'),run_name='__main__')
   env=execute.call_args.args[2]
   self.assertEqual(env['RAILS_MASTER_KEY'],'fake-test')
   self.assertEqual(env['RAILS_ENV'],'test')
   self.assertNotIn('SOULSHOUSE_BEARER_TOKEN',env)
   self.assertNotIn('OPENAI_API_KEY',env)
 def test_wrapper_refuses_production_before_key_read(self):
  import os,runpy,sys
  from unittest.mock import patch
  with patch.dict(os.environ,{'RAILS_ENV':'production'}), patch.object(sys,'argv',['mira-rails','runner','1']), patch.object(Path,'read_text') as read:
   with self.assertRaises(SystemExit):runpy.run_path(str(ROOT/'agent-runtime/mira-rails'),run_name='__main__')
   read.assert_not_called()
