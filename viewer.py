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
import threading

from settings import settings
import html_templates
from lib.utils import url_fails, get_mimetype, get_video_duration
from lib.models import *



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
home = None


WEBPAGE_TIMEOUT = 30 # secs
IMAGE_TIMEOUT = 30 # secs

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


def load_browser(url):
    global browser, current_browser_url, home
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
    with open(home + UZBLRC) as f:  # load uzbl.rc
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

def view_url(url, cb=lambda _: True, force=False):
    global current_browser_url
    logging.info("view_url: %s" % url)

    if url == current_browser_url and not force:
        logging.info('Already showing %s, not doing anything.', current_browser_url)
    else:
        current_browser_url = url
        browser_send('uri ' + current_browser_url, cb=cb)


def view_image(url, cb=lambda _: True, force=False):    
    global current_browser_url    
    logging.info("view_image: %s" % url)

    url = urllib.quote(url)    

    if url == current_browser_url and not force:
        logging.info('Already showing %s, not doing anything.', current_browser_url)
    else:
        current_browser_url = url
        browser_send('js window.setimg("{0}")'.format(url), cb=lambda b: 'COMMAND_EXECUTED' in b and 'setimg' in b)

    

def view_video(uri):
    logging.info('view_video (%s)', uri)
    arch = machine()

    if arch in ('armv6l', 'armv7l'):
        player_args = ['omxplayer', uri]
        player_kwargs = {'o': settings['audio_output'], '_bg': True, '_ok_code': [0, 124]}
        player_kwargs['_ok_code'] = [0, 124]
    else:
        player_args = ['mplayer', uri, '-nosound']
        player_kwargs = {'_bg': True}


    run = sh.Command(player_args[0])(*player_args[1:], **player_kwargs)

    browser_clear()
    while run.process.alive:        
        sleep(1)
    if run.exit_code == 124:
        logging.error('omxplayer timed out')


class ViewThread(threading.Thread):
    def __init__(self, entry):
        super(ViewThread, self).__init__()
        self.entry = entry
        self.loopTime = 1
        self.__stop = threading.Event()


    def stop(self):
        self.__stop.set()
        self.join()

    def run(self):
        directory = self.entry.directory
        files = [path.join(directory, f) for f in os.listdir(directory) if path.isfile(path.join(directory, f))]

        num_files = len(files)
        
        if num_files == 0:
            load_browser(url='http://{0}:{1}/splash_page'.format(settings.get_listen_ip(), settings.get_listen_port()) if settings['show_splash'] else 'file://' + BLACK_PAGE)
            while not self.__stop.isSet(): 
                sleep(self.loopTime)            
        else:
            num = 0
            currentEntryDuration = 0
            mime = None
            file = None
            isNew = True
            while not self.__stop.isSet():            
                logging.info("worker still waiting %d seconds for %s" % (currentEntryDuration, file))
                if currentEntryDuration <= 0: 
                    sh.killall('omxplayer.bin', _ok_code=[1])

                    file = files[num]                
                    mime = get_mimetype(file)
                    num = (num+1) % num_files
                    if mime is not None:
                        if 'image' in mime:
                            currentEntryDuration = IMAGE_TIMEOUT
                            view_image(file, force=isNew)
                            isNew = False
                        elif 'text' in mime: 
                            currentEntryDuration = WEBPAGE_TIMEOUT
                            with open(file, 'r') as urlfile:
                                try:
                                    view_url(urlfile.readlines()[0].replace('\n', ''),force=isNew)                                                        
                                except Exception as e:
                                    logging.error('cannot show text file: %s, error: %s' % (file, e))  
                            isNew = False
                        elif 'video' in mime:
                            currentEntryDuration = get_video_duration(file)
                            view_video(file)                            
                        else:
                            # cannot show this entry, so skip
                            logging.info('mimetype (%s) of file (%s) not supported.' % (mime, file))
                            mime = None
                            currentEntryDuration = 0
                    else:
                        logging.info('cannot show suspect file: %s' % file)    
                    

                sleep(self.loopTime)
                currentEntryDuration -= self.loopTime     

class Viewer(object):

    def __init__(self):
        global home
        home = getenv('HOME', '/home/pi')
        self.currentId = None
        self.currentDirectory = None
        self.worker = None

        signal(SIGUSR1, sigusr1)
        signal(SIGUSR2, sigusr2)

        settings.load()
        logging.getLogger().setLevel(logging.DEBUG if settings['debug_logging'] else logging.INFO)        

        try:
            sh.mkdir(SCREENLY_HTML)
        except:
            pass
        html_templates.black_page(BLACK_PAGE)

        load_browser(url='http://{0}:{1}/splash_page'.format(settings.get_listen_ip(), settings.get_listen_port()) if settings['show_splash'] else 'file://' + BLACK_PAGE)

    def play(self, entry):
        self.stop()
        self.currentId = entry.id
        self.currentDirectory = entry.directory             
            
        self.worker = ViewThread(entry)
        self.worker.setDaemon(True)
        self.worker.start()

    def stop(self):
        if self.worker is not None:
            self.worker.stop()

    def run(self):
        while True:
            schedules = list(Schedule.select(Schedule.q.active==True, orderBy='id'))
            if len(schedules) > 0: # there is an active schedule                
                schedule = schedules[0]
                dt = datetime.time(datetime.now())
                time = dt.hour * 60 * 60 + dt.minute * 60 + dt.second        
                
                for entry in schedule.entries:                     
                    logging.info('checking activity of: %s, time: %d' % (entry, time))
                    
                    if entry.start <= time and entry.end >= time and (self.currentId is None or self.currentId != entry.id or self.currentDirectory != entry.directory):
                        logging.info('show directory: %s' % entry)
                        self.play(entry)
                        break
                    else:
                        # if an entry is currently running there is nothing
                        # to do
                        pass
            else: # there is no active schedule
                self.stop()
            # sleep 10 seconds then run again
            sleep(10)   


if __name__ == "__main__":
    try:
        viewer = Viewer()
        viewer.run()
    except:
        logging.exception("Viewer crashed.")
        raise
