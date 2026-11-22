local checks = 0
local function check(ok, what)
    if not ok then error('FAILED: '..what, 2) end
    checks = checks + 1
end

local stored = {
    line_count=2, legacy_line_count=4, opacity=10, intensity=80,
    color_refresh_mode='wide_wait', refresh_mode='screen',
    color_name='yellow', style='color', spotlight_layout='guide', step_mode='line'
}
local saved = {}
package.preload['gettext']=function() return function(x) return x end end
package.preload['datastorage']=function() return {
    getSettingsDir=function() return '/test' end,
    getDataDir=function() return '/test/koreader' end
} end
local image_loads, image_frees, image_path = 0, 0, nil
package.preload['ui/renderimage']=function()
    return {renderImageFile=function(_,path,_,width,height)
        image_loads=image_loads+1
        image_path=path
        if path:find('missing') then return nil end
        return {getWidth=function() return width end,
            getHeight=function() return height end,
            getType=function() return 'RGB32' end,
            free=function() image_frees=image_frees+1 end}
    end}
end
local chooser_folder, chooser_filter
package.preload['apps/filemanager/filemanagerutil']=function()
    return {showChooseDialog=function(_,callback,current,_,filter)
        chooser_folder=current
        chooser_filter=filter
        callback('/test/koreader/screensavers/forest.png')
    end}
end
package.preload['ffi/blitbuffer']=function() return {
    COLOR_BLACK='BLACK',COLOR_WHITE='WHITE',
    TYPE_BBRGB32='RGB32',TYPE_BB8A='BB8A',
    ColorRGB32=function(r,g,b,a) return {r=r,g=g,b=b,a=a} end
} end
package.preload['device']=function() return {screen={getWidth=function() return 600 end, getHeight=function() return 900 end}} end
package.preload['ui/geometry']=function() return {new=function(_,v) return v end} end
package.preload['luasettings']=function()
   return {open=function() return {
      readSetting=function(_,k) return stored[k] end,
      saveSetting=function(_,k,v) stored[k]=v; saved[k]=v end,
      flush=function() end
   } end}
end
local registered_actions = {}
package.preload['dispatcher']=function() return {
    registerAction=function(_,name,action)
        -- KOReader's dispatcher is idempotent: a second document instance
        -- registers the same named action without adding it again.
        if not registered_actions[name] then registered_actions[name] = action end
        return true
    end,
} end
local dirty = {}
local next_ticks = {}
local scheduled, top_widget, spin_widget = {}, nil, nil
local function flushNextTicks()
    while #next_ticks > 0 do
        local cb = table.remove(next_ticks, 1)
        cb()
    end
end
package.preload['ui/uimanager']=function() return {
   setDirty=function(_,widget, mode, region) dirty[#dirty+1]={widget=widget,mode=mode,region=region} end,
   show=function(_,msg)
       if msg.is_spin then spin_widget = msg else error('unexpected InfoMessage') end
   end,
   nextTick=function(_,cb) next_ticks[#next_ticks+1] = cb end,
   scheduleIn=function(_,seconds,cb)
       assert(not scheduled[cb], 'timer scheduled twice')
       scheduled[cb] = seconds
   end,
   unschedule=function(_,cb) scheduled[cb] = nil end,
   getTopmostVisibleWidget=function() return top_widget end,
} end
package.preload['ui/widget/spinwidget']=function()
    return {new=function(_,options) options.is_spin=true; return options end}
end
package.preload['ui/widget/widget']=function()
   local Widget={}
   function Widget:extend(fields) return setmetatable(fields,{__index=self}) end
   return Widget
end
package.preload['ui/widget/infomessage']=function() return {new=function(_,arg) return arg end} end
local plugin_path = (arg and arg[0] or 'tests/test_plugin.lua'):gsub('tests/test_plugin.lua$', 'focusreader.koplugin/')
local P = dofile(plugin_path..'main.lua')
local log={}
local page=1
local doc={}
doc._document={setStringProperty=function(_,prop,value) log[#log+1]={kind='color',value=value} end}
function doc:getCurrentPage() return page end
function doc:getCurrentPos() return 0 end
function doc:getVisiblePageCount() return 1 end
function doc:getPageCount() return 3 end
function doc:clearSelection() log[#log+1]={kind='clear'} end
function doc:getTextFromXPointers(a,b,draw) log[#log+1]={kind='select',draw=draw}; return 'hello' end
function doc:getTextFromPositions(a,b,do_not_draw)
    local boxes = {}
    for i=1,12 do boxes[i]={x=40,y=60+40*i,w=380,h=24} end
    return {sboxes=boxes,pos0='xp1',pos1='xp2'}
end
local menu_items
local view={dialog={},view_mode='page',footer_visible=false,registerViewModule=function(self,k,p) self[k]=p end}
local roll={}
local original=function(_,d) page=math.min(3,math.max(1,page+d)); return true end
roll.onGotoViewRel=original
local ui={document=doc,rolling=roll,highlight={setSelectionColor=function() log[#log+1]={kind='restore'} end},menu={registerToMainMenu=function(_,plugin) menu_items={}; plugin:addToMainMenu(menu_items) end}}
local instance=setmetatable({ui=ui,view=view},{__index=P})
instance:init()
local focus_action = registered_actions.focusreader_toggle
check(focus_action and focus_action.category=='none'
    and focus_action.event=='FocusReaderToggle'
    and focus_action.title=='Toggle Focus Reader'
    and focus_action.reader==true,
    'reader-only gesture action registered on initialization')
check(not instance.enabled, 'dispatcher registration does not auto-start')
check(instance.opacity==56, 'default opacity overrides saved old opacity')
check(instance.refresh_mode=='focused','focused refresh overrides saved screen refresh')
check(instance.color_refresh_mode==nil,'experimental color refresh ignored')
check(instance.line_count==2 and instance.legacy_line_count==4,'line settings retained')
check(instance.color_name=='yellow','saved color retained')
check(instance.spotlight_layout=='guide','spotlight style retained')
instance:onReaderReady()
check(instance.supported and view.focusreader==instance,'plugin loaded and registered')
check(type(menu_items.focusreader)=='table','menu registered')
check(menu_items.focusreader.sorting_hint=='tools','Tools menu location')
local items=menu_items.focusreader.sub_item_table
check(#items==3,'main menu is Start/Stop, Focus mode and Settings only')
check(items[2].text=='Focus mode' and #items[2].sub_item_table==4,
    'Focus mode contains Highlight, both Spotlight layouts and Freeform')
local mode_choices=items[2].sub_item_table
check(mode_choices[4].text=='Freeform Focus (no text needed)',
    'no-text Freeform mode remains selectable')
check(items[3].text=='Settings' and #items[3].sub_item_table==3,
    'Settings opens all three mode folders at once')
local settings_folders=items[3].sub_item_table
check(settings_folders[1].text=='Highlight Focus'
    and settings_folders[2].text=='Spotlight Focus'
    and settings_folders[3].text=='Freeform Focus',
    'settings folders are ordered and labeled clearly')
local highlight_settings=settings_folders[1].sub_item_table
local spotlight_settings=settings_folders[2].sub_item_table
local freeform_settings=settings_folders[3].sub_item_table
check(#highlight_settings==7 and highlight_settings[1].text=='Color'
    and highlight_settings[2].text=='Focused lines'
    and highlight_settings[3].text=='Advance by',
    'Highlight settings include color, focused lines and nested text navigation')
check(#highlight_settings[1].sub_item_table==6
    and #highlight_settings[2].sub_item_table==5,
    'Highlight color and 1–5-line controls remain available')
check(highlight_settings[3].sub_item_table[1].text=='One line'
    and highlight_settings[3].sub_item_table[2].text=='Whole focused group'
    and highlight_settings[3].sub_item_table[3].text=='Whole paragraph',
    'shared Advance by settings keep all three options')
check(highlight_settings[5].text=='Word-by-word (no speech)'
    and highlight_settings[6].text=='Advanced'
    and highlight_settings[6].sub_item_table[1].text=='Word navigation diagnostic',
    'word navigation and diagnostics are preserved')
check(#spotlight_settings==4
    and spotlight_settings[1].text=='Focused lines'
    and spotlight_settings[2].text=='Advance by'
    and spotlight_settings[3].text=='Mask background'
    and spotlight_settings[4].text=='Center focused paragraph',
    'Spotlight settings keep existing controls and add the centering toggle')
check(#spotlight_settings[1].sub_item_table==5
    and #spotlight_settings[3].sub_item_table==6,
    'Spotlight preserves 1–5 line presets, masks, image chooser and backing')
check(#freeform_settings==3
    and freeform_settings[1].text=='Window height'
    and #freeform_settings[1].sub_item_table==8
    and freeform_settings[2].text=='Window overlap'
    and #freeform_settings[2].sub_item_table==7
    and freeform_settings[3].text=='Mask background'
    and #freeform_settings[3].sub_item_table==6,
    'Freeform offers window height, overlap and shared mask, not text Advance by')
check(spotlight_settings[3].sub_item_table == freeform_settings[3].sub_item_table,
    'Spotlight and Freeform share the same mask settings')
local image_settings=spotlight_settings[3].sub_item_table[6].sub_item_table
check(spotlight_settings[3].sub_item_table[6].text=='Image background color'
    and #image_settings==2,
    'transparent-image backing options are inside Mask background')
local old_style=instance.style
local old_mask=instance.spotlight_mask_color
instance.style='mask'
check(#settings_folders==3
    and settings_folders[1].sub_item_table==highlight_settings
    and settings_folders[3].sub_item_table==freeform_settings,
    'inactive Highlight and Freeform settings stay accessible in Spotlight')
instance.style='freeform'
check(#settings_folders==3
    and settings_folders[1].sub_item_table==highlight_settings
    and settings_folders[2].sub_item_table==spotlight_settings,
    'inactive Highlight and Spotlight settings stay accessible in Freeform')
instance.style=old_style
instance.spotlight_mask_color=old_mask
local labels={}
local function scan(a)
  for _,e in ipairs(a) do
    labels[#labels+1]=(e.text or '')
    if e.sub_item_table then scan(e.sub_item_table) end
  end
end
scan(items)
local label_text=table.concat(labels,';'):lower()
check(not label_text:find('opacity') and not label_text:find('refresh')
    and not label_text:find('test') and not label_text:find('clicker'),
    'technical options stay out of the visible settings')
instance:onFocusReaderToggle()
check(instance.enabled and roll.onGotoViewRel~=original,
    'gesture toggle starts focus and installs page-control hook')
instance:onFocusReaderToggle()
check(not instance.enabled and roll.onGotoViewRel==original,
    'gesture toggle stops focus and restores page controls')
instance:start()
check(instance.enabled and roll.onGotoViewRel~=original,'start installs clicker hook')
local selected=false
for _,x in ipairs(log) do if x.kind=='select' and x.draw then selected=true end end
check(selected,'native selection rendered')
local before=instance.index
roll:onGotoViewRel(1)
check(instance.index==before+1,'clicker down advances a line')
roll:onGotoViewRel(-1)
check(instance.index==before,'clicker up returns a line')
local total = #instance.lines
for _=1,total do roll:onGotoViewRel(1) end
check(page==2,'automatic next page')
for _=1,total do roll:onGotoViewRel(-1) end
check(page==1,'automatic previous page')
highlight_settings[1].sub_item_table[2].callback()  -- orange
check(instance.color_name=='orange' and stored.color_name=='orange','changing color saved')
highlight_settings[2].sub_item_table[4].callback()
check(instance.line_count==4 and stored.line_count==4,'highlight line count changed and saved')
mode_choices[2].callback()  -- window
check(instance.style=='mask' and instance.spotlight_layout=='window','spotlight window selected')
local bb={paints=0, paintRect=function(self,_,_,w,h,color) self.paints=self.paints+1; assert(color=='BLACK') end}
instance:paintTo(bb,0,0)
check(bb.paints>=1,'blackout drawn')
check(instance.spotlight_mask_color=='black','old settings default to black')
spotlight_settings[3].sub_item_table[2].callback()
check(instance.spotlight_mask_color=='white' and stored.spotlight_mask_color=='white','white mask preference saved')
local white_bb={paints=0,paintRect=function(self,_,_,w,h,color) self.paints=self.paints+1; assert(color=='WHITE') end}
instance:paintTo(white_bb,0,0)
check(white_bb.paints>0,'white mask painted')
spotlight_settings[3].sub_item_table[1].callback()
check(instance.spotlight_mask_color=='black','black can be restored')
mode_choices[3].callback() -- guide
check(instance.style=='mask' and instance.spotlight_layout=='guide','spotlight guide selected')
spotlight_settings[1].sub_item_table[3].callback()
check(instance.legacy_line_count==3 and stored.legacy_line_count==3,'independent spotlight lines saved')
mode_choices[1].callback()
check(instance.style=='color','switch back to highlight focus')
check(instance.opacity==56,'opacity unchanged after style changes')
instance:stop()
check(not instance.enabled and roll.onGotoViewRel==original,'stop restores clicker hook')
-- Word focus must not start without native word geometry.
highlight_settings[5].callback()
check(instance.word_mode and stored.word_mode,'word mode persists')
local mgr = require('ui/uimanager')
local original_show_word = mgr.show
local word_messages = 0
mgr.show = function() word_messages = word_messages + 1 end
instance:start()
check(not instance.enabled and word_messages == 1,'missing word geometry fails safely')
mgr.show = original_show_word
highlight_settings[5].callback()
check(not instance.word_mode,'word mode can be disabled')
check(saved.opacity==nil and saved.intensity==nil and saved.color_refresh_mode==nil and saved.refresh_mode==nil, 'retired settings never rewritten')
check(dirty[#dirty].mode=='ui','nonflashing ui refresh mode preserved')

-- A reader without a native selection backend must not silently switch a
-- working Spotlight Focus session to blank colored selection.
instance:setStyle('mask')
instance:start()
check(instance.enabled and instance.style=='mask', 'spotlight starts before fallback test')
local original_color_method = doc.getTextFromXPointers
doc.getTextFromXPointers = nil
-- Test with UIManager.show overridden to record expected message, not crash.
local manager = require('ui/uimanager')
local orig_show = manager.show
local info_count = 0
manager.show = function(_,msg) info_count = info_count + 1; assert(type(msg.text)=='string') end
instance:setStyle('color')
check(instance.style=='mask' and info_count==1, 'missing native selection API preserves spotlight')
doc.getTextFromXPointers = original_color_method
manager.show = orig_show
instance:stop()

-- KOReader's checked settings stay open and refresh their checkmarks by
-- default. Only Start/Stop and informational diagnostics deliberately close.
local function driveMenu(item)
    local trace = {}
    local fake = {
        closeMenu = function() trace[#trace + 1] = 'close' end,
        updateItems = function() trace[#trace + 1] = 'update' end,
    }
    local original_setDirty = require('ui/uimanager').setDirty
    require('ui/uimanager').setDirty = function(self, widget, mode, region)
        trace[#trace + 1] = 'paint'
        original_setDirty(self, widget, mode, region)
    end
    local was_enabled = instance.enabled
    item.callback(fake)
    local is_start_stop = item.text == nil and item.text_func ~= nil
    if is_start_stop then
        check(instance.enabled == was_enabled and #next_ticks == 1,
            'Start/Stop waits for TouchMenu to dismiss before starting')
    end
    -- Mirrors KOReader TouchMenu:onMenuSelect: close automatically for an
    -- unchecked leaf item unless keep_menu_open is set.
    if item.checked or item.checked_func then
        if not (item.check_callback_updates_menu or item.check_callback_closes_menu) then
            fake:updateItems()
        end
    elseif not item.keep_menu_open then
        fake:closeMenu()
    end
    flushNextTicks()
    require('ui/uimanager').setDirty = original_setDirty
    if is_start_stop then
        check(trace[1] == 'close' and instance.enabled ~= was_enabled,
            'Start/Stop toggles after native menu close')
        local first_paint = table.concat(trace, ','):find('paint')
        check(not first_paint or first_paint > #'close',
            'Start/Stop never repaints before native menu close')
    else
        check(not table.concat(trace, ','):find('close'),
            'adjusting a setting never closes the configuration')
        if item.checked_func then
            check(trace[#trace] == 'update', 'checked setting refreshes menu')
        else
            check(item.keep_menu_open == true,
                'non-checked file picker leaves settings open')
        end
    end
end
local function eachLeaf(list)
    for _,entry in ipairs(list) do
        if entry.sub_item_table then
            eachLeaf(entry.sub_item_table)
        elseif entry.callback and entry.text ~= 'Word navigation diagnostic'
                and (not entry.enabled_func or entry.enabled_func()) then
            if entry.checked_func then
                check(not entry.check_callback_closes_menu,
                    'checked setting uses native menu refresh')
            end
            driveMenu(entry)
        end
    end
end
check(not instance.enabled, 'menu test starts stopped')
eachLeaf(mode_choices)
eachLeaf(settings_folders)
instance:setCenterFocusedParagraph(false)
if instance.enabled then instance:stop() end
check(roll.onGotoViewRel == original, 'menu sweep restores page controls')

local reader_closed = 0
ui.menu.onTapCloseMenu = function() reader_closed = reader_closed + 1 end
local native_close_count = 0
local touch = {closeMenu=function() native_close_count = native_close_count + 1 end}
-- Choosing a color must leave the full settings stack open.
highlight_settings[1].sub_item_table[1].callback(touch)
check(reader_closed == 0 and native_close_count == 0,
    'color change keeps ReaderMenu open')
-- The native menu closure occurs after callback, before the next UI tick.
items[1].callback(touch)
check(not instance.enabled and #next_ticks == 1,
    'Start defers activation until native TouchMenu has closed')
check(items[1].keep_menu_open ~= true, 'Start/Stop allows automatic menu close')
if not items[1].keep_menu_open then touch:closeMenu() end
check(native_close_count == 1 and reader_closed == 0,
    'KOReader TouchMenu performs closure without a second X tap')
flushNextTicks()
check(instance.enabled and roll.onGotoViewRel ~= original,
    'Start activates immediately after dismissal and hooks page navigation')
-- The same menu action also stops focus without leaving the menu visible.
items[1].callback(touch)
check(instance.enabled and #next_ticks == 1,
    'Stop defers deactivation until after native menu dismissal')
if not items[1].keep_menu_open then touch:closeMenu() end
flushNextTicks()
check(native_close_count == 2 and not instance.enabled
    and roll.onGotoViewRel == original,
    'Stop also closes menu and restores page turning')
ui.menu.onTapCloseMenu = nil

-- Word navigation must skip whitespace and standalone punctuation, including
-- multi-byte punctuation, without dropping non-ASCII words.
local old_get_word = doc.getWordFromPosition
local original_line_count = instance.line_count
local original_style = instance.style
local original_word_mode = instance.word_mode
local samples = {
    {word='Hello',x=40,w=45},
    {word=' ',x=88,w=9},
    {word=',',x=100,w=8},
    {word='world!',x=112,w=55},
    {word='…',x=170,w=9},
    {word='“',x=180,w=5},
    {word='café',x=185,w=45},
}
function doc:getWordFromPosition(pos)
    if pos.y < 100 or pos.y > 124 then return nil end
    for i,entry in ipairs(samples) do
        if pos.x >= entry.x and pos.x < entry.x+entry.w then
            return {word=entry.word,sbox={x=entry.x,y=100,w=entry.w,h=24},
                pos0='word'..i..'start',pos1='word'..i..'end'}
        end
    end
end
instance:setStyle('color')
instance:setWordMode(true)
instance:start()
check(instance.enabled and #instance.words==3,
    'word focus skips spaces and punctuation but keeps Unicode words')
local w1=instance.words[1].pos0
roll:onGotoViewRel(1)
check(instance.words[instance.index].pos0~=w1 and instance.index==2,
    'one click advances directly to next real word')
roll:onGotoViewRel(1)
check(instance.index==3,'next click reaches accented word without punctuation stop')
-- Reproduce real Kobo diagnostic: identical visible word with different
-- XPointers and widths for trailing space/punctuation.
function doc:getWordFromPosition(pos)
    if pos.y < 100 or pos.y > 124 then return nil end
    if pos.x >= 40 and pos.x < 67 then
        local padded = pos.x >= 53
        return {word=padded and 'I ' or 'I',
            sbox={x=40,y=100,w=padded and 27 or 15,h=24},
            pos0=padded and 'I-space-start' or 'I-start',
            pos1=padded and 'I-space-end' or 'I-end'}
    end
    if pos.x >= 85 and pos.x < 185 then
        local padded = pos.x >= 160
        return {word=padded and 'showered,' or 'showered',
            sbox={x=85,y=100,w=padded and 100 or 92,h=24},
            pos0=padded and 'shower-comma-start' or 'shower-start',
            pos1=padded and 'shower-comma-end' or 'shower-end'}
    end
end
instance.lines={{x=40,y=100,w=150,h=24,area={x=0,y=0,w=400,h=400}}}
instance:refreshWords()
check(#instance.words==2,'real Kobo duplicate XPointers collapse into two visible words')
check(instance.words[1].word_text=='I' and instance.words[2].word_text=='showered',
    'deduplication prefers boxes without trailing space or comma')
-- A punctuation-extended variant may have a shifted start and different
-- XPointers; it must not become an extra button press after the word.
function doc:getWordFromPosition(pos)
    if pos.y < 100 or pos.y > 124 then return nil end
    if pos.x >= 40 and pos.x < 130 then
        local extended = pos.x >= 90
        return {word=extended and 'better,”' or 'better',
            sbox={x=extended and 42 or 40,y=100,w=extended and 88 or 78,h=24},
            pos0=extended and 'better-punct-start' or 'better-start',
            pos1=extended and 'better-punct-end' or 'better-end'}
    end
    if pos.x >= 140 and pos.x < 195 then
        return {word='said',sbox={x=140,y=100,w=55,h=24},pos0='said-start',pos1='said-end'}
    end
end
instance.lines={{x=40,y=100,w=155,h=24,area={x=0,y=0,w=400,h=400}}}
instance:refreshWords()
check(#instance.words==2,'shifted punctuation-extended word box does not add navigation stop')
check(instance.words[1].word_text=='better' and instance.words[2].word_text=='said',
    'punctuation variant is collapsed and next actual word remains')
-- CRengine can split wasn't into [wasn] [’] [t]. A single
-- navigation step must select the whole contraction, not its fragments.
function doc:getWordFromPosition(pos)
    if pos.y < 100 or pos.y > 124 then return nil end
    local parts = {
        {word='wasn',x=40,w=45},
        {word='’',x=85,w=8},
        {word='t',x=93,w=10},
        {word=' ',x=103,w=12},
        {word='ready',x=115,w=55},
    }
    for i,part in ipairs(parts) do
        if pos.x >= part.x and pos.x < part.x + part.w then
            return {word=part.word,sbox={x=part.x,y=100,w=part.w,h=24},
                pos0='contraction'..i..'start',pos1='contraction'..i..'end'}
        end
    end
end
instance.lines={{x=40,y=100,w=130,h=24,area={x=0,y=0,w=400,h=400}}}
instance:refreshWords()
check(#instance.words==2,'apostrophe-separated contraction is one word, adjacent word stays separate')
check(instance.words[1].word_text=='wasnt' and instance.words[1].w==63,
    'curly apostrophe fragments merge into one geometry range')
instance:stop()
doc.getWordFromPosition=old_get_word
instance:setWordMode(original_word_mode)
instance:setLines(original_line_count)
instance:setStyle(original_style)

-- A selected screensaver image paints only masked areas, never the reading
-- window; loading is cached and failures revert safely to a black mask.
instance:setStyle('mask')
instance.spotlight_image_path=nil
instance:chooseSpotlightImage()
check(instance.spotlight_mask_color=='image' and
    instance.spotlight_image_path=='/test/koreader/screensavers/forest.png',
    'image chooser stores the chosen image and enables custom mask')
check(chooser_folder=='/test/koreader/screensavers',
    'image chooser opens KOReader screensavers directory')
check(chooser_filter('foo.PNG') and chooser_filter('image.jpeg')
    and not chooser_filter('document.pdf'), 'chooser filters supported image formats')
instance:setSpotlightImageBaseColor('black')
instance:start()
local image_blits, black_backings = {}, 0
local image_bb={
    pmulalphablitFrom=function(_,image,dx,dy,sx,sy,w,h)
        image_blits[#image_blits+1]={x=dx,y=dy,w=w,h=h}
    end,
    blitFrom=function() error('RGBA image must not be flattened by plain blit') end,
    paintRect=function(_,x,y,w,h,color)
        check(color=='BLACK','custom image defaults to black underlay')
        black_backings=black_backings+1
    end,
}
instance:paintTo(image_bb,0,0)
check(#image_blits>0 and image_loads==1,
    'RGBA background uses premultiplied-alpha compositing')
check(black_backings>0,'black backing painted behind transparency')
instance:paintTo(image_bb,0,0)
check(image_loads==1,'subsequent focus repaints reuse decoded image')
instance:setSpotlightImageBaseColor('white')
check(instance.spotlight_image_base_color=='white' and
    stored.spotlight_image_base_color=='white','image backing color saved separately')
local white_underlay, white_blits = 0, 0
local image_white_bb={
    pmulalphablitFrom=function() white_blits=white_blits+1 end,
    blitFrom=function() error('white RGBA mode must preserve alpha') end,
    paintRect=function(_,x,y,w,h,color)
        if color=='WHITE' then white_underlay=white_underlay+1 end
    end,
}
instance:paintTo(image_white_bb,0,0)
check(white_underlay>0 and white_blits>0,
    'white backing shows through PNG transparency without altering artwork')
check(instance.spotlight_mask_color=='image','changing image backing retains custom image mode')

instance:setSpotlightImageBaseColor('black')
check(instance.spotlight_mask_color=='image' and instance.spotlight_image_base_color=='black',
    'custom image can return to black backing without changing image selection')
instance:stop()
check(image_frees>=1,'image memory released when focus stops')
instance.spotlight_image_path='/test/koreader/screensavers/missing.png'
instance:setSpotlightMaskColor('black')
instance:setSpotlightMaskColor('image')
instance:start()
local fallback={painted=0,paintRect=function(self,_,_,_,_,color)
    self.painted=self.painted+1
    check(color=='BLACK','unavailable image falls back to black')
end}
instance:paintTo(fallback,0,0)
check(fallback.painted>0,'unreadable image falls back to a safe black mask')
instance:setSpotlightImageBaseColor('white')
local missing_white={painted=0,paintRect=function(self,_,_,_,_,color)
    check(color=='WHITE','missing image follows white backing preference')
    self.painted=self.painted+1
end}
instance:paintTo(missing_white,0,0)
check(missing_white.painted>0,'missing image safely falls back to white backing')
instance:setSpotlightImageBaseColor('black')
instance:stop()
instance:setSpotlightMaskColor('black')
instance:setStyle(original_style)

-- Book-cover masks use KOReader's native, in-memory current-book cover API.
-- A cover is decoded once and freed on Stop, never written to the filesystem.
doc.file = '/test/books/example.epub'
local covers_requested, covers_freed = 0, 0
ui.bookinfo = {
    getCoverImage = function(_, current_doc, filename)
        check(current_doc == doc and filename == doc.file,
            'book cover request uses the currently opened book')
        covers_requested = covers_requested + 1
        return {
            getWidth = function() return 600 end,
            getHeight = function() return 900 end,
            getType = function() return 'RGB32' end,
            free = function() covers_freed = covers_freed + 1 end,
        }
    end,
}
instance:setStyle('mask')
instance:setSpotlightMaskColor('cover')
check(instance.spotlight_mask_color == 'cover'
    and stored.spotlight_mask_color == 'cover',
    'book cover mode persists as a separate mask choice')
instance:start()
local cover_before = #image_blits
instance:paintTo(image_bb, 0, 0)
instance:paintTo(image_bb, 0, 0)
check(#image_blits > cover_before and covers_requested == 1,
    'current cover is drawn and cached during repeated focus steps')
instance:stop()
check(covers_freed == 1, 'cached current cover is freed on Stop')
-- Missing artwork is a safe fallback and failed lookups are cached.
local no_cover_calls = 0
ui.bookinfo.getCoverImage = function()
    no_cover_calls = no_cover_calls + 1
    return nil
end
instance:start()
instance:paintTo(fallback, 0, 0)
instance:paintTo(fallback, 0, 0)
check(no_cover_calls == 1,
    'missing cover uses black fallback without repeated extraction attempts')
instance:stop()
ui.bookinfo = nil
doc.file = nil
instance:setSpotlightMaskColor('black')
instance:setStyle(original_style)

-- EPUB underline-only uses the same temporary overlay without CRengine
-- selection; switching back restores native selection.
instance:setStyle('color')
instance:setWordMode(false) -- menu sweep toggled word mode; fixture has no word API
instance:setPDFHighlightStyle('underline')
instance:start()
check(instance.enabled and instance:usesOverlayHighlight(),'EPUB underline overlay starts')
local epub_strokes={}
local epubbb={blendRectRGB32=function(_,x,y,w,h,c)
    epub_strokes[#epub_strokes+1]={x=x,y=y,w=w,h=h,c=c}
end}
instance:paintTo(epubbb,0,0)
check(#epub_strokes>0,'EPUB underline paints below text')
check(epub_strokes[1].h==3,'EPUB underline uses strong three-pixel stroke')
instance:setPDFHighlightStyle('tint')
check(not instance:usesOverlayHighlight(),'EPUB returns to native highlighting')
instance:stop()

-- PDF Highlight Focus draws temporary blended rectangles; it never calls
-- CRengine selection and never creates persistent PDF annotations.
local pdfdoc={configurable={text_wrap=0}}
function pdfdoc:getPageCount() return 3 end
function pdfdoc:getTextFromPositions(p0,p1)
    check(p0.page==1 and p1.page==1,'PDF positions include page number')
    return {sboxes={{{x0=30,y0=50,x1=180,y1=70},{x0=190,y0=50,x1=350,y1=70}},
        {{x0=30,y0=90,x1=350,y1=110}}}}
end
local pdfpaging={current_page=1}
local pdfturn=function(self,d) self.current_page=self.current_page+d; return true end
pdfpaging.onGotoViewRel=pdfturn
local pdfview={dialog={},view_mode='page',registerViewModule=function() end,
    screenToPageTransform=function(_,p) return {page=1,x=p.x,y=p.y} end,
    pageToScreenTransform=function(_,_,rect) return rect end}
local pdfui={document=pdfdoc,paging=pdfpaging,menu={registerToMainMenu=function() end}}
local pdf=setmetatable({ui=pdfui,view=pdfview},{__index=P})
pdf:init()
pdf.style='color'
pdf:onReaderReady()
check(pdf.supported,'PDF support without EPUB getCurrentPage')
pdf:start()
check(pdf.enabled and #pdf.lines==2,'PDF text boxes become two focus lines')
local blended={}
local pdfbb={blendRectRGB32=function(_,x,y,w,h,color)
    blended[#blended+1]={x=x,y=y,w=w,h=h,color=color}
end}
pdf:setPDFHighlightStyle('tint') -- earlier menu sweep persisted underline mode
pdf:paintTo(pdfbb,0,0)
check(#blended==4,'PDF Highlight draws faint tint and underline for each text line')
pdf:setPDFHighlightStyle('underline')
check(stored.pdf_highlight_style=='underline','PDF underline preference persists')
blended={}
pdf:paintTo(pdfbb,0,0)
check(#blended==2,'underline-only mode draws no tint over glyphs')
check(blended[1].h==3 and blended[1].color.a==235,'underline-only mode draws high-contrast three-pixel line')
check(blended[1].color.r < 100 and blended[1].color.g < 100,'underline-only darkens yellow for e-ink visibility')
pdf:setPDFHighlightStyle('tint')
blended={}
pdf:paintTo(pdfbb,0,0)
check(blended[1].color.a==26,'PDF text tint remains light enough for readability')
check(blended[2].color.a==165 and blended[2].h==2,'PDF underline is stronger but stays below glyphs')
check(blended[1].color.a>0 and blended[1].color.a<255,'PDF highlight blends transparently')
check(type(blended[1].color.r)=='number','PDF highlight uses configured RGB color')
pdf:stop()
check(pdfpaging.onGotoViewRel==pdfturn,'PDF page-turn hook restored')

-- A PDF that has diagrams/scans or no extractable text must never trap the
-- page-turn hook or crash when geometry disappears after a successful start.
local original_pdf_text = pdfdoc.getTextFromPositions
pdfdoc.getTextFromPositions = function() return {sboxes={}} end
local original_show_pdf = mgr.show
mgr.show = function() end
pdf:start()
mgr.show = original_show_pdf
check(not pdf.enabled and pdfpaging.onGotoViewRel==pdfturn,
    'PDF with no text refuses to start and leaves native turning intact')
pdfdoc.getTextFromPositions = original_pdf_text

-- Backend failures during a page update must not escape into KOReader.
pdf:start()
check(pdf.enabled,'PDF restarted for backend failure test')
pdfdoc.getTextFromPositions = function() error('MuPDF text position unavailable') end
local ok_update = pcall(function() pdf:onPageUpdate() end)
check(ok_update and not pdf.enabled and pdfpaging.onGotoViewRel==pdfturn,
    'PDF backend exception stops focus and restores native page turning')
pdfdoc.getTextFromPositions = original_pdf_text

-- Landscape can put the extreme corners outside the page; inset probe
-- coordinates must still find usable text.
local first_probe = true
pdfview.screenToPageTransform = function(_,p)
    if p.x < 15 or p.x > 585 then return nil end
    first_probe = false
    return {page=1,x=p.x,y=p.y}
end
pdf:start()
check(pdf.enabled and #pdf.lines==2 and not first_probe,
    'landscape inset probes retain readable PDF text')
pdf:stop()

-- Rotation/reflow to geometry-less output must stop safely and not leave
-- the clicker intercepted. A later valid page can start a new focus session.
pdfview.screenToPageTransform = function(_,p) return {page=1,x=p.x,y=p.y} end
pdf:start()
pdfdoc.getTextFromPositions = function() return {sboxes={}} end
local rotated_ok = pcall(function() pdf:onScreenResize() end)
check(rotated_ok and not pdf.enabled and pdfpaging.onGotoViewRel==pdfturn,
    'PDF rotation losing text positions restores reading controls')
pdfdoc.getTextFromPositions = original_pdf_text
pdf:start()
check(pdf.enabled and #pdf.lines==2,
    'PDF focus can restart after returning to a supported layout')
pdf:stop()

-- EPUB paragraph integration: CRengine XPointers identify seven-line
-- paragraphs, while the mock still supplies its original text-box geometry.
instance:setStyle('color')
instance:setPDFHighlightStyle('tint')
instance:setWordMode(false)
instance:setStepMode('line')
doc.getWordFromPosition = function(_,pos)
    local p = pos.y < 345 and '2' or '3'
    return {pos0='/body/DocFragment/body/div/p['..p..']/span/text().12'}
end
instance:start()
check(instance.enabled and #instance.lines==12,
    'paragraph integration fixture started with twelve visual lines')
instance:setStepMode('paragraph')
check(instance.step_mode=='paragraph' and stored.step_mode=='paragraph',
    'paragraph setting persists and is activated immediately')
check(#instance.paragraph_starts==2 and instance.paragraph_starts[1]==1
    and instance.paragraph_starts[2]==7,
    'structural EPUB paragraphs detected from CRe positions')
local first_para=instance:getSlot()
check(first_para.h>200,'paragraph focus highlights six lines, not just 1–5')
roll:onGotoViewRel(1)
check(instance.index==7,'clicker next advances to next paragraph')
local next_para=instance:getSlot()
check(next_para.y>first_para.y,'second paragraph has separate highlight window')
roll:onGotoViewRel(-1)
check(instance.index==1,'clicker previous returns to prior paragraph')
roll:onGotoViewRel(1)
roll:onGotoViewRel(1)
check(page==2 and instance.index==1,
    'paragraph next at final page anchor advances to next page')
roll:onGotoViewRel(-1)
check(page==1 and instance.index==7,
    'paragraph previous from next page returns to last visible paragraph')
roll:onGotoViewRel(-1)
check(instance.index==1,'reverse clicker returns to first EPUB paragraph')
instance:setStyle('mask')
instance:setSpotlightLayout('guide')
check(instance:getSlot().h==first_para.h,
    'Spotlight Reading Guide retains original paragraph bounds')
instance:setSpotlightLayout('window')
local clean_window = instance:getSlot()
check(clean_window.y == instance.lines[instance.index].y,
    'paragraph Reading Window omits unnecessary top padding')
check(clean_window.h == first_para.h - 2,
    'paragraph Reading Window retains all measured text lines')
roll:onGotoViewRel(1)
check(instance.index == 7, 'paragraph next still advances in Reading Window')
check(dirty[#dirty].mode == 'ui' and dirty[#dirty].region == nil,
    'paragraph Reading Window requests nonflashing viewport redraw')
roll:onGotoViewRel(-1)
check(instance.index == 1, 'paragraph reverse still navigates properly')
instance:setSpotlightLayout('guide')
instance:setStepMode('line')
check(instance.step_mode=='line' and stored.step_mode=='line',
    'line mode remains selectable after paragraph mode')
instance:setStepMode('paragraph')
roll:onGotoViewRel(-1)
check(page>=1,'backward boundary delegates page control safely')
instance:stop()
doc.getWordFromPosition = nil

-- The PDF fallback also uses paragraph anchors without touching XPointers.
pdfdoc.getTextFromPositions = original_pdf_text
pdf:setStepMode('paragraph')
pdf:start()
check(pdf.enabled and #pdf.paragraph_starts>=1,
    'PDF paragraph fallback produces at least one safe focus unit')
local pdf_para_first=pdf:getSlot()
check(pdf_para_first and pdf_para_first.h>0,
    'PDF paragraph highlight has bounded geometry')
pdf:stop()
pdf:setStepMode('line')
check(pdfpaging.onGotoViewRel==pdfturn,
    'paragraph PDF controls are restored when plugin stops')

-- Freeform Focus must work with *no text backend at all*. No extraction,
-- transforms or OCR should be invoked on image-only PDF pages.
pdfpaging.current_page = 1
pdfdoc.getTextFromPositions = function()
    error('Freeform mode must not query text positions')
end
pdf:setStyle('freeform')
pdf:setFreeformHeight(25)
pdf:setFreeformOverlap(0) -- Isolate legacy geometry from earlier menu tests.
check(pdf.freeform_overlap==0 and stored.freeform_overlap==0,
    'Freeform zero overlap is saved and retains legacy movement')
check(pdf.freeform_height==25 and stored.freeform_height==25,
    'Freeform height setting is separate and persists')
pdf:setSpotlightMaskColor('black')
pdf:start()
check(pdf.enabled and #pdf.lines==0 and pdfpaging.onGotoViewRel~=pdfturn,
    'image-only PDF Freeform starts and intercepts clicker without text')
local one=pdf:getSlot()
check(one and one.h==225 and one.y==0 and one.w==600,
    'Freeform starts with quarter-page clear band')
local blackout={}
local freeform_bb={paintRect=function(_,x,y,w,h,color)
    blackout[#blackout+1]={x=x,y=y,w=w,h=h,color=color}
end}
pdf:paintTo(freeform_bb,0,0)
check(#blackout==1 and blackout[1].y==225 and blackout[1].h==675
    and blackout[1].color=='BLACK',
    'Freeform masks below the clear first band even with zero text')
pdfpaging:onGotoViewRel(1)
check(pdf.freeform_index==2 and pdf:getSlot().y==225,
    'clicker advances one geometric window')
blackout={}
pdf:paintTo(freeform_bb,0,0)
check(#blackout==2 and blackout[1].h==225
    and blackout[2].y==450 and blackout[2].h==450,
    'middle window masks above and below without touching clear band')
pdfpaging:onGotoViewRel(-1)
check(pdf.freeform_index==1,
    'reverse clicker returns to previous geometric window')
for _=1,3 do pdfpaging:onGotoViewRel(1) end
check(pdf.freeform_index==4 and pdf:getSlot().y==675,
    'last Freeform window reaches bottom without missing text/image pixels')
pdfpaging:onGotoViewRel(1)
check(pdfpaging.current_page==2 and pdf.freeform_index==1,
    'Freeform automatically turns the real page at bottom')
pdf:onPageUpdate()
check(pdf.freeform_index==1 and pdf.enabled,
    'delayed page updates do not reset or stop Freeform')
pdfpaging:onGotoViewRel(-1)
check(pdfpaging.current_page==1 and pdf.freeform_index==4,
    'reverse page-turn begins at final Freeform window')
pdf:setFreeformHeight(50)
check(pdf:getSlot().h==450 and pdf.freeform_index==2,
    'changing window height preserves approximate reading position')
pdf:setSpotlightMaskColor('white')
blackout={}
pdf:paintTo(freeform_bb,0,0)
check(#blackout>0 and blackout[1].color=='WHITE',
    'Freeform reuses Spotlight white mask preference')
pdf.spotlight_image_path='/test/koreader/screensavers/forest.png'
pdf:setSpotlightMaskColor('image')
local freeform_image_blits=0
local image_freeform={
    paintRect=function() end,
    pmulalphablitFrom=function() freeform_image_blits=freeform_image_blits+1 end,
}
pdf:paintTo(image_freeform,0,0)
check(freeform_image_blits>0,
    'Freeform reuses alpha-aware custom image masks')
pdf:setSpotlightMaskColor('black')
pdfview.footer_visible = true
pdfview.footer={getHeight=function() return 80 end}
pdf:onReaderFooterVisibilityChange()
check(pdf:getSlot().area.h==820 and pdf:getSlot().y+pdf:getSlot().h<=820,
    'Freeform avoids reader footer after a layout change')
pdfview.footer_visible = false
pdf:onScreenResize()
check(pdf:getSlot().area.h==900,
    'Freeform restores full viewport after screen resizing')
pdf:stop()
check(pdfpaging.onGotoViewRel==pdfturn,
    'stopping Freeform restores original page-turn implementation')

-- A PDF without even an exposed getTextFromPositions API is still accepted
-- for Freeform; selecting a text mode fails safely without trapping buttons.
pdfdoc.getTextFromPositions=nil
check(pdf:isSupported(),'PDF Freeform requires no text extraction API')
pdf:setStyle('freeform')
pdf:start()
check(pdf.enabled,'Freeform works without any PDF text API')
pdf:onPageUpdate()
check(pdf.enabled,'image-only Freeform page update is harmless')
local show_before=manager.show
local freeform_warning=0
manager.show=function() freeform_warning=freeform_warning+1 end
pdf:setStyle('color')
manager.show=show_before
check(not pdf.enabled and freeform_warning==1
    and pdfpaging.onGotoViewRel==pdfturn,
    'switching to unavailable text focus stops safely and restores controls')
pdfdoc.getTextFromPositions=original_pdf_text
pdf:start()
check(pdf.enabled and #pdf.lines==2,
    'normal PDF text focusing works again after leaving Freeform')
pdf:setStyle('freeform')
check(pdf.enabled and #pdf.lines==0,
    'switching live from text focus to Freeform clears text dependency')
pdf:setStyle('color')
check(pdf.enabled and #pdf.lines==2,
    'switching live back to text focus rebuilds text geometry')
pdf:stop()
check(pdfpaging.onGotoViewRel==pdfturn,
    'existing PDF turning restored after live mode changes')

-- Simulate the ReaderView handing the plugin an already-painted viewport.
-- Distinct row markers let us verify that native pixels actually move,
-- including where the source and centered bands overlap.
local screen = require('device').screen
local screen_height, screen_width = screen.getHeight, screen.getWidth
local blitbuffer = require('ffi/blitbuffer')
local strip_frees = 0
local function buffer(rows)
    return {
        rows = rows or {},
        getType = function() return 'RGB32' end,
        blitFrom = function(self, src, x, y, source_x, source_y, width, height)
            assert(x == source_x, 'native row copy preserves horizontal position in this layout')
            for j=0,height-1 do self.rows[y+j] = src.rows[source_y+j] end
        end,
        paintRect = function(self, x, y, w, h, color)
            for j=y,y+h-1 do self.rows[j] = color end
        end,
        pmulalphablitFrom = function(self, image, x, y, _, _, w, h)
            self:paintRect(x, y, w, h, 'IMAGE')
        end,
        free = function() strip_frees = strip_frees + 1 end,
    }
end
blitbuffer.new = function() return buffer() end

local centered_page = 1
local layout = {
    {{28,1}, {375,2}, {410,2}, {445,2}},
    {{34,2}, {69,2}, {200,3}},
    {{4,4,2}, {111,4,2}, {218,4,2}, {325,4,2}, {432,4,2},
     {539,4,2}, {646,4,2}, {753,4,2}, {860,4,2}},
}
local reflowed, pages_turned = false, 0
local centered_doc = setmetatable({}, {__index=doc})
function centered_doc:getCurrentPage() return centered_page end
function centered_doc:getTextFromPositions()
    local boxes = {}
    for i, row in ipairs(layout[centered_page]) do
        boxes[i] = {x=50,y=row[1],w=370,h=reflowed and 36 or 24}
    end
    return {sboxes=boxes}
end
function centered_doc:getWordFromPosition(pos)
    for _, row in ipairs(layout[centered_page]) do
        if pos.y >= row[1] and pos.y < row[1] + (reflowed and 36 or 24) then
            local xp = ('/body/DocFragment[%d]/body/p[%d]/text().%d')
                :format(row[3] or 1, row[2], row[1])
            return {pos0=xp, pos1=xp, word='text', sbox={x=50,y=row[1],w=40,h=24}}
        end
    end
end
function centered_doc:getScreenPositionFromXPointer(xp)
    if reflowed and xp:find('/p%[2%]') then return 290, 60 end
end

local centered_view = {dialog={}, view_mode='page', footer_visible=false,
    registerViewModule=view.registerViewModule}
local centered_roll = {}
local centered_ui = {document=centered_doc, rolling=centered_roll, menu=ui.menu}
local centered = setmetatable({ui=centered_ui, view=centered_view}, {__index=P})
local function nativeTurn(_, direction)
    local next_page = math.max(1, math.min(3, centered_page + direction))
    if next_page ~= centered_page then
        centered_page, pages_turned = next_page, pages_turned + 1
        centered:onPageUpdate()
    end
    return true
end
centered_roll.onGotoViewRel = nativeTurn
stored.center_focused_paragraph = nil
centered:init()
centered:onReaderReady()
local toggle = menu_items.focusreader.sub_item_table[3].sub_item_table[2].sub_item_table[4]
check(toggle.enabled_func() and not toggle.checked_func() and not centered.center_focused_paragraph,
    'centering is available in paged EPUB and defaults off')
centered:setStyle('mask')
centered:setSpotlightLayout('window')
centered:setSpotlightMaskColor('black')
centered:setStepMode('paragraph')
centered:start()

local function paintPage()
    local rows = {}
    for j=0,screen:getHeight()-1 do rows[j] = 'native row ' .. j end
    local canvas = buffer(rows)
    centered:paintTo(canvas, 0, 0)
    return canvas.rows
end

local plain_rows = paintPage()
check(plain_rows[28] == 'native row 28' and plain_rows[450] == 'BLACK',
    'default window leaves glyphs at the original reading position')
toggle.callback()
local short_section = centered:getCenteredSection()
local short_rows = paintPage()
check(toggle.checked_func() and stored.center_focused_paragraph == true
    and centered_page == 1 and pages_turned == 0,
    'enabling from the menu persists immediately without changing reader position')
check(short_rows[28] == 'BLACK' and short_rows[short_section.y+2] == 'native row 28'
    and short_section.y + short_section.h/2 == 450 and strip_frees == 1,
    'short paragraph pixels move to the midpoint and the temporary buffer is freed')

centered_roll:onGotoViewRel(1)
local multi_section = centered:getCenteredSection()
local multi_rows = paintPage()
check(multi_section.y + multi_section.h/2 == 450 and multi_rows[multi_section.y+2] == 'native row 375'
    and multi_rows[multi_section.y+72] == 'native row 445',
    'next paragraph is centered with its original line spacing and pixels intact')
check(dirty[#dirty].mode == 'ui' and dirty[#dirty].region.y == multi_section.y
    and dirty[#dirty].region.h == multi_section.h,
    'replacing the reading band requests one nonflashing regional refresh')
centered_roll:onGotoViewRel(-1)
check(centered:getCenteredSection().source_y == short_section.source_y
    and dirty[#dirty].region.h == multi_section.h and paintPage()[multi_section.y] == 'BLACK',
    'going backward clears the larger old band and restores the short paragraph')

centered_roll:onGotoViewRel(1)
centered:setSpotlightMaskColor('white')
check(paintPage()[0] == 'WHITE' and paintPage()[multi_section.y+2] == 'native row 375',
    'white mask preserves the native text and its page background')
centered.spotlight_image_path = '/test/koreader/screensavers/forest.png'
centered:setSpotlightMaskColor('image')
check(paintPage()[0] == 'IMAGE' and paintPage()[multi_section.y+2] == 'native row 375',
    'custom mask preserves a legible centered native text band')
centered:setSpotlightMaskColor('black')
centered_roll:onGotoViewRel(1)
local carry = centered:getCenteredSection()
check(centered_page == 2 and carry.y+carry.h/2 <= 450
    and paintPage()[carry.y+2] == 'native row 34'
    and centered.lines[carry.first].paragraph_key == '/body/DocFragment[1]/body/p[2]',
    'a paragraph continuation appears centered on the next native page')
centered_roll:onGotoViewRel(-1)
check(centered_page == 1 and centered:getCenteredSection().source_y == multi_section.source_y,
    'backward across a page boundary returns to the preceding paragraph section')

toggle.callback()
check(not stored.center_focused_paragraph and paintPage()[375] == 'native row 375'
    and dirty[#dirty].mode == 'ui' and dirty[#dirty].region == nil,
    'disabling restores the original reading window on the same page')
toggle.callback()
centered:setSpotlightLayout('guide')
check(not centered:getCenteredSection() and paintPage()[375] == 'native row 375',
    'Reading Guide stays in place while the centered preference is on')
centered:setSpotlightLayout('window')
centered:setStepMode('line')
check(not centered:getCenteredSection() and dirty[#dirty].region == nil,
    'switching to line focus clears the centered presentation')
centered:setStepMode('paragraph')
centered:setStyle('color')
check(not centered:getCenteredSection(), 'Highlight Focus ignores the centered preference')
centered:setWordMode(true)
check(not centered:getCenteredSection(), 'word focus ignores the centered preference')
centered:setWordMode(false)
centered:setStyle('freeform')
check(not centered:getCenteredSection(), 'Freeform Focus ignores the centered preference')
centered:setStyle('mask')
centered:setStepMode('paragraph')
centered_view.view_mode = 'scroll'
check(not toggle.enabled_func() and not centered:getCenteredSection(),
    'scroll mode gracefully uses standard Spotlight')
centered_view.view_mode = 'page'

centered_roll:onGotoViewRel(1)
centered_roll:onGotoViewRel(1)
centered_roll:onGotoViewRel(1)
centered_roll:onGotoViewRel(1)
local tall_first = centered:getCenteredSection()
check(centered_page == 3 and tall_first.first == 1 and tall_first.last == 8
    and centered.lines[1].paragraph_key == '/body/DocFragment[2]/body/p[4]',
    'a chapter transition starts the first section of a viewport-sized paragraph')
centered_roll:onGotoViewRel(1)
local tall_last = centered:getCenteredSection()
check(centered_page == 3 and tall_last.first == 9 and tall_last.last == 9
    and paintPage()[tall_last.y+2] == 'native row 860',
    'oversized paragraph shows its final native line before the next page')
centered_roll:onGotoViewRel(-1)
check(centered:getCenteredSection().last == 8, 'backward reads the preceding tall section')
centered_roll:onGotoViewRel(-1)
check(centered_page == 2 and centered:getCenteredSection().first == 3,
    'backward across chapters shows the previous last paragraph')
centered_roll:onGotoViewRel(1)
centered_roll:onGotoViewRel(1)
centered_roll:onGotoViewRel(1)
check(centered_page == 3 and centered:getCenteredSection().first == 9,
    'advancing at the end of the book keeps its last centered text')
centered:stop()
check(centered_page == 3 and centered_roll.onGotoViewRel == nativeTurn
    and paintPage()[860] == 'native row 860',
    'exiting restores the native page layout and controls at the latest progress')

centered_page = 1
centered:start()
centered_roll:onGotoViewRel(1)
screen.getHeight = function() return 500 end
screen.getWidth = function() return 800 end
centered_view.footer_visible = true
centered_view.footer = {getHeight=function() return 40 end}
layout[1] = {{24,1}, {72,1}, {270,2}, {312,2}}
reflowed = true
centered:onDocumentRerendered()
local resized = centered:getCenteredSection()
check(centered_page == 1 and resized.w == 800 and resized.y+resized.h/2 == 230
    and resized.first == 3 and resized.last == 4
    and paintPage()[resized.y+2] == 'native row 270',
    'rotation and larger fonts remeasure the same paragraph above the footer')
centered:stop()
check(centered_page == 1 and paintPage()[270] == 'native row 270',
    'stopping on the starting page restores the original native position')
local reopened = setmetatable({ui=centered_ui, view=centered_view}, {__index=P})
reopened:init()
check(reopened.center_focused_paragraph and not reopened.enabled,
    'preference reloads without auto-starting a reading session')
pdf.center_focused_paragraph = true
check(not pdf:canCenterParagraphs() and not pdf:usesCenteredParagraphs(),
    'PDF keeps existing focus behavior even with the EPUB preference saved')
screen.getHeight, screen.getWidth = screen_height, screen_width

-- Automatic Highlight reuses reader navigation and owns a single timer.
local auto_page = 1
local auto_turns = 0
local auto_doc = setmetatable({
    getCurrentPage=function() return auto_page end,
}, {__index=doc})
local auto_original = function(_, direction)
    auto_turns = auto_turns + 1
    auto_page = math.max(1, math.min(3, auto_page + direction))
    return true
end
local auto_roll = {onGotoViewRel=auto_original}
local auto_ui = {document=auto_doc, rolling=auto_roll, highlight=ui.highlight, menu=ui.menu}
local auto = setmetatable({ui=auto_ui,view=view}, {__index=P})
auto:init()
auto:onReaderReady()
auto:setStyle('color')
auto:setWordMode(false)
auto:setStepMode('line')
auto:setLines(1)
top_widget = auto_ui
local auto_menu = menu_items.focusreader.sub_item_table[3].sub_item_table[1].sub_item_table[7]
local play, speed = auto_menu.sub_item_table[1], auto_menu.sub_item_table[2]
local auto_action = registered_actions.focusreader_auto_highlight
check(auto_action and auto_action.reader and auto_action.event=='FocusReaderToggleAutoHighlight',
    'automatic highlight exposes a reader gesture action')
check(auto_menu.text=='Automatic highlight' and not play.enabled_func()
    and auto.auto_highlight_seconds==5 and not next(scheduled),
    'playback is off by default and can be configured before Focus Reader starts')
speed.callback()
check(spin_widget.value==5 and spin_widget.value_min==0.5
    and spin_widget.value_max==120 and spin_widget.value_step==0.5,
    'the speed picker offers half-second intervals from 0.5 to 120 seconds')
spin_widget.value = 2.5
spin_widget.callback(spin_widget)
check(stored.auto_highlight_seconds==2.5 and not next(scheduled),
    'changing speed persists without starting automatic playback')
auto:start()
check(play.enabled_func() and not next(scheduled), 'starting Highlight Focus alone remains manual')
play.callback()
check(not next(scheduled), 'menu playback waits for TouchMenu to dismiss')
flushNextTicks()
local task = auto.auto_highlight_task
check(play.text_func()=='Pause automatic highlight' and scheduled[task]==2.5 and auto.index==1,
    'play waits one full interval before advancing')

local function tick()
    assert(scheduled[task], 'expected a scheduled highlight tick')
    scheduled[task] = nil
    task()
end
tick()
check(auto.index==2 and scheduled[task]==2.5 and dirty[#dirty].mode=='ui',
    'a timer tick advances exactly one line through the normal redraw path')
top_widget = {}
tick()
check(auto.index==2 and scheduled[task]==2.5, 'a visible menu prevents reading progress')
top_widget = auto_ui
tick()
check(auto.index==3, 'returning to the book advances one step without catching up')
auto_roll:onGotoViewRel(-1)
check(auto.index==2 and scheduled[task]==2.5, 'a manual turn resets the active interval')
auto:setAutoHighlightSeconds(8)
check(scheduled[task]==8 and stored.auto_highlight_seconds==8,
    'changing speed during playback replaces the pending timer')

auto.index = #auto.lines
tick()
check(auto_page==2 and auto.index==1 and scheduled[task]==8,
    'automatic advance uses the original forward page turn at the last line')
auto:setStepMode('paragraph')
auto_doc.getWordFromPosition = function(_, pos)
    local paragraph = pos.y < 345 and 1 or 2
    return {pos0=('/body/DocFragment[1]/body/p[%d]/text().5'):format(paragraph)}
end
auto:onPageUpdate()
tick()
check(auto_page==2 and auto.index==7, 'whole paragraph playback uses the existing paragraph anchors')
auto_page = 3
auto:onPageUpdate()
auto.index = 7
local before_end = auto_turns
tick()
check(auto_turns==before_end+1 and not next(scheduled) and auto.enabled
    and play.text_func()=='Play automatic highlight', 'book end stops automatic turns and keeps the focus session')
task()
check(auto_turns==before_end+1, 'an already-paused timer cannot make another page turn')

auto:onFocusReaderToggleAutoHighlight()
auto:onFocusReaderToggleAutoHighlight()
check(not next(scheduled) and auto.enabled, 'the gesture pauses without stopping Highlight Focus')
auto:onFocusReaderToggleAutoHighlight()
auto:onSuspend()
check(not next(scheduled) and auto.enabled, 'suspending cancels the timer and keeps the reading position')
auto:onFocusReaderToggleAutoHighlight()
auto:setStyle('mask')
check(not next(scheduled) and not play.enabled_func(), 'leaving Highlight Focus pauses playback')
auto:setStyle('color')
check(not next(scheduled), 'returning to Highlight Focus requires explicit play')
auto:onFocusReaderToggleAutoHighlight()
auto:stop()
check(not next(scheduled) and auto_roll.onGotoViewRel==auto_original,
    'stopping Focus Reader cancels the timer and restores page controls')
auto:start()
auto:onFocusReaderToggleAutoHighlight()
auto:onCloseDocument()
check(not next(scheduled) and not auto.enabled, 'closing the book cancels playback')
local next_book = setmetatable({ui=auto_ui,view=view}, {__index=P})
next_book:init()
check(next_book.auto_highlight_seconds==8 and not next_book.auto_highlight_playing,
    'reopening restores the speed but starts paused')
print('PASS: '..checks..' mocked KOReader checks')
