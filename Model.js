.pragma library

// Curated filetype groups. Each row in the picker sets every MIME type it
// lists in one go, which is what people actually mean by "open images with
// imv" — the alternative is asking them to know that a JPEG and a WebP are
// two separate registrations.
var CATEGORIES = [
  { key: "images", label: "Images", icon: "󰋩", hint: "png jpg gif webp svg",
    mimes: ["image/png", "image/jpeg", "image/gif", "image/webp", "image/bmp",
            "image/tiff", "image/avif", "image/heif", "image/x-icon"] },
  { key: "svg", label: "Vector images", icon: "󰠱", hint: "svg",
    mimes: ["image/svg+xml"] },
  { key: "video", label: "Video", icon: "󰕧", hint: "mp4 mkv webm mov",
    mimes: ["video/mp4", "video/x-matroska", "video/webm", "video/quicktime",
            "video/x-msvideo", "video/mpeg", "video/x-flv", "video/ogg"] },
  { key: "audio", label: "Audio", icon: "󰝚", hint: "mp3 flac ogg wav",
    mimes: ["audio/mpeg", "audio/flac", "audio/ogg", "audio/x-wav", "audio/wav",
            "audio/mp4", "audio/aac", "audio/opus", "audio/x-vorbis+ogg"] },
  { key: "pdf", label: "PDF", icon: "󰈦", hint: "pdf",
    mimes: ["application/pdf"] },
  { key: "markdown", label: "Markdown", icon: "󰍔", hint: "md markdown",
    mimes: ["text/markdown", "text/x-markdown"] },
  { key: "text", label: "Plain text", icon: "󰈙", hint: "txt log",
    mimes: ["text/plain"] },
  { key: "code", label: "Code & config", icon: "󰅩", hint: "json yaml sh py js css",
    mimes: ["application/json", "application/x-yaml", "text/x-yaml",
            "text/x-shellscript", "text/javascript", "text/css",
            "application/xml", "text/xml", "text/x-python", "text/x-csrc",
            "text/x-c++src", "text/x-lua", "text/rust", "text/x-go",
            "application/toml", "text/x-ruby", "application/x-desktop"] },
  { key: "archives", label: "Archives", icon: "󰗄", hint: "zip tar gz 7z rar",
    mimes: ["application/zip", "application/x-tar", "application/gzip",
            "application/x-xz", "application/zstd", "application/x-7z-compressed",
            "application/vnd.rar", "application/x-bzip2",
            "application/x-compressed-tar"] },
  { key: "web", label: "Web links", icon: "󰖟", hint: "http https html browser",
    mimes: ["x-scheme-handler/http", "x-scheme-handler/https", "text/html",
            "application/xhtml+xml"] },
  { key: "email", label: "Email links", icon: "󰇮", hint: "mailto mail",
    mimes: ["x-scheme-handler/mailto"] },
  { key: "documents", label: "Documents", icon: "󰈬", hint: "docx doc odt rtf",
    mimes: ["application/vnd.openxmlformats-officedocument.wordprocessingml.document",
            "application/msword", "application/vnd.oasis.opendocument.text",
            "application/rtf"] },
  { key: "spreadsheets", label: "Spreadsheets", icon: "󰈛", hint: "xlsx xls ods csv",
    mimes: ["application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
            "application/vnd.ms-excel",
            "application/vnd.oasis.opendocument.spreadsheet", "text/csv"] },
  { key: "presentations", label: "Presentations", icon: "󰈧", hint: "pptx ppt odp",
    mimes: ["application/vnd.openxmlformats-officedocument.presentationml.presentation",
            "application/vnd.ms-powerpoint",
            "application/vnd.oasis.opendocument.presentation"] },
  { key: "ebooks", label: "Ebooks", icon: "󰗚", hint: "epub mobi",
    mimes: ["application/epub+zip", "application/x-mobipocket-ebook",
            "application/vnd.amazon.ebook"] },
  { key: "folders", label: "Folders", icon: "󰉋", hint: "directory file manager",
    mimes: ["inode/directory"] },
  { key: "torrents", label: "Torrents", icon: "󰇚", hint: "torrent magnet",
    mimes: ["application/x-bittorrent", "x-scheme-handler/magnet"] }
]

var CUSTOM_ICON = "󰈔"

function isPlainObject(value) {
  return value !== null && typeof value === "object" && !Array.isArray(value)
}

// ---------------------------------------------------------------- custom rows

// User-added filetypes live in ~/.config/omarchy/mimetypes.json so they can be
// hand-edited and survive a plugin reinstall.
function parseCustom(rawText) {
  var parsed = null
  try { parsed = JSON.parse(rawText || "{}") } catch (e) { return [] }
  var list = isPlainObject(parsed) ? parsed.custom : parsed
  if (!Array.isArray(list)) return []

  var out = []
  var seen = ({})
  for (var i = 0; i < list.length; i++) {
    var entry = list[i]
    var mimes = []
    var label = ""
    if (typeof entry === "string") {
      mimes = [entry]
    } else if (isPlainObject(entry)) {
      label = String(entry.label || "")
      mimes = Array.isArray(entry.mimes) ? entry.mimes.map(String)
        : (entry.mime ? [String(entry.mime)] : [])
    }
    mimes = mimes.filter(function(m) { return m.indexOf("/") !== -1 })
    if (mimes.length === 0) continue
    var key = "custom:" + mimes.join(",")
    if (seen[key]) continue
    seen[key] = true
    out.push({
      key: key,
      label: label || mimes[0],
      icon: CUSTOM_ICON,
      hint: mimes.join(" "),
      mimes: mimes,
      custom: true
    })
  }
  return out
}

function serializeCustom(rows) {
  var out = []
  for (var i = 0; i < rows.length; i++) {
    out.push({ label: rows[i].label, mimes: rows[i].mimes })
  }
  return JSON.stringify({ custom: out }, null, 2) + "\n"
}

function addCustom(rows, label, mimes) {
  var next = rows.slice()
  var key = "custom:" + mimes.join(",")
  for (var i = 0; i < next.length; i++) if (next[i].key === key) return next
  next.push({ key: key, label: label || mimes[0], icon: CUSTOM_ICON,
              hint: mimes.join(" "), mimes: mimes, custom: true })
  return next
}

function removeCustom(rows, key) {
  return rows.filter(function(row) { return row.key !== key })
}

// A MIME type already covered by a built-in category would produce two rows
// that fight over the same registration, so the add flow rejects it.
function builtinFor(mime) {
  for (var i = 0; i < CATEGORIES.length; i++) {
    if (CATEGORIES[i].mimes.indexOf(mime) !== -1) return CATEGORIES[i]
  }
  return null
}

// ------------------------------------------------------------------ defaults

// The mime itself, then its shared-mime-info parents. A default registered
// for text/plain really does open text/markdown, so the picker has to look up
// the chain before it claims nothing is set.
function ancestry(mime, parents) {
  var seen = [mime]
  var queue = [mime]
  while (queue.length > 0) {
    var current = queue.shift()
    var ups = (parents && parents[current]) || []
    for (var i = 0; i < ups.length; i++) {
      if (seen.indexOf(ups[i]) === -1) {
        seen.push(ups[i])
        queue.push(ups[i])
      }
    }
  }
  return seen
}

function defaultFor(mime, scan) {
  var chain = ancestry(mime, scan.parents)
  for (var i = 0; i < chain.length; i++) {
    var appId = scan.defaults[chain[i]]
    if (appId) return { app: appId, via: chain[i], inherited: i > 0 }
  }
  return null
}

function appName(appId, scan) {
  var app = scan.apps[appId]
  return app ? app.name : String(appId || "").replace(/\.desktop$/, "")
}

// One category can span many MIME types whose defaults disagree (a JPEG
// opening in imv while a WebP opens in the browser). Say so rather than
// picking one arbitrarily. An inherited hit is also called out: nothing is
// registered for the type itself, so the app on screen comes from a parent
// type and would change if that parent were reassigned.
function categoryDefault(category, scan) {
  var apps = []
  var missing = 0
  var inherited = 0
  var via = ""
  for (var i = 0; i < category.mimes.length; i++) {
    var hit = defaultFor(category.mimes[i], scan)
    if (!hit) { missing++; continue }
    if (hit.inherited) { inherited++; via = hit.via }
    if (apps.indexOf(hit.app) === -1) apps.push(hit.app)
  }

  if (apps.length === 0) return { app: "", label: "Not set", state: "unset" }
  if (apps.length > 1) {
    return { app: "", label: "Mixed (" + apps.length + " apps)", state: "mixed" }
  }

  var label = appName(apps[0], scan)
  var resolved = category.mimes.length - missing
  if (missing > 0) {
    return { app: apps[0], label: label + " (only some types)", state: "partial" }
  }
  if (inherited === resolved) {
    // Every type in the group falls through to a parent. With one type in the
    // group there is a single parent worth naming.
    var suffix = category.mimes.length === 1 && via ? " (via " + via + ")" : " (inherited)"
    return { app: apps[0], label: label + suffix, state: "inherited" }
  }
  if (inherited > 0) {
    return { app: apps[0], label: label + " (partly inherited)", state: "inherited" }
  }
  return { app: apps[0], label: label, state: "set" }
}

// -------------------------------------------------------------------- search

function matches(filter, haystack) {
  var needle = String(filter || "").trim().toLowerCase()
  if (needle.length === 0) return true
  var text = String(haystack || "").toLowerCase()
  var terms = needle.split(/\s+/)
  for (var i = 0; i < terms.length; i++) {
    if (text.indexOf(terms[i]) === -1) return false
  }
  return true
}

function categoryRows(customRows, scan, filter) {
  var all = CATEGORIES.concat(customRows)
  var out = []
  for (var i = 0; i < all.length; i++) {
    var category = all[i]
    var current = categoryDefault(category, scan)
    var haystack = [category.label, category.hint, current.label,
                    category.mimes.join(" ")].join(" ")
    if (!matches(filter, haystack)) continue
    out.push({
      key: category.key,
      label: category.label,
      icon: category.icon,
      mimes: category.mimes,
      custom: category.custom === true,
      currentApp: current.app,
      currentLabel: current.label,
      currentState: current.state
    })
  }
  return out
}

// ------------------------------------------------------------------ app list

// Handlers that declare any MIME type in the category, or a parent of one.
// Declaring text/plain is a real claim on text/markdown, so those apps belong
// in the short list rather than behind "show all".
function declaredFor(category, scan) {
  var scores = ({})
  for (var i = 0; i < category.mimes.length; i++) {
    var chain = ancestry(category.mimes[i], scan.parents)
    for (var c = 0; c < chain.length; c++) {
      var handlers = scan.handlers[chain[c]] || []
      for (var h = 0; h < handlers.length; h++) {
        var appId = handlers[h]
        // Direct claims outrank inherited ones so the obvious app sorts first.
        var score = (c === 0 ? 100 : 1)
        scores[appId] = (scores[appId] || 0) + score
      }
    }
  }
  return scores
}

function appRows(category, scan, filter, showAll) {
  if (!category) return []
  var scores = declaredFor(category, scan)
  var current = category.currentApp || ""

  var rows = []
  for (var appId in scan.apps) {
    var app = scan.apps[appId]
    var declared = scores[appId] !== undefined
    var isCurrent = appId === current
    // Unlisted apps are only worth showing on request, but never hide the app
    // that is already set — that would make the panel lie about the state.
    if (!declared && !showAll && !isCurrent) continue
    if (app.noDisplay && !declared && !isCurrent) continue
    if (!matches(filter, [app.name, app.generic, appId, app.exec].join(" "))) continue
    rows.push({
      appId: appId,
      name: app.name,
      icon: app.icon,
      subtext: app.generic || appId.replace(/\.desktop$/, ""),
      declared: declared,
      score: scores[appId] || 0,
      isCurrent: isCurrent
    })
  }

  rows.sort(function(a, b) {
    if (a.isCurrent !== b.isCurrent) return a.isCurrent ? -1 : 1
    if (a.declared !== b.declared) return a.declared ? -1 : 1
    if (a.score !== b.score) return b.score - a.score
    return a.name.toLowerCase() < b.name.toLowerCase() ? -1 : 1
  })

  var nameCounts = ({})
  for (var r = 0; r < rows.length; r++) {
    nameCounts[rows[r].name] = (nameCounts[rows[r].name] || 0) + 1
  }
  for (var s = 0; s < rows.length; s++) {
    if (nameCounts[rows[s].name] > 1) {
      rows[s].subtext = rows[s].appId.replace(/\.desktop$/, "")
    }
  }
  return rows
}

function hasHiddenApps(category, scan, filter) {
  if (!category) return false
  var shown = appRows(category, scan, filter, false).length
  var all = appRows(category, scan, filter, true).length
  return all > shown
}

// ------------------------------------------------------------------- labeling

// "application/vnd.oasis.opendocument.text" -> "Opendocument Text".
// Only used to name a user-added row; the JSON file is there for anyone who
// wants a better name than this can guess.
function prettyLabel(mime, ext) {
  if (ext) return "." + String(ext)
  var subtype = String(mime || "").split("/").pop()
  subtype = subtype.split("+")[0]
  subtype = subtype.replace(/^x-/, "").replace(/^vnd\./, "")
  var words = subtype.split(/[.\-_]/).filter(function(w) { return w.length > 0 })
  for (var i = 0; i < words.length; i++) {
    words[i] = words[i].charAt(0).toUpperCase() + words[i].slice(1)
  }
  return words.join(" ") || mime
}
