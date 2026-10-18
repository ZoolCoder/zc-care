// Reads or rewrites the desktop pictures in the wallpaper store, Index.plist:
// every Space on every display keeps its own. Prints "<showing url> <total>".
// Usage: osascript -l JavaScript store.js read|write STORE URL
ObjC.import('Foundation')
function run(argv) {
  const [mode, store, url] = argv
  const data = $.NSData.dataWithContentsOfFile(store)
  if (data.isNil()) return '0 0'
  const root = $.NSPropertyListSerialization.propertyListWithDataOptionsFormatError(data, 2, null, null)
  const image = 'com.apple.wallpaper.choice.image'
  const config = $.NSPropertyListSerialization.dataWithPropertyListFormatOptionsError(
    $({type: 'imageFile', url: {relative: url}}), 200, 0, null)
  let seen = 0, match = 0
  const shows = c => {
    const cfg = c.objectForKey('Configuration')
    if (cfg.isNil() || c.objectForKey('Provider').js !== image) return false
    const d = $.NSPropertyListSerialization.propertyListWithDataOptionsFormatError(cfg, 0, null, null)
    return !d.isNil() && ObjC.deepUnwrap(d).url?.relative === url
  }
  const desktop = d => {
    const choices = d.objectForKey('Content').objectForKey('Choices')
    if (choices.isNil()) return
    for (let i = 0; i < choices.count; i++) {
      const c = choices.objectAtIndex(i)
      seen++
      if (shows(c)) { match++; continue }
      if (mode !== 'write') continue
      c.setObjectForKey(image, 'Provider')
      c.setObjectForKey(config, 'Configuration')
      c.setObjectForKey($.NSArray.array, 'Files')
    }
  }
  const walk = o => {
    if (o.isKindOfClass($.NSArray)) { for (let i = 0; i < o.count; i++) walk(o.objectAtIndex(i)); return }
    if (!o.isKindOfClass($.NSDictionary)) return
    for (const k of o.allKeys.js) {
      const v = o.objectForKey(k)
      if (k.js === 'Desktop' && v.isKindOfClass($.NSDictionary)) desktop(v); else walk(v)
    }
  }
  // Reading walks one unwrapped copy: going through the bridge per key is
  // about a hundred times slower.
  const read = o => {
    if (Array.isArray(o)) return o.forEach(read)
    if (!o || typeof o !== 'object' || o.constructor !== Object) return
    for (const [k, v] of Object.entries(o)) {
      if (k !== 'Desktop' || !v || typeof v !== 'object') { read(v); continue }
      for (const c of v.Content?.Choices ?? []) {
        seen++
        if (c.Provider !== image || !c.Configuration) continue
        const d = $.NSPropertyListSerialization.propertyListWithDataOptionsFormatError(c.Configuration, 0, null, null)
        if (!d.isNil() && ObjC.deepUnwrap(d).url?.relative === url) match++
      }
    }
  }
  if (mode === 'read') {
    read(ObjC.deepUnwrap(root))
    return match + ' ' + seen
  }
  walk(root)
  if (mode === 'write' && match < seen)
    $.NSPropertyListSerialization.dataWithPropertyListFormatOptionsError(root, 200, 0, null).writeToFileAtomically(store, true)
  return match + ' ' + seen
}
