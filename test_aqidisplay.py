import contextlib
from concurrent.futures import Future
from datetime import datetime, timedelta
import io
import logging
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import Mock, patch
import requests
from core import APIError, Client, History, Redact, SingleInstance, load_token, save_settings, load_settings
from login_item_manager import launch_configuration, LoginItemManager
from migrate_legacy import migrate


def reading(city='Test City', aqi=42):
    return {'aqi': aqi, 'city': {'name': city}, 'iaqi': {'t': {'v': 20}}}


class CoreTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.env = patch.dict(os.environ, {'OPENAIR_DATA_DIR': self.directory.name, 'WAQI_API_TOKEN': ''})
        self.env.start()
        self.addCleanup(self.env.stop)

    def test_missing_token_no_request(self):
        with patch('core.requests.get') as get, self.assertRaises(APIError):
            Client('').feed('here')
        get.assert_not_called()

    def test_token_file_and_environment_override(self):
        Path(self.directory.name, 'waqi-token').write_text('local-secret\n')
        self.assertEqual(load_token(), 'local-secret')
        with patch.dict(os.environ, WAQI_API_TOKEN='override'):
            self.assertEqual(load_token(), 'override')

    def test_feed_locations_and_timeout(self):
        with patch('core.requests.get') as get:
            get.return_value.json.return_value = {'status': 'ok', 'data': reading()}
            for location, suffix in [('here','here'), ('@123','@123'), ('1;2','geo:1;2'), ('San Francisco','San%20Francisco')]:
                self.assertEqual(Client('secret').feed(location)['aqi'],42)
                self.assertEqual(get.call_args.args[0], f'https://api.waqi.info/feed/{suffix}/')
                self.assertEqual(get.call_args.kwargs['timeout'], (5,15))
                self.assertEqual(get.call_args.kwargs['params'], {'token':'secret'})

    def test_unavailable_and_malformed_feed(self):
        with patch('core.requests.get') as get:
            for data in [None, [], {}, reading(aqi='-'), reading(aqi='nan'), reading(aqi=-1)]:
                get.return_value.json.return_value = {'status': 'ok', 'data': data}
                with self.assertRaises(APIError):
                    Client('secret').feed('here')

    def test_invalid_json_and_http_error_do_not_expose_secret(self):
        for error in [ValueError('bad json token=secret'), requests.Timeout('https://host/?token=secret')]:
            with patch('core.requests.get', side_effect=error):
                with self.assertRaises(APIError) as caught:
                    Client('secret').feed('here')
                self.assertNotIn('secret', str(caught.exception))

    def test_missing_weather_remains_missing(self):
        with patch('core.requests.get') as get:
            data = reading()
            data['iaqi'] = {'t': {'v':'-'}, 'w': {'v':0}, 'h':None}
            get.return_value.json.return_value = {'status':'ok','data':data}
            self.assertEqual(Client('secret').feed('here')['iaqi'], {'w':{'v':0.0}})

    def test_search_encoding_and_validation(self):
        with patch('core.requests.get') as get:
            get.return_value.json.return_value = {'status':'ok','data':[{}, {'uid':1,'station':{'name':'A'}}]}
            self.assertEqual(len(Client('secret').search(' A & B ')),1)
            self.assertEqual(get.call_args.kwargs['params']['keyword'],'A & B')
            get.reset_mock()
            self.assertEqual(Client('secret').search(' '),[])
            get.assert_not_called()

    def test_history_retains_old_and_different_cities(self):
        history = History(':memory:')
        self.addCleanup(history.connection.close)
        now = datetime.now().replace(minute=30,second=0,microsecond=0)
        history.store(reading('Old'), now-timedelta(days=500))
        history.store(reading('A'),now-timedelta(minutes=1))
        history.store(reading('B'),now)
        history.store(reading('A',60),now)
        self.assertEqual(history.connection.execute('SELECT COUNT(*) FROM aqi_data').fetchone()[0],4)
        self.assertEqual(len(history.recent('A')),1)
        self.assertEqual(history.recent('A')[0][2],60)
        self.assertIsNone(history.recent('A')[0][3])
        self.assertEqual(history.recent('A')[0][9],20)
        self.assertEqual(len(history.recent('B')),1)

    def test_settings_round_trip_and_bad_json(self):
        save_settings({'city':'@123'})
        self.assertEqual(load_settings()['city'],'@123')
        Path(self.directory.name,'settings.json').write_text('broken')
        self.assertEqual(load_settings(),{})

    def test_lock_loser_does_not_release_owner(self):
        first, second, third = SingleInstance(), SingleInstance(), SingleInstance()
        self.addCleanup(first.cleanup)
        self.addCleanup(second.cleanup)
        self.addCleanup(third.cleanup)
        self.assertFalse(first.is_running())
        self.assertTrue(second.is_running())
        second.cleanup()
        self.assertTrue(third.is_running())
        first.cleanup()
        self.assertFalse(third.is_running())

    def test_logs_redact_token_and_exception(self):
        with patch.dict(os.environ, WAQI_API_TOKEN='secret'):
            record = logging.LogRecord('test',20,'',0,'URL token=%s other secret',('secret',),None)
            Redact().filter(record)
            self.assertNotIn('secret',record.getMessage())

    def test_launch_config_source_and_bundle(self):
        import sys
        source = launch_configuration(sys.executable,False)
        self.assertTrue(source['ProgramArguments'][1].endswith('/app.py'))
        bundle = launch_configuration(sys.executable,True)
        self.assertEqual(bundle['ProgramArguments'],[str(Path(sys.executable).absolute())])
        self.assertNotIn('StartInterval',bundle)
        self.assertNotIn('WorkingDirectory',bundle)

    def test_login_construction_does_not_enable(self):
        with patch('login_item_manager.subprocess.run') as run:
            LoginItemManager()
            run.assert_not_called()

    def test_legacy_import_preserves_existing_files(self):
        source = Path(self.directory.name,'legacy')
        source.mkdir()
        (source/'app.py').write_text('self.token = "test-secret"')
        history = History(source/'aqi_data.db')
        history.store(reading('Legacy'))
        history.connection.close()
        migrate(source)
        self.assertEqual(load_token(),'test-secret')
        target = Path(self.directory.name,'aqi_data.db')
        before = target.read_bytes()
        Path(self.directory.name,'waqi-token').write_text('new-secret')
        migrate(source)
        self.assertEqual(target.read_bytes(),before)
        self.assertEqual(load_token(),'new-secret')
        self.assertTrue((source/'aqi_data.db').exists())


class AppTests(unittest.TestCase):
    def make_app(self):
        from app import AQIDisplay
        app = Mock()
        app.pending = None
        app.pending_city = 'here'
        app.current_city = 'here'
        app.search_window = None
        app.cached_data = None
        app.last_update_time = __import__('time').monotonic()
        app.update_interval = 300
        app.error = None
        app.format_options = {'City':False,'AQI':True,'PM2.5':False,'PM10':False,'O₃':False,'NO₂':False,'SO₂':False,'CO':False,'Temperature':True,'Humidity':False,'Wind':False}
        app.temperature_unit = '°F'
        return app, AQIDisplay

    def test_offline_first_launch_title(self):
        app, cls = self.make_app()
        app.client.token = ''
        cls.update_title(app)
        self.assertEqual(app.title,'OpenAir · Setup')

    def test_temperature_and_stale_title(self):
        app, cls = self.make_app()
        app.cached_data = reading()
        app.error = 'offline'
        cls.update_title(app)
        self.assertEqual(app.title,'AQI: 42 | 68.0°F · Stale')

    def test_failed_refresh_preserves_last_reading(self):
        app, cls = self.make_app()
        app.cached_data = reading()
        app.pending = Future()
        app.pending.set_exception(APIError('offline'))
        cls.update(app,None)
        self.assertEqual(app.cached_data['aqi'],42)
        self.assertEqual(app.error,'offline')
        app.history.store.assert_not_called()

    def test_obsolete_station_result_is_discarded(self):
        app, cls = self.make_app()
        app.pending_city = '@old'
        app.pending = Future()
        app.pending.set_result(reading('Old'))
        cls.update(app,None)
        self.assertIsNone(app.cached_data)
        app.history.store.assert_not_called()

    def test_refresh_does_not_overlap(self):
        app, cls = self.make_app()
        app.pending = Future()
        cls.update(app,None,force=True)
        app.executor.submit.assert_not_called()


if __name__ == '__main__':
    unittest.main()
