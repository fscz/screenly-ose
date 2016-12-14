from sqlobject import *
from settings import settings
sqlhub.processConnection = connectionForURI('sqlite://%s' % settings['database'])

from os import listdir
from os.path import join, isfile

from lib.utils import get_mimetype

def _is_supported_(file):    
    mime = get_mimetype(file)
    return mime is not None and ('image' in mime or 'video' in mime or 'text' in mime)

class Schedule(SQLObject):
    class sqlmeta:
        cacheValues = False
    name = StringCol()
    active = BoolCol(default=False, notNull=True)
    entries = MultipleJoin('Entry')

class Entry(SQLObject):
    class sqlmeta:
        cacheValues = False
    name = StringCol()
    directory = StringCol()
    start = IntCol()
    end = IntCol()
    schedule = ForeignKey('Schedule')  

    def _get_files(self):
        return filter(_is_supported_, 
                [join(self.directory, f) for f in listdir(self.directory) if isfile(join(self.directory, f))])            
                

tables = [Schedule, Entry]
for table in tables:
    try:
        table.createTable()
    except:
        pass