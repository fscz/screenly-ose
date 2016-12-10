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



get_template = (name) -> _.template ($ "##{name}-template").html()
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
API.Asset = class Asset extends Backbone.Model
  idAttribute: "asset_id"
  fields: 'name mimetype uri duration options'.split ' '
  defaults: =>
    name: ''
    mimetype: 'webpage'
    uri: ''
    is_active: false
    duration: default_duration
    is_enabled: 0
    nocache: 0
    play_order: 0
  active: =>
    return @get('is_enabled') 

  backup: =>
    @backup_attributes = @toJSON()

  rollback: =>
    if @backup_attributes
      @set @backup_attributes
      @backup_attributes = undefined
  old_name: =>
    if @backup_attributes
      return @backup_attributes.name


API.Assets = class Assets extends Backbone.Collection
  url: "/api/assets"
  model: Asset
  comparator: 'play_order'


# Views
API.View = {};
API.View.EditAssetView = class EditAssetView extends Backbone.View
  $f: (field) => @$ "[name='#{field}']" # get field element
  $fv: (field, val...) => (@$f field).val val... # get or set filed value

  initialize: (options) =>
    @edit = options.edit
    ($ 'body').append @$el.html get_template 'asset-modal'

    (@$ 'input[name="nocache"]').prop 'checked', @model.get 'nocache'
    (@$ '.modal-header .close').remove()
    (@$el.children ":first").modal()

    @model.backup()

    @model.bind 'change', @validate

    @render()
    @validate()
    _.delay (=> (@$f 'uri').focus()), 300
    no

  render: () =>
    @undelegateEvents()
    if @edit
      (@$ f).attr 'disabled', on for f in 'mimetype uri file_upload'.split ' '
      (@$ '#modalLabel').text "Edit Asset"
      (@$ '.asset-location').hide(); (@$ '.asset-location.edit').show()      

    (@$ '.duration').toggle (true)
    @clickTabNavUri() if (@model.get 'mimetype') == 'webpage'

    for field in @model.fields
      if (@$fv field) != @model.get field
        @$fv field, @model.get field
    (@$ '.uri-text').html insertWbr @model.get 'uri'

    @delegateEvents()
    no

  viewmodel: =>
    for field in @model.fields when not (@$f field).prop 'disabled'      
      @model.set field, (@$fv field), silent:yes

  events:
    'submit form': 'save'
    'click .cancel': 'cancel'
    'change': 'change'
    'keyup': 'change'
    'click .tabnav-uri': 'clickTabNavUri'
    'click .tabnav-file_upload': 'clickTabNavUpload'
    'click .tabnav-browse': 'clickTabNavBrowse'
    'click #tab-browse.tab-pane > fieldset > ul.files > li': 'clickFolder'
    'paste [name=uri]': 'updateUriMimetype'
    'change [name=file_upload]': 'updateFileUploadMimetype'
    'change [name=mimetype]': 'change_mimetype'

  save: (e) =>
    e.preventDefault()
    @viewmodel()
    save = null
    @model.set 'nocache', if (@$ 'input[name="nocache"]').prop 'checked' then 1 else 0
    if (@$ '#tab-file_upload').hasClass 'active'
      if not @$fv 'name'
        @$fv 'name', get_filename @$fv 'file_upload'
      (@$ '.progress').show()
      @$el.fileupload
        url: @model.url()
        progressall: (e, data) => if data.loaded and data.total
          (@$ '.progress .bar').css 'width', "#{data.loaded/data.total*100}%"
      save = @$el.fileupload 'send', fileInput: (@$f 'file_upload')
    else
      if not @model.get 'name'
        if @model.old_name()
          @model.set {name: @model.old_name()}, silent:yes
        else if get_mimetype @model.get 'uri'
          @model.set {name: get_filename @model.get 'uri'}, silent:yes
        else
          @model.set {name: @model.get 'uri'}, silent:yes
      save = @model.save()

    (@$ 'input, select').prop 'disabled', on
    save.done (data) =>
      @model.id = data.asset_id
      @collection.add @model if not @model.collection
      (@$el.children ":first").modal 'hide'
      _.extend @model.attributes, data
      @model.collection.add @model unless @edit
    save.fail =>
      (@$ '.progress').hide()
      (@$ 'input, select').prop 'disabled', off
    no

  change: (e) =>
    @_change  ||= _.throttle (=>
      @viewmodel()
      @model.trigger 'change'
      @validate()
      yes), 500
    @_change arguments...

  change_mimetype: =>
    if (@$fv 'mimetype') != "video"
      (@$ '.zerohint').hide()
      @$fv 'duration', default_duration
    else
      (@$ '.zerohint').show()
      @$fv 'duration', 0

  validate: (e) =>
    that = this
    validators =
      duration: (v) =>
        if ('video' isnt @model.get 'mimetype') and (not (_.isNumber v*1 ) or v*1 < 1)
          'please enter a valid number'
      uri: (v) =>
        if @model.isNew() and ((that.$ '#tab-uri').hasClass 'active') and not url_test v
          'please enter a valid URL'
      file_upload: (v) =>
        if @model.isNew() and not v and (that.$ '#tab-file_upload').hasClass 'active'
          return 'please select a file'

    errors = ([field, v] for field, fn of validators when v = fn (@$fv field))
    
    (@$ ".control-group.warning .help-inline.warning").remove()
    (@$ ".control-group").removeClass 'warning'
    (@$ '[type=submit]').prop 'disabled', no
    
    for [field, v] in errors      
      (@$ '[type=submit]').prop 'disabled', yes
      (@$ ".control-group.#{field}").addClass 'warning'
      (@$ ".control-group.#{field} .controls").append \
        $ ("<span class='help-inline warning'>#{v}</span>")    

  cancel: (e) =>
    @model.rollback()
    unless @edit then @model.destroy()
    (@$el.children ":first").modal 'hide'

  clickTabNavUri: (e) => # TODO: clean
    if not (@$ '#tab-uri').hasClass 'active'
      (@$ 'ul.nav-tabs li').removeClass 'active'
      (@$ '.tab-pane').removeClass 'active'
      (@$ '.tabnav-file_upload').removeClass 'active'
      (@$ '#tab-file_upload').removeClass 'active' 
      (@$ '.tabnav-browse').removeClass 'active'
      (@$ '#tab-browse').removeClass 'active'

      (@$ '.tabnav-uri').addClass 'active'
      (@$ '#tab-uri').addClass 'active'
      (@$f 'uri').focus()

      @$fv 'uri', ''
      @$fv 'mimetype', 'webpage'

      @validate()
    no

  clickTabNavUpload: (e) => # TODO: clean
    if not (@$ '#tab-file_upload').hasClass 'active'
      (@$ 'ul.nav-tabs li').removeClass 'active'
      (@$ '.tab-pane').removeClass 'active'
      (@$ '.tabnav-uri').removeClass 'active'
      (@$ '#tab-uri').removeClass 'active'
      (@$ '.tabnav-browse').removeClass 'active'
      (@$ '#tab-browse').removeClass 'active'

      (@$ '.tabnav-file_upload').addClass 'active'
      (@$ '#tab-file_upload').addClass 'active' 
            
      @$fv 'uri', ''
      @$fv 'mimetype', 'webpage'

      @validate()
    no

  clickTabNavBrowse: (e) => # TODO: clean
    if not (@$ '#tab-browse').hasClass 'active'
      (@$ 'ul.nav-tabs li').removeClass 'active'
      (@$ '.tab-pane').removeClass 'active'
      (@$ '.tabnav-file_upload').removeClass 'active'
      (@$ '#tab-file_upload').removeClass 'active' 
      (@$ '.tabnav-uri').removeClass 'active'
      (@$ '#tab-uri').removeClass 'active'

      (@$ '.tabnav-browse').addClass 'active'
      (@$ '#tab-browse').addClass 'active'
      
      @$fv 'uri', '/'
      @$fv 'mimetype', 'dir'

      @.validate()

      @updateFolderSelection('/', 'dir')
    no
  clickFolder: (e) =>
    data_stat = $(e.target).data('stat')
    if data_stat 
      stat = JSON.parse(data_stat)
      
      @$fv 'uri', stat['path']
      @$fv 'mimetype', stat['mime']

      @.validate()

      @updateFolderSelection(stat['path'], stat['mime'])

  updateFolderSelection: (path, mime) =>   
    
    ($ '#tab-browse.tab-pane').find('.path').text(path)

    if mime == 'dir'
      $.ajax('/api/filesystem'+path).success (files, status, xhr) ->        
        ($ '#tab-browse.tab-pane').find('.files').empty()                    

        $.each files, (index,file) ->           
          li = $ '<li data-><img class="'+(if file['mime'] == 'dir' then 'dir' else 'file')+'"/>'+file.name+'</li>'
          li.data 'stat', JSON.stringify(file)
          ($ '#tab-browse.tab-pane').find('.files').append li
          

  updateUriMimetype: => _.defer => @updateMimetype @$fv 'uri'
  updateFileUploadMimetype: => _.defer => @updateMimetype @$fv 'file_upload'
  updateMimetype: (filename) =>
    # also updates the filename label in the dom
    mt = get_mimetype filename
    (@$ '#file_upload_label').text (get_filename filename)
    @$fv 'mimetype', mt if mt
    @change_mimetype()


API.View.AssetRowView = class AssetRowView extends Backbone.View
  tagName: "tr"

  initialize: (options) =>
    @template = get_template 'asset-row'

  render: =>
    @$el.html @template _.extend json = @model.toJSON(),
      name: insertWbr json.name # word break urls at slashes
    @$el.prop 'id', @model.get 'asset_id'
    (@$ ".delete-asset-button").popover content: get_template 'confirm-delete'
    (@$ ".toggle input").prop "checked", @model.get 'is_enabled'
    (@$ ".asset-icon").addClass switch @model.get "mimetype"
      when "video"   then "icon-facetime-video"
      when "image"   then "icon-picture"
      when "webpage" then "icon-globe"
      when "slideshow" then "icon-picture"
      else ""
    @el

  events:
    'change .is_enabled-toggle input': 'toggleIsEnabled'
    'click .edit-asset-button': 'edit'
    'click .delete-asset-button': 'showPopover'

  toggleIsEnabled: (e) =>
    val = (1 + @model.get 'is_enabled') % 2
    @model.set is_enabled: val
    @setEnabled off
    save = @model.save()
    save.done => @setEnabled on
    save.fail =>
      @model.set @model.previousAttributes(), silent:yes # revert changes
      @setEnabled on
      @render()
    yes

  setEnabled: (enabled) => if enabled
      @$el.removeClass 'warning'
      @delegateEvents()
      (@$ 'input, button').prop 'disabled', off
    else
      @hidePopover()
      @undelegateEvents()
      @$el.addClass 'warning'
      (@$ 'input, button').prop 'disabled', on

  edit: (e) =>
    new EditAssetView model: @model, edit:on
    no

  delete: (e) =>
    @hidePopover()
    if (xhr = @model.destroy()) is not false
      xhr.done => @remove()
    else
      @remove()
    no

  showPopover: =>
    if not ($ '.popover').length
      (@$ ".delete-asset-button").popover 'show'
      ($ '.confirm-delete').click @delete
      ($ window).one 'click', @hidePopover
    no

  hidePopover: =>
    (@$ ".delete-asset-button").popover 'hide'
    no


API.View.AssetsView = class AssetsView extends Backbone.View
  initialize: (options) =>
    @collection.bind event, @render for event in ('reset add remove sync'.split ' ')
    @sorted = (@$ '#active-assets').sortable
      containment: 'parent'
      axis: 'y'
      helper: 'clone'
      update: @update_order

  update_order: =>
    active = (@$ '#active-assets').sortable 'toArray'
    
    @collection.get(id).set('play_order', i) for id, i in active
    @collection.get(el.id).set('play_order', active.length) for el in (@$ '#inactive-assets tr').toArray()

    $.post '/api/assets/order', ids: ((@$ '#active-assets').sortable 'toArray').join ','

  render: =>
    @collection.sort()
    
    (@$ "##{which}-assets").html '' for which in ['active', 'inactive']

    @collection.each (model) =>
      which = if model.active() then 'active' else 'inactive'
      (@$ "##{which}-assets").append (new AssetRowView model: model).render()

    for which in ['inactive', 'active']
      @$(".#{which}-table thead").toggle !!(@$("##{which}-assets tr").length)
      
    @update_order()
   
    @el


API.App = class App extends Backbone.View
  initialize: =>
    ($ window).ajaxError (e,r) =>
      ($ '#request-error').html (get_template 'request-error')()
      if (j = $.parseJSON r.responseText) and (err = j.error)
        ($ '#request-error .msg').text 'Server Error: ' + err
    ($ window).ajaxSuccess (data) =>
      ($ '#request-error').html ''

    (API.assets = new Assets()).fetch()
    API.assetsView = new AssetsView
      collection: API.assets
      el: @$ '#assets'


  events: {'click #add-asset-button': 'add'}

  add: (e) =>
    new EditAssetView model:
      new Asset {}, {collection: API.assets}
    no
