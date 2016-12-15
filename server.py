#!/usr/bin/env python
# -*- coding: utf8 -*-

__author__ = "WireLoad Inc"
__copyright__ = "Copyright 2012-2016, WireLoad Inc"
__license__ = "Dual License: GPLv2 and Commercial License"

from datetime import datetime, timedelta
from functools import wraps
from hurry.filesize import size
from os import path, makedirs, statvfs, mkdir, getenv, listdir
from sh import git
import sh
from subprocess import check_output
import json
import os
import stat
import traceback
import uuid

from bottle import route, run, request, error, static_file, response
from bottle import HTTPResponse
from bottlehaml import haml_template

from lib import diagnostics
from lib.models import *

from lib.utils import json_dump
from lib.utils import get_node_ip
from lib.utils import validate_url
from lib.utils import url_fails
from lib.utils import get_video_duration
from lib.utils import get_mimetype
from dateutil import parser as date_parser

from settings import settings, DEFAULTS, CONFIGURABLE_SETTINGS
from werkzeug.wrappers import Request

import json

################################
# Utilities
################################


def make_json_response(obj):
    response.content_type = "application/json"    
    return json_dump(obj)


def api_error(error):
    response.content_type = "application/json"
    response.status = 500
    return json_dump({'error': error})


def is_up_to_date():
    """
    Determine if there is any update available.
    Used in conjunction with check_update() in viewer.py.
    """

    sha_file = os.path.join(settings.get_configdir(), 'latest_screenly_sha')

    # Until this has been created by viewer.py,
    # let's just assume we're up to date.
    if not os.path.exists(sha_file):
        return True

    try:
        with open(sha_file, 'r') as f:
            latest_sha = f.read().strip()
    except:
        latest_sha = None

    if latest_sha:
        branch_sha = git('rev-parse', 'HEAD')
        return branch_sha.stdout.strip() == latest_sha

    # If we weren't able to verify with remote side,
    # we'll set up_to_date to true in order to hide
    # the 'update available' message
    else:
        return True


def template(template_name, **context):
    """Screenly template response generator. Shares the
    same function signature as Bottle's template() method
    but also injects some global context."""
    context['template_settings'] = {
        'imports': ['from lib.utils import template_handle_unicode'],
        'default_filters': ['template_handle_unicode'],
    }

    return haml_template(template_name, **context)


################################
# Model
################################


################################
# Views
################################


@route('/')
def viewIndex():
    return template('index')


@route('/settings', method=["GET", "POST"])
def settings_page():

    context = {'flash': None}

    if request.method == "POST":
        for field, default in CONFIGURABLE_SETTINGS.items():
            value = request.POST.get(field, default)
            if isinstance(default, bool):
                value = value == 'on'
            settings[field] = value
        try:
            settings.save()
            sh.sudo('systemctl', 'kill', '--signal=SIGUSR2', 'screenly-viewer.service')
            context['flash'] = {'class': "success", 'message': "Settings were successfully saved."}
        except IOError as e:
            context['flash'] = {'class': "error", 'message': e}
        except sh.ErrorReturnCode_1 as e:
            context['flash'] = {'class': "error", 'message': e}
    else:
        settings.load()
    for field, default in DEFAULTS['viewer'].items():
        context[field] = settings[field]

    return template('settings', **context)


@route('/system_info')
def system_info():
    viewlog = None
    try:
        viewlog = check_output(['sudo', 'systemctl', 'status', 'screenly-viewer.service', '-n', '20']).split('\n')
    except:
        pass

    loadavg = diagnostics.get_load_avg()['15 min']

    display_info = diagnostics.get_monitor_status()

    # Calculate disk space
    slash = statvfs("/")
    free_space = size(slash.f_bavail * slash.f_frsize)

    # Get uptime
    uptime_in_seconds = diagnostics.get_uptime()
    system_uptime = timedelta(seconds=uptime_in_seconds)

    return template(
        'system_info',
        viewlog=viewlog,
        loadavg=loadavg,
        free_space=free_space,
        uptime=system_uptime,
        display_info=display_info
    )


@route('/splash_page')
def splash_page():
    my_ip = get_node_ip()
    if my_ip:
        ip_lookup = True

        # If we bind on 127.0.0.1, `enable_ssl.sh` has most likely been
        # executed and we should access over SSL.
        if settings.get_listen_ip() == '127.0.0.1':
            url = 'https://{}'.format(my_ip)
        else:
            url = "http://{}:{}".format(my_ip, settings.get_listen_port())
    else:
        ip_lookup = False
        url = "Unable to look up your installation's IP address."

    return template('splash_page', ip_lookup=ip_lookup, url=url)


@error(403)
def mistake403(code):
    return 'The parameter you passed has the wrong format!'


@error(404)
def mistake404(code):
    return 'Sorry, this page does not exist!'


################################
# API
################################
def load_model(request):
    return json.loads(Request(request.environ).form['model'].strip().decode('utf-8'))        

def get_file_info(file, path):
    full_path = os.path.join(path, file)
    stat_info = os.stat(full_path)

    acc = dict()
    acc['name'] = file
    acc['path'] = full_path
    acc['creation'] = stat_info.st_ctime
    acc['modification'] = stat_info.st_mtime
    acc['access'] = stat_info.st_atime
    acc['size'] = stat_info.st_size

    if stat.S_ISDIR(stat_info.st_mode):
        acc['mime'] = 'dir'
    elif stat.S_ISREG(stat_info.st_mode):
        mime = get_mimetype(full_path)
        if mime is not None:
            acc['mime'] = mime

    return acc

def file_info_cmp(info1, info2):
    if info1['mime'] == info2['mime']:    
        if info1['name'] < info2['name']:
           return -1
        else:
            return 1 
    elif info1['mime'] == 'dir' and not info2['mime'] == 'dir':
        return -1
    else:
        return 1 

# api view decorator. handles errors
def api(view):
    @wraps(view)
    def api_view(*args, **kwargs):
        try:
            return make_json_response(view(*args, **kwargs))
        except HTTPResponse:
            raise
        except Exception as e:
            traceback.print_exc()
            return api_error(unicode(e))
    return api_view

@route('/api/directory', method="GET")
def api_filesystem():
    try:
        path = request.query['path']
        contents = [{
            'name': '..'
            , 'path': os.path.abspath(os.path.join(path, '..'))
            , 'mime': 'dir'
            , 'creation': 0
            , 'modification': 0
            , 'access': 0
            , 'size': 0
        }] + sorted(
                filter(
                    lambda info: 'mime' in info and not info['name'].startswith('.'), 
                        [get_file_info(f, path) for f in listdir(path)]), cmp=file_info_cmp)        
        
        return json.dumps(contents)
    except Exception as e:
        traceback.print_exc()
        return api_error(unicode(e))  


@route('/api/schedules', method="GET")
@api
def get_schedules():
    return list(Schedule.select())

@route('/api/schedules/:schedule_id', method="GET")
@api
def get_schedule(schedule_id):
    try:        
        schedule = Schedule.get(schedule_id)
        return schedule
    except Exception as e:
        traceback.print_exc()
        return api_error(unicode(e)) 

@route('/api/schedules', method="POST")
@api
def add_schedule():
    model = load_model(request)
    return Schedule(name=model['name'])    

@route('/api/schedules/:schedule_id', method="PUT")
@api
def edit_schedule(schedule_id):
    try:        
        schedule = Schedule.get(schedule_id)        
        model = load_model(request)
        schedule.set(name=model['name'], active=model['active'])
        return schedule
    except Exception as e:
        traceback.print_exc()
        return api_error(unicode(e)) 

@route('/api/schedules/:schedule_id', method="DELETE")
@api
def delete_schedule(schedule_id):   
    try: 
        Schedule.delete(schedule_id)
        return dict()
    except Exception as e:
        traceback.print_exc()
        return api_error(unicode(e)) 

@route('/api/schedules/:schedule_id/entries', method="GET")
@api
def get_entries(schedule_id):
    try:
        return list(Entry.select(Entry.q.schedule==schedule_id, orderBy='start'))
    except Exception as e:
        traceback.print_exc()
        return api_error(unicode(e)) 

@route('/api/schedules/:schedule_id/entries/:entry_id', method="GET")
@api
def get_entries(schedule_id, entry_id):
    try:
        entry = Entry.get(entry_id)
        if entry.schedule_id == schedule_id:
            return entry
        else:
            raise Exception("Entry "+entry_id+" does not belong to schedule "+schedule_id)

    except Exception as e:
        traceback.print_exc()
        return api_error(unicode(e)) 

@route('/api/schedules/:schedule_id/entries', method="POST")
@api
def create_entry(schedule_id):
    try: 
        schedule = Schedule.get(schedule_id)
        model = load_model(request)    
        return Entry(name=model['name'], 
            directory=model['directory'], 
            start=model['start'], 
            end=model['end'], 
            schedule=schedule)

    except Exception as e:
        traceback.print_exc()
        return api_error(unicode(e)) 

@route('/api/schedules/:schedule_id/entries/:entry_id', method="PUT")
@api
def edit_entry(schedule_id, entry_id):        
    try: 
        schedule = Schedule.get(schedule_id)
        model = load_model(request)
        entry = Entry.get(entry_id)
        if entry.schedule.id == schedule.id:
            entry.set(name=model['name'], 
                    directory=model['directory'], 
                    start=model['start'], 
                    end=model['end'], 
                    schedule=schedule)
            return entry
        else:
            raise Exception("Entry "+entry_id+" does not belong to schedule "+schedule_id)
    except Exception as e:
        traceback.print_exc()
        return api_error(unicode(e)) 

@route('/api/schedules/:schedule_id/entries/:entry_id', method="DELETE")
@api
def delete_entry(schedule_id, entry_id):
    try:
        schedule = Schedule.get(schedule_id)
        entry = Entry.get(entry_id)
        if entry.schedule.id == schedule.id:
            entry.destroySelf()
            return {}
        else:
            raise Exception("Entry "+entry_id+" does not belong to schedule "+schedule_id)
    except Exception as e:
        traceback.print_exc()
        return api_error(unicode(e)) 


################################
# Static
################################

@route('/static/:path#.+#', name='static')
def static(path):
    return static_file(path, root='static')


if __name__ == "__main__":  
    '''
    schedules = list(Schedule.select(Schedule.q.name=="first_schedule"))
    entries = list(Entry.select(Entry.q.schedule==schedules[0]))
    entries[0].set(start=0, end=2 * 60 * 60)    
    entries[1].set(start=2 * 60 * 60, end=4 * 60 * 60)
    '''

    '''
    schedule1 = Schedule(name="first_schedule")
    Entry(name="en1", directory="/home/romy1", start=0, end=2, schedule=schedule1)
    Entry(name="en2", directory="/home/romy2", start=2, end=5, schedule=schedule1)

    schedule2 = Schedule(name="second_schedule")
    Entry(name="en3", directory="/home/romy3", start=0, end=2, schedule=schedule2)
    Entry(name="en4", directory="/home/romy4", start=2, end=5, schedule=schedule2)
    '''
    # Make sure the asset folder exist. If not, create it
    if not path.isdir(settings['assetdir']):
        mkdir(settings['assetdir'])
    # Create config dir if it doesn't exist
    if not path.isdir(settings.get_configdir()):
        makedirs(settings.get_configdir())


    run(
        host=settings.get_listen_ip(),
        port=settings.get_listen_port(),
        server='gunicorn',
        threads=2,
        timeout=20,
    )
