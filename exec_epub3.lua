module(...,package.seeall)
local eb = require("exec_epub")
local dom = require("luaxml-domobject")

local ext = "xhtml"
local outputdir = nil
local input     = nil
function prepare(params)
	local basedir = params.input.."-".. params.format
  local outputdir_name="OEBPS"
	outputdir= basedir.."/"..outputdir_name
  input = params.input 
  params.ext = ext
  params.tex4ht_sty_par = params.tex4ht_sty_par .. ",html5"
  params.packages = params.packages .. string.format("\\Configure{ext}{%s}",ext)
	return eb.prepare(params)
end

function run(out,params)
	return eb.run(out, params)
end


local function makeTOC(document)
  local template = [[
<!DOCTYPE html>
<html xmlns="http://www.w3.org/1999/xhtml" 
 xmlns:epub="http://www.idpf.org/2007/ops"
>
<head><title>TOC</title></head>
<body>
<nav id="pub-toc" epub:type="toc">
 <h1>Table of contents</h1>
 <ol class="toc" hidden="hidden">
  <li>
   <a href="${document}">Document</a>
  </li>
 </ol>
</nav>
</body>
</html>
]] % {document=document}
  return template
end

local function add_media_overlays(content)
  local add_meta = function(package, attributes, text)
    local meta = package:create_element("meta",attributes)
    local dur_el = meta:create_text_node(text)
    meta:add_child_node(dur_el)
    package:add_child_node(meta)
  end
  -- calculate total audio time
  local calc_times = function(times)
    local time = 0
    for _, curr in ipairs(times) do
      -- smil file contains timestamps in the H:M:S format, we need to parse it
      local hours, minutes, seconds = curr:match("(%d+):(%d+):(%d+)")
      time = time +  os.time({year=1970, day=1, month=1, hour=hours, min=minutes, sec=seconds})
    end
    return os.date("%H:%M:%S",time)
  end
  local opfdom = dom.parse(content)
  local items = opfdom:query_selector("manifest item")
  local ref = {}
  local times = {}
  local package = opfdom:query_selector("metadata")[1]
  -- we must read all smil files and find references to html files
  -- it is necessary to add media-overlay attribute to the referenced items
  for _, item in ipairs(items) do
    local href = item:get_attribute("href")
    ref[href] = item
    -- we must read audio length from the smil file and add it as a <meta> property
    if href:match("smil$") then
      local f = io.open(outputdir .. "/" .. href, "r")
      if not f then break end
      local smil = f:read("*all")
      f:close()
      local smildom = dom.parse(smil)
      local audios = smildom:query_selector("audio")
      local last = audios[#audios]
      -- add audio duration to the metadata section
      if last then
        local duration = last:get_attribute("clipend")
        if duration then
          -- todo: calculate total audio length
          table.insert(times, duration)
          local audio_id = item:get_attribute("id")
          add_meta(package, {property="media:duration", refines="#"..audio_id}, duration)
        end
      end

      -- add the media-overlay attribute
      local textref = smil:match('epub:textref="(.-)"')
      local id = item:get_attribute("id")
      local referenced = ref[textref]
      if referenced then
        referenced:set_attribute("media-overlay", id)
      end
    end
  end
  -- calculate length of all media overlay audio files
  if #times > 0 then
    local totaltime = calc_times(times)
    add_meta(package,{property="media:duration"}, totaltime)
  end
  local serialized = opfdom:serialize()
  return serialized
end


local function remove_spurious_TOC_elements(tocdom)
  local function count_child_elements(el)
    -- count children elements of the current element
    local  count = 0
    for _, curr_el in ipairs(el:get_children()) do
      if curr_el:is_element() then count = count + 1 end
    end
    return count
  end
  -- modify the TOC to comply to epubcheck tests
  -- add a blank <li> to empty <ol>
  for _, el in ipairs(tocdom:query_selector("ol")) do
    if count_child_elements(el) == 0 then 
      el:remove_node()
      -- local newli = el:create_element("li")
      -- local newspan = newli:create_element("span")
      -- newli:add_child_node(newspan)
      -- el:add_child_node(newli)
    end
  end
  -- place child elements of the <li> elements to a <span>, epubcheck reports 
  -- error for text nodes that are direct child of <li>
  for _, el in ipairs(tocdom:query_selector("li")) do
    for _, child in ipairs(el._children) do
      if child:is_text() then 
        local new_el = el:create_element("span")
        print("replace child", child._text)
        new_el:add_child_node(child:copy_node())
        child:replace_node(new_el)
      end
    end
  end
  return tocdom

end
local function cleanTOC(content)
  -- remove spurious empty elements from the TOC, to make epubcheck happy
  -- find the file with TOC ("properties" attribute set to "nav"
  local opfdom = dom.parse(content)
  for _,item in ipairs(opfdom:query_selector("item")) do
    local properties = item:get_attribute("properties") or ""
    if properties:match("nav") then
      local filename =  item:get_attribute("href")
      if filename then
        filename = outputdir .. "/" ..  filename
        local f = io.open(filename, "r")
        local t = f:read("*all")
        f:close()
        local tocdom = dom.parse(t)
        tocdom = remove_spurious_TOC_elements(tocdom)
        f = io.open(filename,"w")
        f:write(tocdom:serialize())
        f:close()
      end
    end
  end


end


local function cleanOPF()
  -- in epub3, there must be table of contents
	-- if there is no toc in the document, we must add generic one
	local opf =  "content.opf"
	local f = io.open(opf,"r")
	if not f then 
    print("Cannot open "..opf .. " for toc searching")
		return nil
  end
  local content = f:read("*all")
	f:close()
	if content:find "properties[%s]*=[%s]*\"[^\"]*nav" then
    print "TOC nav found"
    cleanTOC(content)
  else
    print "no TOC, using generic one"
    local inputfile = input .. "." .. ext
    print("Main file name", inputfile)
		-- write toc file
    local toc_name = "generic_toc" .."."..ext
		local f = io.open(outputdir .. "/" .. toc_name, "w")
		f:write(makeTOC(inputfile))
		f:close()
		-- add toc file to the conten.opf
		content = content:gsub("<manifest>","<manifest>\n<item id='htmltoc'" ..
		  " properties=\"nav\" media-type=\"application/xhtml+xml\" href=\""..
			toc_name .."\" />\n")
    content = content:gsub("<spine([^>]*)>", "<spine%1>\n<itemref idref=\"htmltoc\" linear=\"no\"/>\n")
    -- remove empty guide element
  end
  -- content = content:gsub("<guide>%s*</guide>","")
  content = eb.remove_empty_guide(content)

  content = add_media_overlays(content)
  f = io.open(outputdir .. "/" ..opf,"w")
  f:write(content)
  f:close()
  --makeTOC(inputfile)
end



function writeContainer()			
	--local ret =  eb.writeContainer()
  print "write container"
	eb.make_opf()
	cleanOPF()
	local ret = eb.pack_container()
	return ret
end

function clean()
	return eb.clean()
end
