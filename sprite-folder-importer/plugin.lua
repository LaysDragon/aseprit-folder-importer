local PLUGIN_ID = "folder_importer_v1"
local MENU_GROUP_ID = "folder_importer_group"
local MENU_TITLE = "Folder Importer"

local CANDIDATE_MENU_GROUPS = {
  "file_scripts",
  "file_import",
  "file",
}

local IMAGE_EXTENSIONS = {
  png = true,
  jpg = true,
  jpeg = true,
  bmp = true,
  gif = true,
  webp = true,
}

local SAVE_GUARD = false

local function toForwardSlashes(path)
  return (path or ""):gsub("\\", "/")
end

local function normalize(path)
  if not path or path == "" then
    return ""
  end
  return app.fs.normalizePath(path)
end

local function encodeValue(text)
  local s = tostring(text or "")
  s = s:gsub("%%", "%%25")
  s = s:gsub("\r", "%%0D")
  s = s:gsub("\n", "%%0A")
  return s
end

local function decodeValue(text)
  local s = tostring(text or "")
  s = s:gsub("%%0A", "\n")
  s = s:gsub("%%0D", "\r")
  s = s:gsub("%%25", "%%")
  return s
end

local function splitLines(text)
  local lines = {}
  for line in tostring(text or ""):gmatch("([^\n]*)\n?") do
    if line == "" and #lines > 0 and lines[#lines] == "" then
      break
    end
    table.insert(lines, line)
  end
  return lines
end

local function serializeMeta(meta)
  local lines = {
    PLUGIN_ID,
    "root=" .. encodeValue(meta.rootPath or ""),
    "work=" .. encodeValue(meta.workFile or ""),
  }
  return table.concat(lines, "\n")
end

local function parseMeta(sprite)
  if not sprite or not sprite.data or sprite.data == "" then
    return nil
  end

  local lines = splitLines(sprite.data)
  if #lines < 1 or lines[1] ~= PLUGIN_ID then
    return nil
  end

  local result = {
    rootPath = "",
    workFile = "",
  }

  for i = 2, #lines do
    local key, value = lines[i]:match("^([%w_]+)=(.*)$")
    if key then
      if key == "root" then
        result.rootPath = decodeValue(value)
      elseif key == "work" then
        result.workFile = decodeValue(value)
      end
    end
  end

  return result
end

local function isImageFile(path)
  local ext = app.fs.fileExtension(path):lower()
  return IMAGE_EXTENSIONS[ext] == true
end

local function pathPrefix(text)
  return toForwardSlashes(normalize(text)):lower()
end

local function startsWithPath(path, prefix)
  local p = pathPrefix(path)
  local r = pathPrefix(prefix)
  if r == "" then
    return true
  end
  return p == r or p:sub(1, #r + 1) == (r .. "/")
end

local function getParent(path)
  local parent = app.fs.filePath(path)
  if not parent or parent == "" or parent == path then
    return ""
  end
  return normalize(parent)
end

local function commonParent(paths)
  if #paths == 0 then
    return ""
  end

  local candidate = normalize(paths[1])
  while candidate ~= "" do
    local allMatch = true
    for _, p in ipairs(paths) do
      if not startsWithPath(p, candidate) then
        allMatch = false
        break
      end
    end
    if allMatch then
      return candidate
    end
    local nextCandidate = getParent(candidate)
    if nextCandidate == candidate then
      break
    end
    candidate = nextCandidate
  end

  return getParent(normalize(paths[1]))
end

local function makeRelative(path, root)
  local p = normalize(path)
  local r = normalize(root)
  if p == "" or r == "" then
    return app.fs.fileName(path)
  end

  local pForward = toForwardSlashes(p)
  local rForward = toForwardSlashes(r)

  local pCmp = pForward:lower()
  local rCmp = rForward:lower()
  if pCmp == rCmp then
    return ""
  end

  local prefix = rCmp .. "/"
  if pCmp:sub(1, #prefix) == prefix then
    return pForward:sub(#rForward + 2)
  end

  return app.fs.fileName(path)
end

local function ensureDirectory(path)
  if path == "" then
    return false
  end
  if app.fs.isDirectory(path) then
    return true
  end
  return app.fs.makeAllDirectories(path)
end

local function gatherImagesRecursive(dir, out)
  local files = app.fs.listFiles(dir)
  table.sort(files)

  for _, name in ipairs(files) do
    local fullPath = app.fs.joinPath(dir, name)
    if app.fs.isDirectory(fullPath) then
      gatherImagesRecursive(fullPath, out)
    elseif app.fs.isFile(fullPath) and isImageFile(fullPath) then
      table.insert(out, normalize(fullPath))
    end
  end
end

local function uniqueRelativePath(relPath, used)
  local rel = toForwardSlashes(relPath)
  if used[rel] == nil then
    used[rel] = 1
    return rel
  end

  local title = app.fs.filePathAndTitle(rel)
  local ext = app.fs.fileExtension(rel)

  local index = used[rel] + 1
  while true do
    local candidate = string.format("%s_%d.%s", title, index, ext)
    if used[candidate] == nil then
      used[rel] = index
      used[candidate] = 1
      return candidate
    end
    index = index + 1
  end
end

local function uniqueSliceName(name, used)
  if used[name] == nil then
    used[name] = 1
    return name
  end
  local index = used[name] + 1
  while true do
    local candidate = string.format("%s_%d", name, index)
    if used[candidate] == nil then
      used[name] = index
      used[candidate] = 1
      return candidate
    end
    index = index + 1
  end
end

local function collectEntries(selectedDirs)
  local roots = {}
  for _, dir in ipairs(selectedDirs) do
    local norm = normalize(dir)
    if norm ~= "" and app.fs.isDirectory(norm) then
      table.insert(roots, norm)
    end
  end

  if #roots == 0 then
    return nil, "No valid folders selected."
  end

  local relativeRoot = roots[1]
  if #roots > 1 then
    relativeRoot = commonParent(roots)
  end

  local files = {}
  for _, dir in ipairs(roots) do
    gatherImagesRecursive(dir, files)
  end

  table.sort(files)

  local usedRel = {}
  local usedSliceNames = {}
  local entries = {}

  for _, fullPath in ipairs(files) do
    local relBase = (#roots == 1) and roots[1] or relativeRoot
    local relPath = makeRelative(fullPath, relBase)
    if relPath ~= "" then
      relPath = uniqueRelativePath(relPath, usedRel)
      local sliceName = app.fs.filePathAndTitle(relPath)
      sliceName = toForwardSlashes(sliceName)
      sliceName = uniqueSliceName(sliceName, usedSliceNames)

      local image = Image { fromFile = fullPath }
      if image then
        table.insert(entries, {
          fullPath = fullPath,
          relPath = toForwardSlashes(relPath),
          sliceName = sliceName,
          image = image,
          w = image.width,
          h = image.height,
        })
      end
    end
  end

  if #entries == 0 then
    return nil, "No supported images found in selected folders."
  end

  return {
    rootPath = relativeRoot,
    roots = roots,
    entries = entries,
  }
end

local function buildPlacements(entries)
  local count = #entries
  local cols = math.max(1, math.ceil(math.sqrt(count)))
  local gap = 1

  local placements = {}
  local x = 0
  local y = 0
  local col = 0
  local rowHeight = 0
  local canvasW = 0

  for i, entry in ipairs(entries) do
    if col >= cols then
      canvasW = math.max(canvasW, math.max(0, x - gap))
      x = 0
      y = y + rowHeight + gap
      rowHeight = 0
      col = 0
    end

    table.insert(placements, {
      entry = entry,
      x = x,
      y = y,
      w = entry.w,
      h = entry.h,
    })

    x = x + entry.w + gap
    rowHeight = math.max(rowHeight, entry.h)
    col = col + 1

    if i == count then
      canvasW = math.max(canvasW, math.max(0, x - gap))
      y = y + rowHeight
    end
  end

  local canvasH = math.max(1, y)
  canvasW = math.max(1, canvasW)

  return {
    width = canvasW,
    height = canvasH,
    placements = placements,
  }
end

local function defaultWorkFile(rootPath)
  local base = rootPath
  if base == "" then
    base = app.fs.userDocsPath
  end
  return app.fs.joinPath(base, "_folder_importer_work.aseprite")
end

local function importFromFolders(selectedDirs)
  local result, err = collectEntries(selectedDirs)
  if not result then
    app.alert {
      title = MENU_TITLE,
      text = err,
    }
    return
  end

  local layout = buildPlacements(result.entries)
  local sprite = Sprite(layout.width, layout.height, ColorMode.RGB)
  local layer = sprite.layers[1]
  layer.name = "Imported"

  local cel = sprite:newCel(layer, 1)
  local canvas = cel.image

  for _, item in ipairs(layout.placements) do
    canvas:drawImage(item.entry.image, Point(item.x, item.y))

    local slice = sprite:newSlice(Rectangle(item.x, item.y, item.w, item.h))
    slice.name = item.entry.sliceName
    slice.data = item.entry.relPath
  end

  sprite.data = serializeMeta {
    rootPath = result.rootPath,
    workFile = defaultWorkFile(result.rootPath),
  }

  app.sprite = sprite
  app.refresh()

  app.alert {
    title = MENU_TITLE,
    text = {
      string.format("Imported %d images.", #result.entries),
      string.format("Canvas: %dx%d", layout.width, layout.height),
      string.format("Export root: %s", result.rootPath),
    },
  }
end

local function extractOutputRootFromDialog(data, fallbackRoot)
  if data.use_original_root then
    if fallbackRoot and fallbackRoot ~= "" then
      return fallbackRoot
    end
    return nil
  end

  local pick = normalize(data.output_pick or "")
  if pick == "" then
    return nil
  end

  if app.fs.isDirectory(pick) then
    return pick
  end

  if app.fs.isFile(pick) then
    return app.fs.filePath(pick)
  end

  local parent = app.fs.filePath(pick)
  if parent and parent ~= "" then
    return parent
  end

  return nil
end

local function exportSlices(sprite, opts)
  local meta = parseMeta(sprite)
  if not meta then
    return false, "Active sprite is not a Folder Importer sprite."
  end

  local outputRoot = normalize(opts.outputRoot or meta.rootPath)
  if outputRoot == "" then
    return false, "Missing output root folder."
  end

  if not ensureDirectory(outputRoot) then
    return false, "Cannot create output root folder:\n" .. outputRoot
  end

  local rendered = Image(sprite)
  local exported = 0

  for _, slice in ipairs(sprite.slices) do
    local relPath = slice.data
    if not relPath or relPath == "" then
      relPath = (slice.name or "slice") .. ".png"
    end

    relPath = toForwardSlashes(relPath)
    local relForJoin = relPath:gsub("/", app.fs.pathSeparator)
    local target = app.fs.joinPath(outputRoot, relForJoin)

    local parent = app.fs.filePath(target)
    if parent and parent ~= "" and not ensureDirectory(parent) then
      return false, "Cannot create folder:\n" .. parent
    end

    local cropped = Image(rendered, slice.bounds)
    if cropped then
      cropped:saveAs(target)
      exported = exported + 1
    end
  end

  local workFile = normalize(opts.workFile or meta.workFile)
  if workFile == "" then
    workFile = defaultWorkFile(outputRoot)
  end

  meta.rootPath = outputRoot
  meta.workFile = workFile
  sprite.data = serializeMeta(meta)
  sprite:saveAs(workFile)

  return true, {
    exported = exported,
    outputRoot = outputRoot,
    workFile = workFile,
  }
end

local function openExportDialog()
  local sprite = app.sprite
  if not sprite then
    app.alert {
      title = MENU_TITLE,
      text = "No active sprite.",
    }
    return
  end

  local meta = parseMeta(sprite)
  if not meta then
    app.alert {
      title = MENU_TITLE,
      text = "Active sprite is not created by Folder Importer.",
    }
    return
  end

  local dlg
  dlg = Dialog { title = "Export Slices" }
  dlg:label {
    id = "root_info",
    label = "Original root",
    text = meta.rootPath,
  }
  dlg:check {
    id = "use_original_root",
    text = "Use original root",
    selected = true,
  }
  dlg:file {
    id = "output_pick",
    label = "Output pick",
    title = "Pick a file inside output folder (if not using original root)",
    open = true,
    entry = true,
  }
  dlg:newrow()
  dlg:button {
    text = "Export",
    onclick = function()
      local data = dlg.data
      local outputRoot = extractOutputRootFromDialog(data, meta.rootPath)
      if not outputRoot then
        app.alert {
          title = MENU_TITLE,
          text = "Please select output root (or enable 'Use original root').",
        }
        return
      end

      local ok, infoOrErr = exportSlices(sprite, {
        outputRoot = outputRoot,
      })

      if not ok then
        app.alert {
          title = MENU_TITLE,
          text = infoOrErr,
        }
        return
      end

      app.alert {
        title = MENU_TITLE,
        text = {
          string.format("Exported %d files.", infoOrErr.exported),
          string.format("Output root: %s", infoOrErr.outputRoot),
          string.format("Work file: %s", infoOrErr.workFile),
        },
      }

      dlg:close()
    end,
  }
  dlg:button {
    text = "Cancel",
    onclick = function()
      dlg:close()
    end,
  }
  dlg:show()
end

local function foldersToText(list)
  if #list == 0 then
    return "(none)"
  end

  local lines = {}
  for i, path in ipairs(list) do
    lines[#lines + 1] = string.format("%d) %s", i, path)
  end
  return table.concat(lines, "\n")
end

local function openImportDialog(plugin)
  local selected = {}

  if type(plugin.preferences.lastFolders) == "table" then
    for _, p in ipairs(plugin.preferences.lastFolders) do
      if type(p) == "string" and p ~= "" and app.fs.isDirectory(p) then
        table.insert(selected, normalize(p))
      end
    end
  end

  local function addFolder(rawPath)
    local path = normalize(rawPath)
    if path == "" then
      return false, "Pick a file or folder first."
    end

    local dir = path
    if app.fs.isFile(path) then
      dir = app.fs.filePath(path)
    end

    if not app.fs.isDirectory(dir) then
      return false, "Not a valid folder path."
    end

    dir = normalize(dir)
    for _, p in ipairs(selected) do
      if pathPrefix(p) == pathPrefix(dir) then
        return false, "Folder already added."
      end
    end

    table.insert(selected, dir)
    return true
  end

  local dlg
  local function refresh()
    dlg:modify {
      id = "folders",
      text = foldersToText(selected),
    }
  end

  dlg = Dialog { title = "Import Folders As Slices" }
  dlg:label {
    id = "hint",
    label = "How to pick",
    text = "Use file picker to choose any file inside target folder, then click Add.",
  }
  dlg:file {
    id = "pick_file",
    label = "Pick",
    title = "Pick a file inside the folder you want to add",
    open = true,
    entry = true,
  }
  dlg:newrow()
  dlg:label {
    id = "folders",
    label = "Selected",
    text = foldersToText(selected),
  }
  dlg:newrow()
  dlg:button {
    text = "Add",
    onclick = function()
      local ok, msg = addFolder(dlg.data.pick_file)
      if not ok then
        app.alert {
          title = MENU_TITLE,
          text = msg,
        }
      end
      refresh()
    end,
  }
  dlg:button {
    text = "Remove Last",
    onclick = function()
      if #selected > 0 then
        table.remove(selected, #selected)
      end
      refresh()
    end,
  }
  dlg:button {
    text = "Clear",
    onclick = function()
      selected = {}
      refresh()
    end,
  }
  dlg:newrow()
  dlg:button {
    text = "Import",
    onclick = function()
      if #selected == 0 then
        app.alert {
          title = MENU_TITLE,
          text = "No folders selected.",
        }
        return
      end

      plugin.preferences.lastFolders = selected
      dlg:close()
      importFromFolders(selected)
    end,
  }
  dlg:button {
    text = "Cancel",
    onclick = function()
      dlg:close()
    end,
  }

  dlg:show()
end

local function safeNewMenuGroup(plugin)
  for _, parentGroup in ipairs(CANDIDATE_MENU_GROUPS) do
    local ok = pcall(function()
      plugin:newMenuGroup {
        id = MENU_GROUP_ID,
        title = MENU_TITLE,
        group = parentGroup,
      }
    end)

    if ok then
      return MENU_GROUP_ID
    end
  end

  return nil
end

local function registerCommand(plugin, spec)
  local groups = { MENU_GROUP_ID }
  for _, g in ipairs(CANDIDATE_MENU_GROUPS) do
    table.insert(groups, g)
  end

  for _, group in ipairs(groups) do
    local cmd = {
      id = spec.id,
      title = spec.title,
      group = group,
      onclick = spec.onclick,
    }

    local ok = pcall(function()
      plugin:newCommand(cmd)
    end)

    if ok then
      return true
    end
  end

  return false
end

local function setupSaveHook()
  app.events:on("beforecommand", function(ev)
    if ev.name ~= "SaveFile" then
      return
    end

    if SAVE_GUARD then
      return
    end

    local sprite = app.sprite
    if not sprite then
      return
    end

    local meta = parseMeta(sprite)
    if not meta then
      return
    end

    ev.stopPropagation()
    SAVE_GUARD = true

    local ok, resultOrErr = pcall(function()
      local okExport, infoOrErr = exportSlices(sprite, {
        outputRoot = meta.rootPath,
      })
      if not okExport then
        error(infoOrErr)
      end
      return infoOrErr
    end)

    SAVE_GUARD = false

    if ok then
      app.tip(string.format("Exported %d files and saved workspace.", resultOrErr.exported), 4)
    else
      app.alert {
        title = MENU_TITLE,
        text = {
          "Save interception failed:",
          tostring(resultOrErr),
        },
      }
    end
  end)
end

function init(plugin)
  safeNewMenuGroup(plugin)

  registerCommand(plugin, {
    id = "ImportFolderAsSlices",
    title = "Import Folders As Slices",
    onclick = function()
      openImportDialog(plugin)
    end,
  })

  registerCommand(plugin, {
    id = "ExportSlicesToFolder",
    title = "Export Slices To Folder",
    onclick = function()
      openExportDialog()
    end,
  })

  setupSaveHook()
end

function exit(plugin)
  plugin = plugin
end
