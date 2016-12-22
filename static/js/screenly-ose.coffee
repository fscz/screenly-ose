### screenly-ose ui ###

$().ready ->
  popover_shown = off

  hide_popover = ->
    $('#subsribe-form-container').html('')
    popover_shown = off
    $(window).off('keyup.email_popover')
    $(window).off('click.email_popover')

  show_popover = ->
    $('#subsribe-form-container').html($('#subscribe-form-template').html())
    popover_shown = on

    $(window).on 'keyup.email_popover', (event) ->
      if event.keyCode == 27
        hide_popover()

    $(window).on 'click.email_popover', (event) ->
      pop = document.getElementById('subscribe-popover')
      if !$.contains(pop, event.target)
        hide_popover()

  $('#show-email-popover').click ->
    if !popover_shown then show_popover()
    off

API = (window.Screenly ||= {}) # exports



get_template = (name) -> _.template ($ "##{name}").html()
delay = (wait, fn) -> _.delay fn, wait

supported_upload_mimetypes = [ [('jpg jpeg png pnm gif bmp'.split ' '), 'image']
              [('avi mkv mov mpg mpeg mp4 ts flv'.split ' '), 'video']]

supported_video_uri_schemes   = ('rtsp rtmp'.split ' ')


get_mimetype = (filename) =>
  scheme = (_.first filename.split ':').toLowerCase()

  match = scheme in supported_video_uri_schemes
  if match then return 'video'
  ext = (_.last filename.split '.').toLowerCase()
  mt = _.find supported_upload_mimetypes, (mt) -> ext in mt[0]
  if mt then mt[1] else null
  

url_test = (v) -> /(http|https|rtsp|rtmp):\/\/[\w-]+(\.?[\w-]+)+([\w.,@?^=%&amp;:\/~+#-]*[\w@?^=%&amp;\/~+#-])?/.test v
get_filename = (v) -> (v.replace /[\/\\\s]+$/g, '').replace /^.*[\\\/]/g, ''
insertWbr = (v) -> (v.replace /\//g, '/<wbr>').replace /\&/g, '&amp;<wbr>'

# Tell Backbone to send its saves as JSON-encoded.
Backbone.emulateJSON = on


# Models
API.Entry = class Entry extends Backbone.Model
  idAttribute: "id"
  fields: 'name directory start end'.split ' '
  defaults: =>
    name: ''
    directory: ''
    mimetype: ''
    start: 0
    end: 0

API.Entries = class Entries extends Backbone.Collection  
  model: Entry
  comparator: (item) ->
    return parseInt(item.get('start'))
  url: () -> "/api/schedules/"+@schedule_id+"/entries"

API.Schedule = class Schedule extends Backbone.Model
  idAttribute: "id"
  fields: 'name active'.split ' '
  defaults: =>
    name: ''
    active: false

API.Schedules = class Schedules extends Backbone.Collection  
  model: Schedule  
  url: "/api/schedules"

API.Directory = class Directory extends Backbone.Collection
  url: '/api/directory'

# Views
API.View = {};
class DisposableView extends Backbone.View 
  close: () =>
    @unbind()
    @$el.empty()
    @undelegateEvents()

API.View.TimeView = class TimeView extends DisposableView
  events: 
    'click .spinner .btn:first-of-type': 'up'
    'click .spinner .btn:last-of-type': 'down'
    'change #hours': 'changeTime'
    'change #minutes': 'changeTime'
    'change #seconds': 'changeTime'

  initialize: (attrs, options) =>
    that = @
    @type = options.type
    @index = options.index
    @template = $ "<span class='input-group-addon'>
                    #{options.name}
                  </span>
                  <div class='form-inline'>
                    <div class='input-group spinner'>
                      <input id='hours' type='text' class='form-control' value='0' min='0' max='23'>
                      <div class='input-group-btn-vertical'>
                        <button class='btn btn-default' type='button'><i class='fa fa-caret-up'></i></button>
                        <button class='btn btn-default' type='button'><i class='fa fa-caret-down'></i></button>
                      </div>
                    </div>
                    <div class='input-group'>
                      :
                    </div>
                    <div class='input-group spinner'>
                      <input id='minutes' type='text' class='form-control' value='0' min='0' max='59'>
                      <div class='input-group-btn-vertical'>
                        <button class='btn btn-default' type='button'><i class='fa fa-caret-up'></i></button>
                        <button class='btn btn-default' type='button'><i class='fa fa-caret-down'></i></button>
                      </div>
                    </div>
                    <div class='input-group'>
                      :
                    </div>
                    <div class='input-group spinner'>
                      <input id='seconds' type='text' class='form-control' value='0' min='0' max='59'>
                      <div class='input-group-btn-vertical'>
                        <button class='btn btn-default' type='button'><i class='fa fa-caret-up'></i></button>
                        <button class='btn btn-default' type='button'><i class='fa fa-caret-down'></i></button>
                      </div>
                    </div>
                  </div>"
    @hours = @template.find('#hours')
    @minutes = @template.find('#minutes')
    @seconds = @template.find('#seconds')    

    @$el.html @template

    @field = @$el.find('.form-control')

    @model.bind 'change', @render

    @render()

  changeTime: (e) =>
    input = $(e.currentTarget)
    max = input.attr('max')      
    min = input.attr('min')      
    try
      val = parseInt(input.val())      
      if val <= max and val >= min
        [h,m,s] = [parseInt(@hours.val()), parseInt(@minutes.val()), parseInt(@seconds.val())]
        
        newTime = h * 3600 + m * 60 + s

        if @type == 'start'
          last = @model.collection.models[@index - 1] if @index - 1 >= 0

          if last and @model.attributes.end > newTime
            last.set('end', newTime)
            last.save()
            @model.set('start', newTime)
            @model.save()          

        else # @type == 'end'
          next = @model.collection.models[@index + 1] if @index + 1 < @model.collection.models.length

          if next and next.attributes.end > newTime      
            next.set('start', newTime)
            next.save()
            @model.set('end', newTime)
            @model.save() 

      else 
        throw 'value not allowed' 

    catch error
      @render()

  up: (e) =>    
    btn = $(e.currentTarget)        
    input = btn.closest('.spinner').find('input')    
    max = input.attr('max')      
    val = parseInt(input.val())
    [h,m,s] = [parseInt(@hours.val()), parseInt(@minutes.val()), parseInt(@seconds.val())]

    newTime = null  

    if val < max 
      if input.attr('id') == 'hours'
        newTime = (h + 1) * 3600 + m * 60 + s
      else if input.attr('id') == 'minutes'
        newTime = h * 3600 + (m + 1) * 60 + s
      else # seconds
        newTime = h * 3600 + m * 60 + s + 1


      if @type == 'start'
        last = @model.collection.models[@index - 1] if @index - 1 >= 0

        if last and @model.attributes.end > newTime
          last.set('end', newTime)
          last.save()
          @model.set('start', newTime)
          @model.save()          

      else # @type == 'end'
        next = @model.collection.models[@index + 1] if @index + 1 < @model.collection.models.length

        if next and next.attributes.end > newTime      
          next.set('start', newTime)
          next.save()
          @model.set('end', newTime)
          @model.save()        



  down: (e) =>    
    btn = $(e.currentTarget)        
    input = btn.closest('.spinner').find('input')    
    min = input.attr('min')      
    val = parseInt(input.val())
    [h,m,s] = [parseInt(@hours.val()), parseInt(@minutes.val()), parseInt(@seconds.val())]

    newTime = null  

    if val > min
      if input.attr('id') == 'hours'
        newTime = (h - 1) * 3600 + m * 60 + s
      else if input.attr('id') == 'minutes'
        newTime = h * 3600 + (m - 1) * 60 + s
      else # seconds
        newTime = h * 3600 + m * 60 + s - 1


      if @type == 'start'
        last = @model.collection.models[@index - 1] if @index - 1 >= 0

        if last and @model.attributes.end > newTime
          last.set('end', newTime)
          last.save()
          @model.set('start', newTime)
          @model.save()  

      else # @type == 'end'
        next = @model.collection.models[@index + 1] if @index + 1 < @model.collection.models.length

        if next and next.attributes.end > newTime      
          next.set('start', newTime)
          next.save()
          @model.set('end', newTime)
          @model.save() 

  get_time: (time) =>
    hours = time // 3600
    minutes = (time - hours * 3600) // 60
    seconds = (time - hours * 3600 - minutes * 60).toFixed 0
    [hours, minutes, seconds]

  render: =>
    [hours, minutes, seconds] = @get_time(@model.attributes[@type])
    @hours.val hours
    @minutes.val minutes
    @seconds.val seconds


API.View.DirectoryView = class DirectoryView extends DisposableView
  events:
    'click #directory-list > li.dir': 'clickFolder'
  initialize: (attrs, options) =>    
    @template = $ '<span class="input-group-addon">
                    Directory
                  </span>
                  <div class="form-control" style="height: 300px">
                    <div id="directory"/>
                    <ul id="directory-list"/>
                  </div>'
    @$el.html @template

    @list = @$el.find('#directory-list')
    @directory = @$el.find('#directory')
    
    @collection.bind 'sync', @render    

    @fetch(@model.attributes.directory or '/')

  fetch: (path) =>    
    @path = path
    that = @
    retryOnce = true

    @collection.fetch 
      data: 
        path: @path
      success: (collection, response, options) ->
        that.model.attributes.directory = that.path
        that.model.save()

      error: (collection, response, options) ->
        if retryOnce
          retryOnce = false
          that.fetch('/')

  clickFolder: (e) =>
    data_stat = $(e.target).data('stat')
    if data_stat 
      stat = JSON.parse(data_stat)
      
      @fetch(stat['path'])

  render: =>
    @list.empty()
    @directory.text(@path)

    for model in @collection.models      
      cls = if model.attributes.mime == 'dir' then 'dir' else 'file'
      $li = $ "<li class='#{cls}'><img class='#{cls}'/>#{model.attributes.name}</li>"
      $li.data 'stat', JSON.stringify(model.attributes)
      @list.append $li
    no

API.View.EntryView = class EntryView extends DisposableView
  events: 
    'change input#name': 'updateName'
    'click #delete-button': 'deleteEntry'

  initialize: (attrs, options) =>
    that = @
    @intervall = options.intervall
    @index = options.index
    @deletable = @model.collection.length > 1


    @$el.empty()

    @template = $ "
        <div class='panel panel-success'>
          <div class='panel-heading clearfix'>
            <div class='panel-title pull-left'>
              Entry
            </div>
            <div class='pull-right'>
              <button id='delete-button' type='button' class='btn btn-danger' #{if @deletable then '' else 'disabled'}>
                Delete
              </button>
            </div>
          </div>
          <div class='input-group'>
            <span class='input-group-addon'>
              Name
            </span>
            <input id='name' class='form-control' type='text' placeholder='name' value='#{@model.attributes.name}'/>
          </div>
          <div class='input-group' id='directory-container'>            
          </div>
          <div class='input-group' id='start-container'>            
          </div>
          <div class='input-group' id='end-container'>            
          </div>
        </div>
    "

    @directory = new DirectoryView
      collection: new Directory {}
      model: @model
      el: @template.find('#directory-container') 

    @start = new TimeView {
      el: @template.find('#start-container')
      model: @model
      },
      {
        name: 'Start'
        type: 'start'
        index: @index
      }


    @end = new TimeView {
      el: @template.find('#end-container')
      model: @model
      },
      {
        name: 'End'
        type: 'end'
        index: @index
      }

    @$el.html @template
    no

  updateName: (e) =>
    @model.attributes.name = $(e.target).val()
    @model.save()

  deleteEntry: (e) =>
    if @index - 1 >= 0
      last = @model.collection.models[@index - 1]
      last.attributes.end = @model.attributes.end
      last.save()
    else if @index + 1 <= @model.collection.length - 1
      next = @model.collection.models[@index + 1]
      next.attributes.start = @model.attributes.start
      next.save()

    @intervall.remove()
    @model.destroy()
    API.controller.unshowEntry()

  close: () =>
    @start.close()
    @end.close()
    @directory.close()
    super()

API.View.Timeline = class TimelineView extends DisposableView 
  
  events:
    'click .timeline-intervall': 'showEntryView'

  get_end: ($intervall) =>
    ($intervall.width() + $intervall.offset().left - @$el.offset().left) * @max_seconds / @$el.width()

  get_start: ($intervall) =>
    get_end($intervall) - ($intervall.width() * @max_seconds / @$el.width())

  duration: ($intervall) =>
    @get_end($intervall) - @get_start($intervall)

  get_time: (e) =>
    relX = e.pageX - @$el.offset().left
    time = (relX / @$el.width()) * @max_seconds      
    hours = time // 3600
    minutes = (time - hours * 3600) // 60
    seconds = (time - hours * 3600 - minutes * 60).toFixed 0
    [hours, minutes, seconds]


  initialize: (attrs, options) =>
    @max_seconds = (24*60*60) - 1
    @width = @$el.parent().width()
    @intervalls = []
    that = @
    $(window).on('resize', @updateIntervallWidths)

    tooltip = @$el.find('#timeline-tooltip')

    @$el.mousemove (e) -> 
      relX = e.pageX - that.$el.offset().left
      [hours,minutes,seconds] = that.get_time(e)
      
      tooltip.attr 'title',  hours+':'+minutes+':'+seconds
      tooltip.css 
        top: (e.pageY - $(e.target).offset().top) - 5
        left: relX
      tooltip.tooltip 'fixTitle'
      tooltip.tooltip 'show'

    @$el.mouseleave (e) ->
      tooltip.tooltip 'hide'
    

    @$el.contextMenu
      menu: [
        {
          name: 'Insert keyframe'
          callback: (e) -> 
            relX = e.data.pageX - that.$el.offset().left
            time = (relX / that.$el.width()) * that.max_seconds
            that.insert(time)            
        }
      ],
      data: that

    @collection.bind('change', @render)
    
    @render()  

  updateIntervallWidths: (e) =>
    @render()

  showEntryView: (e) =>
    $intervall = $(e.currentTarget)
    @$el.find('.timeline-intervall').removeClass('active')
    $intervall.addClass('active')

    index = parseInt($intervall.data('index'))
    model = @collection.models[index]
    API.controller.showEntry model, 
      intervall: $intervall
      index: index

  get_intervall_at: (time) =>
    for entry in @collection.models
      if entry.attributes.start < time and entry.attributes.end > time
        return entry

  insert: (time) =>
    intervall = @get_intervall_at(time)

    if intervall
      startTime = intervall.attributes.start
      intervall.attributes.start = time      
      intervall.save()
      
      @collection.create 
        directory: '/'
        start: startTime
        end: time
     
      @render()      
    no

  renderIntervall: (entry, index) =>
    that = @

    $intervall = $ "<div class='timeline-intervall' data-index='#{index}'><div class='timeline-keyframe'/></div>"
      
    $intervall.css 
      width: (((entry.attributes.end - entry.attributes.start) / @max_seconds) * @$el.width()) + 'px'
      
    @$el.append($intervall)


    $keyframe = $intervall.find('.timeline-keyframe')

    # do not allow movement of last keyframe
    if index < @collection.models.length - 1
      $keyframe.mousedown (e) ->
        that.isDragging = true 
        that.dragIntervall = $intervall
        that.startX = e.pageX
        that.startWidth = $intervall.width()          
        that.next = $(".timeline-intervall[data-index='#{index+1}']")
        that.nextStartWidth = that.next.width()              
    else
      $keyframe.toggleClass('timeline-keyframe')
    

  render: =>
    @$el.find('.timeline-intervall').remove() 

    @isDragging = false
    @dragIntervall
    @startWidth = null
    @startX = null
    @next = null
    @nextStartWidth = null   

    that = @

    @$el.mousemove (e) ->
      if that.isDragging
        delta = e.pageX - that.startX
        if that.startWidth + delta > 2 and delta < that.nextStartWidth - 2
          that.dragIntervall.width(that.startWidth + delta)
          that.next.width(that.nextStartWidth - delta)        
    
    @$el.mouseup (e) ->
      if that.isDragging
        end = that.get_end(that.dragIntervall)
        index = parseInt(that.dragIntervall.data('index'))
        model = that.collection.models[index]
        model.attributes.end = end
        model.save()

        nextIndex = parseInt(that.next.data('index'))
        nextModel = that.collection.models[nextIndex]
        nextModel.attributes.start = end
        nextModel.save()

        that.isDragging = false
    
    @$el.mouseleave (e) ->
      if that.isDragging
        that.dragIntervall.width(that.startWidth)
      @isDragging = false
      
    

    for entry, index in @collection.models
      @renderIntervall entry, index

  close: =>
    $(window).off('resize', @updateIntervallWidths)
    super()


API.View.ScheduleView = class ScheduleView extends DisposableView
  events: 
    'change input.form-control[placeholder="name"]': 'changeName'
    'click #enableSchedule': 'enableSchedule'
    'click #deleteSchedule': 'deleteSchedule'
  initialize: (attrs, options) =>
    that = @
    @template = $ "
        <div class='panel panel-success'>
          <div class='panel-heading clearfix'>
            <div class='panel-title pull-left'>
              Schedule
            </div>
            <div class='pull-right'>
                <button id='enableSchedule' type='button' class='btn btn-success' style='display: inline-block'>Enable</button>                
                <button id='deleteSchedule' type='button' class='btn btn-danger' style='display: inline-block'>Remove</button>              
            </div>
          </div>
          <div class='input-group'>
            <span class='input-group-addon'>
              Name
            </span>
            <input class='form-control' type='text' placeholder='name' value='#{@model.attributes.name}'/>
          </div>
          <div id='timeline'>
            <i id='timeline-tooltip' data-toggle='tooltip' data-placement='top' data-animation='false' data-trigger='manual'/>
          </div>
        </div>
    "

    @$el.html @template    
    if @model.attributes.active
      $button = @template.find('#enableSchedule')
      $button.removeClass 'btn-success'      
      $button.addClass 'btn-danger'      
      $button.text 'Disable'

    @model.attributes.entries.bind event, @reload for event in ('add remove'.split ' ')     

    @timeline = new TimelineView
      el: @template.find('#timeline')
      collection: that.model.attributes.entries

  reload: (e) =>
    API.controller.showSchedule(@model)

  deleteSchedule: (e) =>
    @model.attributes.entries.unbind event, @reload for event in ('add remove'.split ' ')     
    while entry = @model.attributes.entries.first()      
      entry.destroy()

    @model.destroy()

    API.controller.unshowSchedule()

  enableSchedule: (e) => 
    $button = $(e.currentTarget)
    if @model.attributes.active
      @model.attributes.active = false
      $button.removeClass 'btn-danger'
      $button.addClass 'btn-success'
      $button.text 'Enable'
    else
      @model.attributes.active = true
      $button.removeClass 'btn-success'
      $button.addClass 'btn-danger'
      $button.text 'Disable'

      # on enable disable other enabled
      for schedule in @model.collection.models
        if schedule.attributes.active and schedule.attributes.id != @model.attributes.id
          schedule.attributes.active = false
          schedule.save() 

    @model.save()

  changeName: (e) =>
    @model.attributes.name = $(e.target).val()
    @model.save()

  close: =>
    @timeline.close()
    super()


API.View.SchedulesView = class SchedulesView extends DisposableView
  events: 
    'click .list-group-item': 'clickScheduleLink' 
  initialize: (attrs, options) =>    
    @collection.bind event, @render for event in ('sync add remove reset'.split ' ')      

  clickScheduleLink: (e) =>
    index = $(e.currentTarget).data('schedule')
    entries = new API.Entries()

    schedule = @collection.models[index]
    entries.schedule_id = schedule.attributes.id

    entries.fetch
      success: (collection, response, options) ->
        schedule.set 
          entries: collection
        
        API.controller.showSchedule(schedule)

  render: =>
    @$el.empty()

    @collection.each (model, index) =>  
      $schedule = $("<a class='list-group-item' data-schedule='#{index}' href='#'> 
        <div class='schedule-row-title'>
          #{model.attributes.name}&nbsp;          
        </div>        
        <div>" + 
          (if model.attributes.active then "<span class='label label-success'>Enabled</span>" else "<span class='label label-danger'>Disabled</span>") + 
            "</div>
        </a>")
      @$el.append($schedule)


API.App = class App extends DisposableView
  events: 
    'click #schedule-add': 'add'

  initialize: (attrs, options) =>    
    ($ window).ajaxError (e,r) =>
      ($ '#request-error').html (get_template 'request-error')()
      if (j = $.parseJSON r.responseText) and (err = j.error)
        ($ '#request-error .msg').text 'Server Error: ' + err
    ($ window).ajaxSuccess (data) =>
      ($ '#request-error').html ''

    (API.schedules = new Schedules()).fetch()    

    API.controller = new API.Controller
    API.controller.showSchedules()

  add: (e) =>
    API.schedules.create {
      name: new Date
      entries: new Entries ([])
      }, 
      {
        success: (model, response) ->
          model.attributes.entries.schedule_id = model.attributes.id
          model.attributes.entries.create {
            start:0, 
            end: (24*3600) - 1
            directory: '/'
          }
      }

API.Controller = class Controller 
  showSchedules: =>
    if @schedulesView
      @schedulesView.close()

    @schedulesView = new SchedulesView
      collection: API.schedules
      el: $ '#schedules'
    @schedulesView

  unshowSchedule: =>
    if @scheduleView
      @scheduleView.close()
    if @entryView
      @entryView.close()  
    @entryView = null
    @scheduleView = null

  showSchedule: (schedule) =>
    @unshowEntry()

    if @scheduleView
      @scheduleView.close()

    @scheduleView = new ScheduleView   
      model: schedule
      el: $ '#schedule'
    @scheduleView

  unshowEntry: =>
    if @entryView
      @entryView.close() 
    @entryView = null

  showEntry: (entry, options) =>
    if @entryView
      @entryView.close()      

    @entryView = new EntryView {
        el: $('#entry')
        model: entry           
      }
      , options
    @entryView