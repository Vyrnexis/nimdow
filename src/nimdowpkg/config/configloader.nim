import
  os,
  parsetoml,
  strutils,
  tables

import
  apprules,
  tagsettings,
  ../point,
  ../keys/keyutils,
  ../spawn,
  ../logger,
  ../windowtitleposition,
  ../wmcommands

var configLoc*: string

proc findConfigPath*(): string =
  let configHome = getConfigDir()
  result = configHome & "nimdow/config.toml"
  if not fileExists(result):
    result = "/usr/share/nimdow/config.default.toml"
  if not fileExists(result):
    log "config file " & result & " does not exist", lvlError
    result = ""

type
  KeyCombo* = tuple[key: string, modifiers: uint32]
    ## `key` is an xkbcommon key name ("Return", "i", "1", ...). For tag actions it
    ## doubles as the argument (the tag number); IPC passes the argument as `key`.
  Action* = proc(keyCombo: KeyCombo): void
  RegionClickAction* = proc(idx: int, width: int, regionCord: Point[int], clickCord: Point[int], button: int): void

  WindowSettings* = object
    tagCount*: uint
    borderColorUnfocused*: int
    borderColorFocused*: int
    borderColorUrgent*: int
    borderWidth*: uint
    modKey*: int
  BarSettings* = object
    height*: uint
    windowTitlePosition*: WindowTitlePosition
    fonts*: seq[string]
    showIndicator*: bool
    # Hex values
    fgColor*, bgColor*, selectionColor*, urgentColor*, hasWindowsColor*: int
    transparency*: uint8
    ## Tray icon size is the bar height minus twice the padding.
    trayIconPadding*, trayIconSpacing*: uint
  ScratchpadSettings* = object
    width*: int
    height*: int
  LayoutSettings* = object
    gapSize*: uint
    outerGap*: uint
    resizeStep*: uint
  MonitorSettings* = object
    tagSettings*: TagSettings
    barSettings*: BarSettings
    layoutSettings*: LayoutSettings
  MonitorSettingsRef* = ref MonitorSettings

  MonitorID* = int
  Config* = ref object
    actionIdentifierTable*: Table[string, Action]
    keyComboTable*: Table[KeyCombo, Action]
    regionClickActionTable*: Table[int, RegionClickAction]
    windowSettings*: WindowSettings
    scratchpadSettings*: ScratchpadSettings
    loggingEnabled*: bool
    reverseTagScrolling*: bool
    trayEnabled*: bool
    ## 1-based index of the monitor (in screen order) whose bar shows the tray; 0 follows the selected monitor.
    trayMonitor*: int
    trayIconTheme*: string
    tagKeys*: seq[string]
    defaultMonitorSettings*: MonitorSettings
    # Specific monitor settings
    monitorSettings*: Table[MonitorID, MonitorSettings]
    appRules*: seq[AppRule]

proc newConfig*(): Config =
  Config(
    actionIdentifierTable: initTable[string, Action](),
    keyComboTable: initTable[KeyCombo, Action](),
    windowSettings: WindowSettings(
      tagCount: 9,
      borderColorUnfocused: 0x1c1b19,
      borderColorFocused: 0x519f50,
      borderColorUrgent: 0xff5555,
      borderWidth: 1,
      modKey: ModifierTable["super"].int
    ),
    scratchpadSettings: ScratchpadSettings(
      width: 500,
      height: 300,
    ),

    loggingEnabled: false,
    trayEnabled: true,
    trayMonitor: 1,
    reverseTagScrolling: false
  )

proc configureAction*(this: Config, actionName: string, actionInvokee: Action)
proc populateBarSettings*(this: Config, barSettings: var BarSettings, settingsTable: TomlTableRef)
proc populateLayoutSettings*(this: Config, layoutSettings: var LayoutSettings, settingsTable: TomlTableRef)
proc populateControlAction(this: Config, action: string, configTable: TomlTable)
proc populateKeyComboTable*(this: Config, configTable: TomlTable)
proc getKeyCombos(
  this: Config,
  configTable: TomlTable,
  action: string,
  keys: seq[string]
): seq[KeyCombo]
proc getKeyCombos(
  this: Config,
  configTable: TomlTable,
  action: string
): seq[KeyCombo]
proc getKeysForAction(this: Config, configTable: TomlTable, action: string): seq[string]
proc getModifiersForAction(this: Config, configTable: TomlTable, action: string): seq[TomlValueRef]
proc getAutostartCommands(this: Config, configTable: TomlTable): seq[string]
proc runCommands(this: Config, commands: varargs[string])

proc runAutostartCommands*(this: Config, configTable: TomlTable) =
  let autostartCommands = this.getAutostartCommands(configTable)
  this.runCommands(autostartCommands)

proc getAutostartCommands(this: Config, configTable: TomlTable): seq[string] =
  if not configTable.hasKey("autostart"):
    return
  let autoStartTable = configTable["autostart"]
  if autoStartTable.kind != TomlValueKind.Table:
    raise newException(Exception,"Invalid autostart table")

  if not autoStartTable.tableVal[].hasKey("exec"):
    raise newException(Exception, "Autostart table does not have exec key")

  for cmd in autoStartTable.tableVal[]["exec"].arrayVal:
    if cmd.kind == TomlValueKind.String:
      result.add(cmd.stringVal)
    else:
      log repr(cmd) & " is not a string", lvlWarn

proc runCommand(this: Config, cmd: string) =
  if not spawnShell(cmd):
    log "Failed to start command: " & cmd, lvlWarn

proc runCommands(this: Config, commands: varargs[string]) =
  for cmd in commands:
    this.runCommand(cmd)

proc runCommandWithArgs(this: Config, command: string, arguments: varargs[string]) =
  var cmd = command.replace("%0", arguments.join " ")
  for i, argument in arguments:
    cmd = cmd.replace("%" & $(i + 1), argument)
  this.runCommand(cmd)

proc populateAppRules*(this: Config, configTable: TomlTable) =
  this.appRules = configTable.parseAppRules()

proc getModifierMask(modifier: TomlValueRef): uint32 =
  if modifier.kind != TomlValueKind.String:
    log "Invalid key configuration: " & repr(modifier) & " is not a string", lvlError
    return

  if not ModifierTable.hasKey(modifier.stringVal):
    log "Invalid key configuration: " & repr(modifier) & " is not a valid key modifier", lvlError
    return

  return ModifierTable[modifier.stringVal]

proc bitorModifiers(modifiers: openarray[TomlValueRef]): uint32 =
  for tomlElement in modifiers:
    result = result or getModifierMask(tomlElement)

proc configureAction*(this: Config, actionName: string, actionInvokee: Action) =
  this.actionIdentifierTable[actionName] = actionInvokee

proc configureExternalProcess(this: Config, command: string) =
  this.actionIdentifierTable[command] =
    proc(keyCombo: KeyCombo) =
      this.runCommands(command)

proc populateDefaultMonitorSettings(this: Config) =
  this.defaultMonitorSettings = MonitorSettings()

  this.defaultMonitorSettings.barSettings = BarSettings(
      height: 20,
      windowTitlePosition: wtpCenter,
      fonts: @[
        "monospace:size=10:antialias=true",
        "NotoColorEmoji:size=10:antialias=true"
      ],
      showIndicator: true,
      fgColor: 0xfce8c3,
      bgColor: 0x1c1b19,
      selectionColor: 0x519f50,
      urgentColor: 0xef2f27,
      hasWindowsColor: 0xfce8c3,
      trayIconPadding: 2,
      trayIconSpacing: 4
  )

  this.defaultMonitorSettings.layoutSettings = LayoutSettings(
      gapSize: 12,
      outerGap: 0,
      resizeStep: 10
  )

  this.defaultMonitorSettings.tagSettings = createDefaultTagSettings()

proc populateMonitorSettings(this: Config, configTable: TomlTable) =
  this.populateDefaultMonitorSettings()

  if not configTable.hasKey("monitors"):
    return

  let monitorsTable = configTable["monitors"]
  if monitorsTable.kind != TomlValueKind.Table:
    raise newException(Exception, "Invalid monitors config table")

  # Change default monitor settings.
  if monitorsTable.hasKey("default"):
    let settingsTable = configTable["settings"].tableVal
    this.populateBarSettings(this.defaultMonitorSettings.barSettings, settingsTable)
    this.populateLayoutSettings(this.defaultMonitorSettings.layoutSettings, settingsTable)

    let changedDefaults = monitorsTable["default"]
    if changedDefaults.hasKey("tags"):
      let tagsTable = changedDefaults["tags"]
      if tagsTable.kind == TomlValueKind.Table:
        # this.defaultMonitorSettings.populateTagSettings(tagsTable.tableVal)
        this.defaultMonitorSettings.tagSettings.populateTagSettings(tagsTable.tableVal)

  # Populate settings per-monitor
  for monitorIDStr, settingsToml in monitorsTable.tableVal.pairs():
    if monitorIDStr == "default":
      continue

    if settingsToml.kind != TomlValueKind.Table:
      log "Settings table incorrect type for monitor ID: " & monitorIDStr
      continue

    # Parse the ID into a integer.
    var monitorID: MonitorID
    try:
      monitorID = parseInt(monitorIDStr)
    except:
      log "Invalid monitor ID: " & monitorIDStr, lvlError
      continue

    var monitorSettings: MonitorSettings = deepcopy this.defaultMonitorSettings

    if settingsToml.hasKey("tags"):
      let tagsTable = settingsToml["tags"]
      if tagsTable.kind == TomlValueKind.Table:
        monitorSettings.tagSettings.populateTagSettings(tagsTable.tableVal)

    this.monitorSettings[monitorID] = monitorSettings

proc populateControlsTable(this: Config, configTable: TomlTable) =
  if not configTable.hasKey("controls"):
    return
  # Populate window manager controls
  let controlsTable = configTable["controls"]
  if controlsTable.kind != TomlValueKind.Table:
    raise newException(Exception, "Invalid controls config table")

  for action in controlsTable.tableVal.keys():
    let commandOpt = parseCommand(action)
    if commandOpt.isSome:
      this.populateControlAction(($(commandOpt.get)).toLower(), controlsTable[action].tableVal[])
    else:
      log "Invalid control: " & action, lvlError

proc populateExternalProcessSettings(this: Config, configTable: TomlTable) =
  if not configTable.hasKey("startProcess"):
    return

  # Populate external commands
  let externalProcessesTable = configTable["startProcess"]

  if externalProcessesTable.kind != TomlValueKind.Array:
    raise newException(Exception, "No \"startProcess\" commands defined!")

  for commandDeclaration in externalProcessesTable.arrayVal:
    if commandDeclaration.kind != TomlValueKind.Table:
      raise newException(Exception, "Invalid \"startProcess\" configuration command!")
    if not commandDeclaration.tableVal[].hasKey("command"):
      raise newException(Exception, "Invalid \"startProcess\" configuration: Missing \"command\" string!")

    let command = commandDeclaration.tableVal["command"].stringVal
    if commandDeclaration.tableVal[].hasKey("clickRegion"):
      if commandDeclaration.tableVal["clickRegion"].kind != TomlValueKind.Int:
        raise newException(
          Exception,
          "Invalid \"startProcess\" configuration: \"clickRegion\" not a number!"
        )

      let clickRegion = commandDeclaration.tableVal["clickRegion"].intVal.int
      closureScope:
        let command = command
        this.regionClickActionTable[clickRegion] =
          proc(idx: int, width: int, regionCord: Point[int], clickCord: Point[int], button: int) =
            this.runCommandWithArgs(
              command,
              $idx,
              $regionCord.x,
              $regionCord.y,
              $clickCord.x,
              $clickCord.y,
              $width,
              $button
            )
    else:
      this.configureExternalProcess(command)
      this.populateControlAction(
        command,
        commandDeclaration.tableVal[]
      )

proc removeTransparencyFromHexColor(color: int): int =
  return color or (0xff shl 24)

proc loadHexValue(this: Config, settingsTable: TomlTableRef, valueName: string): int =
  if settingsTable.hasKey(valueName):
    let setting = settingsTable[valueName]
    if setting.kind == TomlValueKind.String:
      return fromHex[int](setting.stringVal)
    else:
      raise newException(Exception, valueName & " is not a proper hex value! Ensure it is wrapped in double quotes")
  return -1

proc populateLayoutSettings*(
  this: Config,
  layoutSettings: var LayoutSettings,
  settingsTable: TomlTableRef
) =
  if settingsTable.hasKey("gapSize"):
    let gapSizeSetting = settingsTable["gapSize"]
    if gapSizeSetting.kind == TomlValueKind.Int:
      layoutSettings.gapSize = max(0, gapSizeSetting.intVal).uint
    else:
      log "gapSize is not an integer value!", lvlWarn

  if settingsTable.hasKey("outerGap"):
    let outerGapSetting = settingsTable["outerGap"]
    if outerGapSetting.kind == TomlValueKind.Int:
      layoutSettings.outerGap = max(0, outerGapSetting.intVal).uint
    else:
      log "outerGap is not an integer value!", lvlWarn

  if settingsTable.hasKey("resizeStep"):
    let resizeStepSetting = settingsTable["resizeStep"]
    if resizeStepSetting.kind == TomlValueKind.Int:
      if resizeStepSetting.intVal > 0:
        layoutSettings.resizeStep = resizeStepSetting.intVal.uint
      else:
        log "resizeStep is not a positive integer!", lvlWarn
    else:
      log "resizeStep is not an integer value!", lvlWarn

proc populateBarSettings*(this: Config, barSettings: var BarSettings, settingsTable: TomlTableRef) =
  if settingsTable.hasKey("windowTitlePosition"):
    let wtpToml = settingsTable["windowTitlePosition"]
    if wtpToml.kind != TomlValueKind.String:
      raise newException(Exception, "windowTitlePosition needs to be a string!")

    let windowTitlePosition = wtpToml.stringVal.toLower()
    if windowTitlePosition == "center" or windowTitlePosition == "centre":
      barSettings.windowTitlePosition = wtpCenter
    elif windowTitlePosition == "left":
      barSettings.windowTitlePosition = wtpLeft
    else:
      raise newException(Exception, "windowTitlePosition needs to be: center, centre, or left!")

  let bgColor = this.loadHexValue(settingsTable, "barBackgroundColor")
  if bgColor != -1:
    barSettings.bgColor = bgColor

  let fgColor = this.loadHexValue(settingsTable, "barForegroundColor")
  if fgColor != -1:
    barSettings.fgColor = fgColor

  let selectionColor = this.loadHexValue(settingsTable, "barSelectionColor")
  if selectionColor != -1:
    barSettings.selectionColor = selectionColor

  let urgentColor = this.loadHexValue(settingsTable, "barUrgentColor")
  if urgentColor != -1:
    barSettings.urgentColor = urgentColor

  barSettings.transparency = 255
  if settingsTable.hasKey("barTransparency"):
    let barTransparency = settingsTable["barTransparency"]
    if barTransparency.kind == TomlValueKind.Int:
      barSettings.transparency = clamp(barTransparency.intVal, 0, 255).uint8

  let hasWindowsColor= this.loadHexValue(settingsTable, "barHasWindowsColor")
  if hasWindowsColor != -1:
    barSettings.hasWindowsColor= hasWindowsColor
  else:
    barSettings.hasWindowsColor = fgColor

  if settingsTable.hasKey("barShowIndicator"):
    let showIndicator = settingsTable["barShowIndicator"]
    if showIndicator.kind == TomlValueKind.Bool:
      barSettings.showIndicator = showIndicator.boolVal

  for (key, field) in [("trayIconPadding", addr barSettings.trayIconPadding),
                       ("trayIconSpacing", addr barSettings.trayIconSpacing)]:
    if settingsTable.hasKey(key):
      let value = settingsTable[key]
      if value.kind == TomlValueKind.Int:
        field[] = max(0, value.intVal).uint
      else:
        log key & " is not an integer value!", lvlWarn

  if settingsTable.hasKey("barHeight"):
    let barHeight = settingsTable["barHeight"]
    if barHeight.kind == TomlValueKind.Int:
      barSettings.height = max(0, barHeight.intVal).uint

  if settingsTable.hasKey("barFonts"):
    let barFonts = settingsTable["barFonts"]
    if barFonts.kind != TomlValueKind.Array:
      raise newException(Exception, "barFonts is not an array of strings!")

    var fonts: seq[string]
    for font in barFonts.arrayVal:
      if font.kind == TomlValueKind.String:
        fonts.add(font.stringVal)
      else:
        raise newException(Exception, "Invalid font - must be a string!")
    barSettings.fonts = fonts

proc populateGeneralSettings*(this: Config, configTable: TomlTable) =
  if not configTable.hasKey("settings") or configTable["settings"].kind != TomlValueKind.Table:
    raise newException(Exception, "Invalid settings table")

  let settingsTable = configTable["settings"].tableVal
  this.populateBarSettings(this.defaultMonitorSettings.barSettings, settingsTable)
  this.populateLayoutSettings(this.defaultMonitorSettings.layoutSettings, settingsTable)

  # Window settings
  if settingsTable.hasKey("borderWidth"):
    let borderWidthSetting = settingsTable["borderWidth"]
    if borderWidthSetting.kind == TomlValueKind.Int:
      this.windowSettings.borderWidth = max(0, borderWidthSetting.intVal).uint
    else:
      log "borderWidth is not an integer value!", lvlWarn

  let unfocusedBorderVal = this.loadHexValue(settingsTable, "borderColorUnfocused")
  if unfocusedBorderVal != -1:
    this.windowSettings.borderColorUnfocused = removeTransparencyFromHexColor(unfocusedBorderVal)

  let focusedBorderVal = this.loadHexValue(settingsTable, "borderColorFocused")
  if focusedBorderVal != -1:
    this.windowSettings.borderColorFocused = removeTransparencyFromHexColor(focusedBorderVal)

  let urgentBorderVal = this.loadHexValue(settingsTable, "borderColorUrgent")
  if urgentBorderVal != -1:
    this.windowSettings.borderColorUrgent = removeTransparencyFromHexColor(urgentBorderVal)

  # Bar & layout settings
  for monitorSettings in this.monitorSettings.mvalues():
    this.populateBarSettings(monitorSettings.barSettings, settingsTable)
    this.populateLayoutSettings(monitorSettings.layoutSettings, settingsTable)

  # General settings
  if settingsTable.hasKey("loggingEnabled"):
    let loggingEnabledSetting = settingsTable["loggingEnabled"]
    if loggingEnabledSetting.kind == TomlValueKind.Bool:
      this.loggingEnabled = loggingEnabledSetting.boolVal
    else:
      log "loggingEnabled is not true/false!", lvlWarn

  if settingsTable.hasKey("trayEnabled"):
    let trayEnabled = settingsTable["trayEnabled"]
    if trayEnabled.kind == TomlValueKind.Bool:
      this.trayEnabled = trayEnabled.boolVal
    else:
      log "trayEnabled is not true/false!", lvlWarn

  if settingsTable.hasKey("trayMonitor"):
    let trayMonitor = settingsTable["trayMonitor"]
    if trayMonitor.kind == TomlValueKind.Int:
      this.trayMonitor = max(0, trayMonitor.intVal)
    else:
      log "trayMonitor is not an integer value!", lvlWarn

  if settingsTable.hasKey("trayIconTheme"):
    let trayIconTheme = settingsTable["trayIconTheme"]
    if trayIconTheme.kind == TomlValueKind.String:
      this.trayIconTheme = trayIconTheme.stringVal
    else:
      log "trayIconTheme is not a string!", lvlWarn

  if settingsTable.hasKey("reverseTagScrolling"):
    let reverseTagScrollingSetting = settingsTable["reverseTagScrolling"]
    if reverseTagScrollingSetting.kind == TomlValueKind.Bool:
      this.reverseTagScrolling = reverseTagScrollingSetting.boolVal
    else:
      log "reverseTagScrolling is not true/false!", lvlWarn

  # Scratchpad settings
  if settingsTable.hasKey("scratchpadWidth"):
    let scratchpadWidthSetting = settingsTable["scratchpadWidth"]
    if scratchpadWidthSetting.kind == TomlValueKind.Int:
      this.scratchpadSettings.width = scratchpadWidthSetting.intVal.int
    else:
      log "scratchpadWidth is not an integer value!", lvlWarn

  if settingsTable.hasKey("scratchpadHeight"):
    let scratchpadHeightSetting = settingsTable["scratchpadHeight"]
    if scratchpadHeightSetting.kind == TomlValueKind.Int:
      this.scratchpadSettings.height = scratchpadHeightSetting.intVal.int
    else:
      log "scratchpadHeight is not an integer value!", lvlWarn

  if settingsTable.hasKey("modKey"):
    let modKeySettings = settingsTable["modKey"]
    if modKeySettings.kind == TomlValueKind.String:
      this.windowSettings.modKey = ModifierTable[modKeySettings.stringVal].int
    else:
      log "modKey is not a string value!", lvlWarn

proc populateKeyComboTable*(this: Config, configTable: TomlTable) =
  ## Reads the user's configuration file and set the keybindings.
  this.populateControlsTable(configTable)
  this.populateMonitorSettings(configTable)
  this.populateExternalProcessSettings(configTable)

proc loadConfigFile*(): TomlTable =
  ## Reads the user's configuration file into a table.
  ## Set configLoc before calling this procedure,
  ## if you would like to use an alternate config file.
  if configLoc.len == 0:
    configLoc = findConfigPath()
  let loadedConfig = parsetoml.parseFile(configLoc)
  if loadedConfig.kind != TomlValueKind.Table:
    raise newException(Exception, "Invalid config file!")
  return loadedConfig.tableVal[]

proc populateControlAction(this: Config, action: string, configTable: TomlTable) =
  let keyCombos = this.getKeyCombos(configTable, action)
  for keyCombo in keyCombos:
    if this.actionIdentifierTable.hasKey(action):
      this.keyComboTable[keyCombo] = this.actionIdentifierTable[action]
    else:
      raise newException(Exception, "Invalid key config action: \"" & action & "\" does not exist")

proc getKeyCombos(
  this: Config,
  configTable: TomlTable,
  action: string,
  keys: seq[string]
): seq[KeyCombo] =
  ## Gets the KeyCombos associated with the given `action` from the table.
  let modifierArray = this.getModifiersForAction(configTable, action)
  let modifiers: uint32 = bitorModifiers(modifierArray)
  for key in keys:
    if key.toKeysym() == NoSymbol:
      log "Unknown key name in config: \"" & key & "\" (action \"" & action & "\")", lvlError
      continue
    result.add((key, modifiers))

proc getKeyCombos(
  this: Config,
  configTable: TomlTable,
  action: string
): seq[KeyCombo] =
  return this.getKeyCombos(
    configTable,
    action,
    this.getKeysForAction(configTable, action)
  )

proc getKeysForAction(this: Config, configTable: TomlTable, action: string): seq[string] =
  if not configTable.hasKey("keys"):
    log "\"keys\" not found in config table for action \"" & action & "\"", lvlError
    return
  var tomlKeys = configTable["keys"]
  if tomlKeys.kind != TomlValueKind.Array:
    log "Invalid key config for action: " & action & "\n\"keys\" must be an array of strings", lvlError
    return

  for tomlKey in tomlKeys.arrayVal:
    if tomlKey.kind != TomlValueKind.String:
      log "Invalid key configuration: " & repr(tomlKey) & " is not a string", lvlError
      return
    result.add(tomlKey.stringVal)

proc getModifiersForAction(this: Config, configTable: TomlTable, action: string): seq[TomlValueRef] =
  if configTable.hasKey("modifiers"):
    var modifiersConfig = configTable["modifiers"]
    if modifiersConfig.kind != TomlValueKind.Array:
      log "Invalid key configuration: " & repr(modifiersConfig) & " is not an array", lvlError
    return modifiersConfig.arrayVal

