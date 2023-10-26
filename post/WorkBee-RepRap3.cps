// WorkBee - Duet post processor
//
// Modified by Bjorn Andersson <bjorn@iki.fi>, based on the procsessor
// provided by Ooznest.
//
// Changes compared to Ooznest's processor:
// - Cleanup of unused code
// - Tool change prompts
// - Z probing during tool change, selectable between manual and probe tool
// - Helical moves using G2/G3
// - maxCircularSweep 360 degrees
// - Add comments showing the router move in the G-code
// - Output X, Y and F only when they change in G0/G1 commands
// - Show router specific RPM settings for Makita and DeWalt routers
// - Support lasers ("Jets" in Fusion)
//
// Todo:
// - Implement onCommand() commands
// - Optional XY probing, manual and auto
// - Probing plate offset
// - Maybe simulate normal ends mills for lasers, so that all toolpaths can be
//   used with lasers (in addition to the normal "Jets")

// PostProcessor attributes
description = "WorkBee RepRapFirmware 3";
longDescription = "Milling post for Ooznest WorkBee CNC with RepRapFirmware 3 by bjorn@iki.fi.\nVersion 20231026.0";
vendor = "Ooznest";
vendorUrl = "https://ooznest.co.uk/";
legal = "";
certificationLevel = 2;
minimumRevision = 24000;
version = "1.2"
extension = "nc";
setCodePage("ascii");

capabilities = CAPABILITY_MILLING;
//capabilities = CAPABILITY_MILLING | CAPABILITY_JET;
tolerance = spatial(0.002, MM);

minimumChordLength = spatial(0.25, MM);
minimumCircularRadius = spatial(0.01, MM);
maximumCircularRadius = spatial(1000, MM);
minimumCircularSweep = toRad(0);
maximumCircularSweep = toRad(360);
allowHelicalMoves = true;
allowSpiralMoves = false;
allowedCircularPlanes = (1 << PLANE_XY);

const NO_ROUTER = "Do not show";

// user-defined properties
properties = {
  toolChangePrompt: {
    title: "Prompt for tool change",
    description: "Prompts to change tool and probe between operations if the tool changes",
    type: "boolean",
    value: false
  },
  useProbingTool: {
    title: "Use probing tool",
    description: "Use a probing tool to automatically probe for Z-origin during tool change, else manual probing will be performed.",
    type: "boolean",
    value: false
  },
  routerRPM: {
    title: "Show router RPM dial setting",
    description: "On tool change, in addition to showing RPM values show the router specific setting",
    type: "enum",
    values: [NO_ROUTER, "Makita", "DeWalt"],
    value: NO_ROUTER
  }
  // laserMode: {
  //   title: "Enable laser mode",
  //   description: "Enable laser mode",
  //   type: "boolean",
  //   laserMode: false
  // }
};

var gFormat = createFormat({prefix: "G", decimals: 0});
var mFormat = createFormat({prefix: "M", decimals: 0});
var iFormat = createFormat({decimals: 0});

var xyzFormat = createFormat({decimals: 3, trim: false});
var feedFormat = createFormat({decimals: 1 });
var speedFormat = createFormat({decimals: 0});
var secFormat = createFormat({decimals:3, forceDecimal: true}); // seconds - range 0.001-1000

// FIX: Use createOutputVariable() instead
var xOutput = createVariable({prefix: "X", force: false}, xyzFormat);
var yOutput = createVariable({prefix: "Y", force: false}, xyzFormat);
var zOutput = createVariable({prefix: "Z", force: false}, xyzFormat);
var feedOutput = createVariable({prefix: "F", force: false}, feedFormat);
var speedOutput = createVariable({prefix: "S", force: true}, speedFormat);
var pParam = createVariable({prefix: "P", force: true}, iFormat);

// circular output
// FIX: Use createOutputVariable() instead
var iOutput = createReferenceVariable({prefix: "I", force: true}, xyzFormat);
var jOutput = createReferenceVariable({prefix: "J", force: true}, xyzFormat);

// FIX: Use createOutputVariable() instead
var gMotionModal = createModal({force: true}, gFormat); // modal group 1 // G0-G3, ...
var gAbsIncModal = createModal({}, gFormat); // modal group 3 // G90-91
var gUnitModal = createModal({}, gFormat); // modal group 6 // G20-21

// collected state
var previousMovement = null;

const routerSpeeds = {
  "Makita": [
    10000,
    12000,
    17000,
    22000,
    27000,
    30000,
  ],
  "DeWalt": [
    16000,
    18200,
    20400,
    22600,
    24800,
    27000
  ]
};

function speedSetting(speed) {
  if (properties.routerRPM == NO_ROUTER) {
    return undefined;
  }
  var rSpeeds = routerSpeeds[properties.routerRPM];
  if (speed <= rSpeeds[0]) {
    return 1;
  }
  const highestSetting = rSpeeds.length
  const highestSpeed = rSpeeds[highestSetting - 1];
  if (speed >= highestSpeed) {
    return highestSetting;
  }
  for (var i = 1; i < highestSetting; i++) {
    rSpeed = rSpeeds[i]
    if (rSpeed >= speed) {
      rSetting = (speed - rSpeeds[i-1]) / (rSpeed - rSpeeds[i-1]) + i;
      return rSetting;
    }
  }
  return undefined; // never reached
}

function writeBlock() {
    writeWords(arguments);
}

function writeComment(){
  writeWords(";", arguments);
}


// onMachine() is invoked when the machine configuration changes during post
// processing.
//
// function onMachine() {
// }

// onOpen() is invoked once at post processing initialization. This is the place
// to output the program header. The configuration script is not allowed to
// modify the entry functions after onOpen() has been invoked.
//
function onOpen() {
  if (unit == IN) {
    error(localize("Please select millimeters as unit when post processing."));
    return;
  }

  if (hasGlobalParameter("document-path")){
    writeComment("Document: ", getGlobalParameter("document-path"));
  }

  if (programName) {
    writeComment("Program name:", programName);
  }
  if (programComment) {
    writeComment("Comment: ", programComment);
  }

  var d = new Date();
  writeComment("Created at:", d.toISOString());
  writeln("");

  writeBlock(gUnitModal.format(21), "; Units in mm");
  writeBlock(gAbsIncModal.format(90), "; Absolute coordinates");

  // if (isJet()) {
  //   properties.toolChangePrompt = false;
  //   writeBlock('M452 C"!exp.heater3" ; Enable laser mode on HEATER3');
  // } else {
  //   writeBlock("M453 ; Enable CNC mode")
  //   speedOutput.disable()
  // }
}

// onParameter() is invoked for each parameter in the CLD data where a parameter
// is a simple name-value pair.
//
// @param String name
// @param String value
//
// function onParameter(name, value) {
// }

// onPassThrough() is invoked for pass-through information. Pass-through allows
// the user to transfer text unmodified through to the post processor to the
// output file. This feature should be used with caution as the post processor
// will ignore any pass-through data.
//
// @param String value
//
// function onPassThrough(value) {
//   // onPassThrough(String value)
// }

// onComment() is invoked for each comment.
//
// @param String comment
//
function onComment(comment) {
  writeComment(comment);
}

<<<<<<< HEAD
function homeZ() {
  writeBlock("G53 G0 Z{move.axes[2].max-1} ; Raise Z")
=======
function raiseZ() {
  writeComment("Raise Z");
  writeBlock("G90                               ; Absolute positioning");
  writeBlock("G53 G0 Z{move.axes[2].max-1}      ; Top pos - 1mm");
>>>>>>> fa13b77 (Cleanup)
}

// onSection() is invoked at the start of a section. A section commonly
// corresponds to an individual operation within the CAM system. However, note
// that it is perfectly legal from the post processors perspective if an
// operation generated multiple sections.
//
function onSection() {

  var insertToolCall = isFirstSection() ||
    currentSection.getForceToolChange && currentSection.getForceToolChange() ||
    (tool.toolId != getPreviousSection().getTool().toolId);

  writeln("");

  if (hasParameter("operation-comment")) {
    var comment = getParameter("operation-comment");
    if (comment) {
      writeComment("Operation", comment);
    }
  }
  if (tool.description) {
    writeComment("Tool: #" + tool.Number + " " + tool.description);
  }

  if (properties.toolChangePrompt && insertToolCall) {
    raiseZ(); // Raise so we can remove dust shoe and insert tool
    var msg = "Insert tool #" + tool.number;
    if (tool.description) {
      toolDesc = tool.description.replace('"','""');
      msg += ": " + toolDesc;
    }
    if (properties.useProbingTool) {
      msg += ". Connect the probe."
      writeBlock("M291", 'P"' + msg + '"', "S3", "X1", "Y1", "Z1");
      msg = "Probe connected? Move the tool over the probe plate to probe the " +
      "workplane's Z origin. Press OK to start probing.";
    } else {
      msg += ". Move the tool tip so that it touches the workplane's Z origin.";
    }
    writeBlock("M291", 'P"' + msg + '"', "S3", "X1", "Y1", "Z1");
<<<<<<< HEAD
=======

    // FIX: Ensure that a tool has been selected, but don't override/overwrite
    // the current one
>>>>>>> fa13b77 (Cleanup)
    if (properties.useProbingTool) {
      writeBlock("G53 G38.2 Z{move.axes[2].min}  ; Probe towards Z min"); 
      writeBlock("G10 L20 Z5                     ; Set workplane at 5mm");
    } else {
      writeBlock("G10 L20 Z0 ; Set workplane at 0mm"); 
    }
    raiseZ(); // Raise so we can put on dust shoe
    msg = "";
    if (properties.useProbingTool) {
      msg = "Remove the probe tool. "
    }
    msg += "Set router to " + tool.getSpindleRPM() + " RPM";
    if (properties.routerRPM != NO_ROUTER) {
     msg += ", " + properties.routerRPM + " " + speedSetting(tool.getSpindleRPM()).toFixed(1);
    }
    msg += ". Start the router. Routing will start when you press OK."
    writeBlock("M291", 'P"' + msg + '"', "S3");
  }
  writeBlock("M3", "S" + tool.getSpindleRPM());
}

// onSectionSpecialCycle() is invoked at the start of a section if the section
// contains a cycle that has been marked as special. A section commonly
// corresponds to an individual operation within the CAM system. However, note
// that it is perfectly legal from the post processors perspective if an
// operation generated multiple sections. onSectionSpecialCycle() doesn't do
// anything by default. Use PostProcessor.setSectionSpecialCycle() to mark a
// cycle as special.
// function onSectionSpecialCycle() {
// }

// onDwell() is invoked per dwell command.
//
// @param Number seconds
//
function onDwell(seconds) {
  if (seconds > 99999.999) {
    warning(localize("Dwelling time is out of range."));
  }
  seconds = clamp(0.001, seconds, 99999.999);
  writeBlock("G4", "S" + secFormat.format(seconds));
}


// onRapid() is invoked per linear rapid (high-feed) motion. Make sure to
// prevent dog-leg movement in the generated program.
//
// @param Number _x
// @param Number _y
// @param Number _z
//
function onRapid(_x, _y, _z) {
  var x = xOutput.format(_x);
  var y = yOutput.format(_y);
  var z = zOutput.format(_z);
  if (x || y || z) {
    writeBlock(gMotionModal.format(0), x, y, z);
    feedOutput.reset();
  }
}

// onLinear() is invoked per linear motion.
//
// @param Number _x
// @param Number _y
// @param Number _z
// @param Number feedrate
//
function onLinear(_x, _y, _z, feedrate) {
  // at least one axis is required
  var x = xOutput.format(_x);
  var y = yOutput.format(_y);
  var z = zOutput.format(_z);
  var f = feedOutput.format(feedrate);
  if (x || y || z) {
      writeBlock(gMotionModal.format(1), x, y, z, f);
  } else if (f) {
    if (getNextRecord().isMotion()) { // try not to output feed without motion
      feedOutput.reset(); // force feed on next line
    } else {
      writeBlock(gMotionModal.format(1), f);
    }
  }
}

// onCircular() is invoked per circular motion.
//
// @param Boolean clockwise
// @param Number cx
// @param Number cy
// @param Number cz
// @param Number x
// @param Number y
// @param Number z
// @param Number feedrate
//
function onCircular(clockwise, cx, cy, cz, x, y, z, feedrate) {
  var start = getCurrentPosition();
  var s;
  xOutput.reset();
  yOutput.reset();
  writeBlock(gMotionModal.format(clockwise ? 2 : 3),
    xOutput.format(x),
    yOutput.format(y),
    zOutput.format(z),
    iOutput.format(cx - start.x, 0),
    jOutput.format(cy - start.y, 0),
    feedOutput.format(feedrate));
}

// onRapid5D() is invoked per linear 5-axis rapid motion.
//
// @param Number x
// @param Number y
// @param Number z
// @param Number dx
// @param Number dy
// @param Number dz
//
// function onRapid5D(x, y, z, dx, dy, dz) {
// }

// onLinear5D() is invoked per linear 5-axis motion.
//
// @param Number x
// @param Number y
// @param Number z
// @param Number dx
// @param Number dy
// @param Number dz
// @param Number feedrate
//
// function onLinear5D(x, y, z, dx, dy, dz, feedrate) {
// }

// onRewindMachineEntry() is invoked per for simultaneous 5-axis motion when
// machine axis rewind is required. This is called before performing a machine
// rewind in the kernel, as onRewindMachine() is now deprecated. Several other
// functions need to be implemented for rewind machine to perform properly, such
// as onTurnTCPOff(), onRotateAxes() etc. These are marked with "Required for
// machine rewinds" in this manual.
//
// onRewindMachineEntry(a, b, c) {
// }

// Required for machine rewinds. onMoveToSafeRetractPosition() is invoked during
// a machine rewind procedure. It needs to output the code for retracting to
// safe position before indexing rotaries (usually a retract in Z).
//
// function onMoveToSafeRetractPosition() {
// }

// onMovement() is invoked when the movement type changes. The property movement
// specifies the current movement type.
//
// @param Integer movement
//
function onMovement(movement) {
  switch(movement) {
    case MOVEMENT_RAPID: s = "Rapid"; break;
    case MOVEMENT_LEAD_IN: s = "Lead in"; break;
    case MOVEMENT_CUTTING: s = "Cutting"; break;
    case MOVEMENT_LEAD_OUT: s = "Lead out"; break;
    case MOVEMENT_LINK_TRANSITION: s = "Link transition"; break;
    case MOVEMENT_LINK_DIRECT: s = "Link direct"; break;
    case MOVEMENT_RAMP_HELIX: s = "Ramp helix"; break;
    case MOVEMENT_RAMP_PROFILE: s = "Ramp profile"; break;
    case MOVEMENT_RAMP_ZIG_ZAG: s = "Ramp zig zag"; break;
    case MOVEMENT_RAMP: s = "Ramp"; break;
    case MOVEMENT_PLUNGE: s = "Plunge"; break;
    case MOVEMENT_PREDRILL: s = "Predrill"; break;
    case MOVEMENT_FINISH_CUTTING: s = "Finish cutting"; break;
    case MOVEMENT_REDUCED: s = "Reduced"; break;
    case MOVEMENT_HIGH_FEED: s = "High feed"; break;
    default: s = "Unknown"
  }
  writeComment(s + " move");
}

// onSectionEnd() is invoked at the termination of a section.
//
// function onSectionEnd() {
// }

// Invoked when the spindle speed changes. The property spindleSpeed specifies
// the current spindleSpeed.
//
// @param Number spindleSpeed
//
// function onSpindleSpeed(spindleSpeed) {
// }

// onRadiusCompensation() is invoked when the radius compensation mode changes.
// The property radiusCompensation specifies the current radius compensation
// mode.
//
function onRadiusCompensation() {
  error(localize("Radius compensation mode is not supported."));
}

var mapCommand = {
  COMMAND_STOP: 0,
  COMMAND_END: 2,
  COMMAND_SPINDLE_CLOCKWISE: 3,
  COMMAND_SPINDLE_COUNTERCLOCKWISE: 4,
  COMMAND_STOP_SPINDLE: 5
};

// onCommand() is invoked for well-known commands (e.g. stop spindle).
// This are only called for manually added commands.
//
// @param Integer command
//
function onCommand(command) {
  writeComment("onCommand", command);
  switch (command) {
    case COMMAND_STOP:          // Program stop (M0)
    case COMMAND_OPTIONAL_STOP: // Optional program stop (M1)
    case COMMAND_END:           // Program end (M2)
    case COMMAND_SPINDLE_CLOCKWISE: // Clockwise spindle direction (M3)
    case COMMAND_SPINDLE_COUNTERCLOCKWISE: // Counterclockwise spindle direction (M4)
      writeBlock(mFormat.format(mapCommand[command]), "S"+tool.getSpindleRPM());
      return;
    case COMMAND_START_SPINDLE: // Start spindle M3 (clockwise) or M4 (counterclockwise)
      onCommand(tool.clockwise ? COMMAND_SPINDLE_CLOCKWISE : COMMAND_SPINDLE_COUNTERCLOCKWISE);
      return;
    case COMMAND_STOP_SPINDLE: //  Stop spindle (M5)
      writeBlock("M5");
      return;

    case COMMAND_ORIENTATE_SPINDLE: // Orientate spindle - +X direction by default (M19)
    case COMMAND_LOAD_TOOL: // Tool change (M6)
    case COMMAND_COOLANT_ON: // Coolant on (M8)
    case COMMAND_COOLANT_OFF: // Coolant off (M9)
    case COMMAND_ACTIVATE_SPEED_FEED_SYNCHRONIZATION: // Active feed-speed synchronization
    case COMMAND_DEACTIVATE_SPEED_FEED_SYNCHRONIZATION: // Deactive feed-speed synchronization
    case COMMAND_LOCK_MULTI_AXIS: // Locks the 4th and 5th axes
    case COMMAND_UNLOCK_MULTI_AXIS: // Unlocks the 4th and 5th axes
    case COMMAND_EXACT_STOP: // Exact stop
    case COMMAND_START_CHIP_TRANSPORT: // Close chip transport
    case COMMAND_STOP_CHIP_TRANSPORT: // Stop chip transport
    case COMMAND_OPEN_DOOR: // Open primary door
    case COMMAND_CLOSE_DOOR: // Close primary door
    case COMMAND_BREAK_CONTROL: // Break control
    case COMMAND_TOOL_MEASURE: // Measure tool
    case COMMAND_CALIBRATE: // Run calibration cycle
    case COMMAND_VERIFY: // Verify part/tool/machine integrity
    case COMMAND_CLEAN: // Run cleaning cycle
    case COMMAND_ALARM: // Alarm
    case COMMAND_ALERT: // Alert
    case COMMAND_CHANGE_PALLET: // Change pallet
    case COMMAND_POWER_ON: // Power on
    case COMMAND_POWER_OFF: // Power off
    case COMMAND_MAIN_CHUCK_OPEN: // Open main chuck
    case COMMAND_MAIN_CHUCK_CLOSE: // Close main chuck
    case COMMAND_SECONDARY_CHUCK_OPEN: // Open secondary chuck
    case COMMAND_SECONDARY_CHUCK_CLOSE: // Close secondary chuck
    case COMMAND_SECONDARY_SPINDLE_SYNCHRONIZATION_ACTIVATE: // Activate spindle synchronization
    case COMMAND_SECONDARY_SPINDLE_SYNCHRONIZATION_DEACTIVATE: // Deactivate spindle synchronization
    case COMMAND_SYNC_CHANNEL: // Sync channels
    case COMMAND_PROBE_ON: // Probe on
    case COMMAND_PROBE_OFF: // Probe off
      return;
    };
}

// onClose() is invoked at post processing completion. This is the place to
// output your program footer.
//
function onClose() {
  writeBlock("M5  ; Stop spindle");
  raiseZ();
}
