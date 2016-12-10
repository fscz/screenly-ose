#!/usr/bin/env python
# -*- coding: utf-8 -*-

from datetime import datetime, timedelta
from os import path, getenv, utime, listdir
import os
from platform import machine
from random import shuffle
from requests import get as req_get
from time import sleep
from json import load as json_load
from signal import signal, SIGUSR1, SIGUSR2
import logging
import sh
import urllib

from settings import settings
import html_templates
from lib.utils import url_fails, get_mimetype, get_video_duration
from lib import db
from lib import assets_helper


__author__ = "WireLoad Inc"
__copyright__ = "Copyright 2012-2016, WireLoad Inc"
__license__ = "Dual License: GPLv2 and Commercial License"


SPLASH_DELAY = 60  # secs
EMPTY_PL_DELAY = 5  # secs

BLACK_PAGE = '/tmp/screenly_html/black_page.html'
WATCHDOG_PATH = '/tmp/screenly.watchdog'
SCREENLY_HTML = '/tmp/screenly_html/'
LOAD_SCREEN = '/screenly/loading.jpg'  # relative to $HOME
UZBLRC = '/.config/uzbl/config-screenly'  # relative to $HOME
INTRO = '/screenly/intro-template.html'

current_browser_url = None
browser = None

VIDEO_TIMEOUT = 20  # secs

HOME = None
arch = None
db_conn = None


def sigusr1(signum, frame):
    """
    The signal interrupts sleep() calls, so the currently playing web or image asset is skipped.
    omxplayer is killed to skip any currently playing video assets.
    """
    logging.info('USR1 received, skipping.')
    sh.killall('omxplayer.bin', _ok_code=[1])


def sigusr2(signum, frame):
    """Reload settings"""
    logging.info("USR2 received, reloading settings.")
    load_settings()


class Scheduler(object):
    def __init__(self, *args, **kwargs):
        logging.debug('Scheduler init')
        self.assets = []
        self.deadline = None
        self.index = 0
        self.counter = 0
        self.update_playlist()

    def get_next_asset(self):
        logging.debug('get_next_asset')
        self.refresh_playlist()
        logging.debug('get_next_asset after refresh')
        if not self.assets:
            return None
        idx = self.index
        self.index = (self.index + 1) % len(self.assets)
        logging.debug('get_next_asset counter %s returning asset %s of %s', self.counter, idx + 1, len(self.assets))
        if settings['shuffle_playlist'] and self.index == 0:
            self.counter += 1
        return self.assets[idx]

    def refresh_playlist(self):
        logging.debug('refresh_playlist')
        time_cur = datetime.utcnow()
        logging.debug('refresh: counter: (%s) deadline (%s) timecur (%s)', self.counter, self.deadline, time_cur)
        if self.get_db_mtime() > self.last_update_db_mtime:
            logging.debug('updating playlist due to database modification')
            self.update_playlist()
        elif settings['shuffle_playlist'] and self.counter >= 5:
            self.update_playlist()
        elif self.deadline and self.deadline <= time_cur:
            self.update_playlist()

    def update_playlist(self):
        logging.debug('update_playlist')
        self.last_update_db_mtime = self.get_db_mtime()
        new_assets = generate_asset_list()
        if new_assets == self.assets:
            # If nothing changed, don't disturb the current play-through.
            return

        self.assets = new_assets
        self.counter = 0
        # Try to keep the same position in the play list. E.g. if a new asset is added to the end of the list, we
        # don't want to start over from the beginning.
        self.index = self.index % len(self.assets) if self.assets else 0
        logging.debug('update_playlist done, count %s, counter %s, index %s', len(self.assets), self.counter, self.index)

    def get_db_mtime(self):
        # get database file last modification time
        try:
            return path.getmtime(settings['database'])
        except:
            return 0


def generate_asset_list():
    logging.info('Generating asset-list...')
    assets = assets_helper.read(db_conn)

    playlist = filter(assets_helper.is_active, assets)

    if settings['shuffle_playlist']:
        shuffle(playlist)

    return playlist


def watchdog():
    """Notify the watchdog file to be used with the watchdog-device."""
    if not path.isfile(WATCHDOG_PATH):
        open(WATCHDOG_PATH, 'w').close()
    else:
        utime(WATCHDOG_PATH, None)


def load_browser(url=None):
    global browser, current_browser_url
    logging.info('Loading browser...')

    if browser:
        logging.info('killing previous uzbl %s', browser.pid)
        browser.process.kill()

    if url is not None:
        current_browser_url = url

    # --config=-       read commands (and config) from stdin
    # --print-events   print events to stdout
    browser = sh.Command('uzbl-browser')(print_events=True, config='-', uri=current_browser_url, _bg=True)
    logging.info('Browser loading %s. Running as PID %s.', current_browser_url, browser.pid)

    uzbl_rc = 'set ssl_verify = {}\n'.format('1' if settings['verify_ssl'] else '0')
    with open(HOME + UZBLRC) as f:  # load uzbl.rc
        uzbl_rc = f.read() + uzbl_rc
    browser_send(uzbl_rc)


def browser_send(command, cb=lambda _: True):
    if not (browser is None) and browser.process.alive:
        while not browser.process._pipe_queue.empty():  # flush stdout
            browser.next()

        browser.process.stdin.put(command + '\n')
        while True:  # loop until cb returns True
            if cb(browser.next()):
                break
    else:
        logging.info('browser found dead, restarting')
        load_browser()


def browser_clear():
    """Load a black page. Default cb waits for the page to load."""
    browser_send('uri ' + 'file://' + BLACK_PAGE, cb=lambda buf: 'LOAD_FINISH' in buf and BLACK_PAGE in buf)

def view_url(url, duration, cb=lambda _: True, force=False):
    global current_browser_url

    if url == current_browser_url and not force:
        logging.debug('Already showing %s, reloading it.', current_browser_url)
    else:
        current_browser_url = url
        browser_send('uri ' + current_browser_url, cb=cb)
        logging.info('current url is %s', current_browser_url)

    logging.info('Sleeping for %s seconds', duration)
    sleep(duration)


def view_image(uri, duration):
    uri = urllib.quote(uri)
    logging.info("view_image: %s" % uri)
    browser_clear()
    browser_send('js window.setimg("{0}")'.format(uri), cb=lambda b: 'COMMAND_EXECUTED' in b and 'setimg' in b)
    logging.info('Sleeping for %s', duration)
    sleep(duration)

def view_video(uri, duration):
    logging.info('view_video (%s) for (%s) seconds', uri, duration)

    if arch in ('armv6l', 'armv7l'):
        player_args = ['omxplayer', uri]
        player_kwargs = {'o': settings['audio_output'], '_bg': True, '_ok_code': [0, 124]}
        player_kwargs['_ok_code'] = [0, 124]
    else:
        player_args = ['mplayer', uri, '-nosound']
        player_kwargs = {'_bg': True}

    if duration and duration != 'N/A':
        player_args = ['timeout', VIDEO_TIMEOUT + duration] + player_args

    run = sh.Command(player_args[0])(*player_args[1:], **player_kwargs)

    browser_clear()
    while run.process.alive:
        watchdog()
        sleep(1)
    if run.exit_code == 124:
        logging.error('omxplayer timed out')

def view_directory(uri, duration, entry_duration=10):    
    slideshow = [path.join(uri, f) for f in os.listdir(uri) if path.isfile(path.join(uri, f))]

    num_entries = len(slideshow)
    num = 0
    if num_entries > 0:
        shuffle(slideshow)
        while True:            
            entry = slideshow[num]
            mime = get_mimetype(entry)
            if mime is not None:
                if 'image' in mime:                
                    view_image(entry, entry_duration)            
                    duration -= entry_duration                     
                elif 'video' in mime:
                    video_duration = get_video_duration(entry)
                    view_video(entry, video_duration)
                    duration -= video_duration                    
                elif 'text' in mime:                
                    with open(entry, 'r') as urlfile:
                        try:
                            view_url(urlfile.readlines()[0].replace('\n', ''), entry_duration)
                            duration -= entry_duration                             
                        except Exception as e:
                            logging.error('cannot show text file: %s, error: %s' % (entry, e))  
                else:
                    logging.info('mimetype (%s) of file (%s) not supported.' % (mime, entry))
            else:
                logging.info('cannot show suspect file: %s' % entry)

            num = (num+1) % num_entries
            if duration <= 0:                
                break


def process_playlist(scheduler):
    logging.debug('Start playlist loop.')
    while True:
        check_update()
        asset = scheduler.get_next_asset()

        if asset is None:
            logging.info('Playlist is empty. Sleeping for %s seconds', EMPTY_PL_DELAY)
            view_image(HOME + LOAD_SCREEN, EMPTY_PL_DELAY)

        elif path.isfile(asset['uri']) or not url_fails(asset['uri']):
            name, mime, uri = asset['name'], asset['mimetype'], asset['uri']
            logging.info('Asset %s %s (%s)', name, uri, mime)            
            watchdog()


            duration = int(asset['duration'])
            if 'image' in mime:                
                view_image(uri, duration)
            elif 'webpage' == mime:
                # FIXME If we want to force periodic reloads of repeated web assets, force=True could be used here.
                # See e38e6fef3a70906e7f8739294ffd523af6ce66be.
                view_url(uri, asset)
            elif 'video' in mime:
                view_video(uri, duration)

            elif uri.startswith('/'): # local file
                if 'dir' == mime:                    
                    view_directory(uri, duration)
                else:
                    pass
               
            else:
                logging.error('Unknown MimeType %s', mime)
                sleep(0.5)

        else:
            logging.info('Asset %s at %s is not available, skipping.', asset['name'], asset['uri'])
            sleep(0.5)


def check_update():
    """
    Check if there is a later version of Screenly OSE
    available. Only do this update once per day.
    Return True if up to date was written to disk,
    False if no update needed and None if unable to check.
    """

    sha_file = path.join(settings.get_configdir(), 'latest_screenly_sha')

    if path.isfile(sha_file):
        sha_file_mtime = path.getmtime(sha_file)
        last_update = datetime.fromtimestamp(sha_file_mtime)
    else:
        last_update = None

    logging.debug('Last update: %s' % str(last_update))

    git_branch = sh.git('rev-parse', '--abbrev-ref', 'HEAD')
    if last_update is None or last_update < (datetime.now() - timedelta(days=1)):

        if not url_fails('http://stats.screenlyapp.com'):
            latest_sha = req_get('http://stats.screenlyapp.com/latest/{}'.format(git_branch))

            if latest_sha.status_code == 200:
                with open(sha_file, 'w') as f:
                    f.write(latest_sha.content.strip())
                return True
            else:
                logging.debug('Received non 200-status')
                return
        else:
            logging.debug('Unable to retrieve latest SHA')
            return
    else:
        return False


def load_settings():
    """Load settings and set the log level."""
    settings.load()
    logging.getLogger().setLevel(logging.DEBUG if settings['debug_logging'] else logging.INFO)


def setup():
    global HOME, arch, db_conn
    HOME = getenv('HOME', '/home/pi')
    arch = machine()

    signal(SIGUSR1, sigusr1)
    signal(SIGUSR2, sigusr2)

    load_settings()
    db_conn = db.conn(settings['database'])

    sh.mkdir(SCREENLY_HTML, p=True)
    html_templates.black_page(BLACK_PAGE)


def main():
    setup()

    url = 'http://{0}:{1}/splash_page'.format(settings.get_listen_ip(), settings.get_listen_port()) if settings['show_splash'] else 'file://' + BLACK_PAGE
    load_browser(url=url)

    if settings['show_splash']:
        sleep(SPLASH_DELAY)

    scheduler = Scheduler()    
    
    process_playlist(scheduler)


if __name__ == "__main__":
    try:
        main()
    except:
        logging.exception("Viewer crashed.")
        raise
