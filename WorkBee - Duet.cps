// WorkBee - Duet post processor
//
// Modified by Bjorn Andersson <bjorn@iki.fi>, based on the procsessor
// provided by Ooznest.
//
// Changes compared to Ooznest's processor:
// - Cleanup of unused code
// - Tool change prompts
// - Z probing during tool change
// - Helical moves using G2/G3
// - maxCircularSweep 360 degrees
// - Move comments in the G-code
// - Set feed only at beginning of move

//
// Todo:
// - Probing selectable between manual Z probing and probe tool
// - DeWalt RPM scale
// - DeWalt/Makita/None selectable
// - Optimize by not outputting coordinates if they don't change from previous move
// - Implement onCommand() commands 

// PostProcessor attributes
description = "WorkBee - Duet";
longDescription = "Milling post for WorkBee CNC Machine by bjorn@iki.fi.";
vendor = "Ooznest";
vendorUrl = "https://ooznest.co.uk/";
legal = "";
certificationLevel = 2;
minimumRevision = 24000;

extension = "nc";
setCodePage("ascii");

capabilities = CAPABILITY_MILLING;
tolerance = spatial(0.002, MM);

minimumChordLength = spatial(0.25, MM);
minimumCircularRadius = spatial(0.01, MM);
maximumCircularRadius = spatial(1000, MM);
minimumCircularSweep = toRad(0);
maximumCircularSweep = toRad(360);
allowHelicalMoves = true;
allowSpiralMoves = false;
allowedCircularPlanes = (1 << PLANE_XY) 

// user-defined properties
properties = {
  writeMachine: true, // write machine
  showSequenceNumbers: false, // show sequence numbers
  sequenceNumberStart: 10, // first sequence number
  sequenceNumberIncrement: 1, // increment for sequence numbers
  separateWordsWithSpace: true, // specifies that the words should be separated with a white space
  toolChangePrompt: true
};

// user-defined property definitions
propertyDefinitions = {
  writeMachine: {title:"Write machine", description:"Output the machine settings in the header of the code.", group:0, type:"boolean"},
  showSequenceNumbers: {title:"Use sequence numbers", description:"Use sequence numbers for each block of outputted code.", group:1, type:"boolean"},
  sequenceNumberStart: {title:"Start sequence number", description:"The number at which to start the sequence numbers.", group:1, type:"integer"},
  sequenceNumberIncrement: {title:"Sequence number increment", description:"The amount by which the sequence number is incremented by in each block.", group:1, type:"integer"},
  separateWordsWithSpace: {title:"Separate words with space", description:"Adds spaces between words if 'yes' is selected.", type:"boolean"},
  toolChangePrompt: {title:"Prompt for tool change", descriptions:"Prompts to change tool and probe between operations if the tool changes", type:"boolean"}
};

var gFormat = createFormat({prefix:"G", decimals:0});
var mFormat = createFormat({prefix:"M", decimals:0});

var xyzFormat = createFormat({decimals:(unit == MM ? 3 : 4), trim:false});
var feedFormat = createFormat({decimals:(unit == MM ? 1 : 2)});
var secFormat = createFormat({decimals:3, forceDecimal:true}); // seconds - range 0.001-1000

var xOutput = createVariable({prefix:"X", force:true}, xyzFormat);
var yOutput = createVariable({prefix:"Y", force:true}, xyzFormat);
var zOutput = createVariable({prefix:"Z", force:true}, xyzFormat);
var feedOutput = createVariable({prefix:"F", force:false}, feedFormat);

// circular output
var iOutput = createReferenceVariable({prefix:"I", force:true}, xyzFormat);
var jOutput = createReferenceVariable({prefix:"J", force:true}, xyzFormat);

var gMotionModal = createModal({force:true}, gFormat); // modal group 1 // G0-G3, ...
var gAbsIncModal = createModal({}, gFormat); // modal group 3 // G90-91
var gUnitModal = createModal({}, gFormat); // modal group 6 // G20-21

// collected state
var sequenceNumber;

const makitaSpeeds = [
  10000.0,
  12000.0,
  17000.0,
  22000.0,
  27000.0,
  30000.0,
];

function speedSetting(speed) {
  if (speed <= makitaSpeeds[0]) {
    return 1;
  }
  const highestSetting = makitaSpeeds.length
  const highestSpeed = makitaSpeeds[highestSetting - 1];
  if (speed >= highestSpeed) {
    return highestSetting;
  }
  for (var i = 1; i < highestSetting; i++) {
    mSpeed = makitaSpeeds[i]
    if (mSpeed >= speed) {
      mSetting = (speed - makitaSpeeds[i-1]) / (mSpeed - makitaSpeeds[i-1]) + i;
      return mSetting;
    }
  }
  return undefined;
}
 
function writeBlock() {
if (properties.showSequenceNumbers) {
    writeWords2("N" + sequenceNumber, arguments);
    sequenceNumber += properties.sequenceNumberIncrement;
  } else {
    writeWords(arguments);
  }
}

function writeComment(text) {
  var comment = "(" + String(text).replace(/[()]/g, "") + ")";
  writeln(comment);
}

function onOpen() {
  if (!properties.separateWordsWithSpace) {
    setWordSeparator("");
  }

  sequenceNumber = properties.sequenceNumberStart;

  if (programName) {
    writeComment(programName);
  }
  if (programComment) {
    writeComment(programComment);
  }

  if (properties.writeMachine) {
    // dump machine configuration
    var vendor = machineConfiguration.getVendor();
    var model = machineConfiguration.getModel();
    var description = machineConfiguration.getDescription();
    if (vendor || model || description) {
      writeComment(localize("Machine"));
    }
    if (vendor) {
      writeComment("  " + localize("vendor") + ": " + vendor);
    }
    if (model) {
      writeComment("  " + localize("model") + ": " + model);
    }
    if (description) {
      writeComment("  " + localize("description") + ": "  + description);
    }
  }

  switch (unit) {
  case IN:
    error(localize("Please select millimeters as unit when post processing."));
    return;
  case MM:
    writeBlock(gUnitModal.format(21));
    break;
  }
  // absolute coordinates
  writeBlock(gAbsIncModal.format(90));
}

function onComment(message) {
  writeComment(message);
}

function onSection() {
  
  var insertToolCall = isFirstSection() ||
    currentSection.getForceToolChange && currentSection.getForceToolChange() ||
    (tool.number != getPreviousSection().getTool().number);

  writeln("");

  if (hasParameter("operation-comment")) {
    var comment = getParameter("operation-comment");
    if (comment) {
      writeComment(comment);
    }
  }

  if (properties.toolChangePrompt && insertToolCall) {
    var msg = "Insert tool #" + tool.number;
    if (tool.description) {
      msg += ": " + tool.description.replace('"','""')
    }
    msg += ". Set router to " + tool.getSpindleRPM() + " RPM";
    msg += ". Makita " + speedSetting(tool.getSpindleRPM()).toFixed(1);
    msg += ". Jog to Z probe position."
    writeBlock("M291", 'P"' + msg + '"', "S3", "X1", "Y1", "Z1");
    writeBlock("G30");
  }

}

function onDwell(seconds) {
  if (seconds > 99999.999) {
    warning(localize("Dwelling time is out of range."));
  }
  seconds = clamp(0.001, seconds, 99999.999);
  writeBlock(gFormat.format(4), "P" + secFormat.format(seconds));
}

function onRadiusCompensation() {
  error(localize("Radius compensation mode is not supported."));
}

function onRapid(_x, _y, _z) {
  var x = xOutput.format(_x);
  var y = yOutput.format(_y);
  var z = zOutput.format(_z);
  if (x || y || z) {
    writeBlock(gMotionModal.format(0), x, y, z);
    feedOutput.reset();
  }
}

function onLinear(_x, _y, _z, feed) {
  // at least one axis is required
  var x = xOutput.format(_x);
  var y = yOutput.format(_y);
  var z = zOutput.format(_z);
  var f = feedOutput.format(feed);
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

function onCircular(clockwise, cx, cy, cz, x, y, z, feed) {
  var start = getCurrentPosition();
  writeBlock(gMotionModal.format(clockwise ? 2 : 3), xOutput.format(x), yOutput.format(y), zOutput.format(z), iOutput.format(cx - start.x, 0), jOutput.format(cy - start.y, 0), feedOutput.format(feed));
}

var mapCommand = {
  COMMAND_STOP: 0,
  COMMAND_END: 2,
  COMMAND_SPINDLE_CLOCKWISE: 3,
  COMMAND_SPINDLE_COUNTERCLOCKWISE: 4,
  COMMAND_STOP_SPINDLE: 5
};

function onCommand(command) {
  switch (command) {
  case COMMAND_START_SPINDLE:
    onCommand(tool.clockwise ? COMMAND_SPINDLE_CLOCKWISE : COMMAND_SPINDLE_COUNTERCLOCKWISE);
    return;
  case COMMAND_LOCK_MULTI_AXIS:
    return;
  case COMMAND_UNLOCK_MULTI_AXIS:
    return;
  case COMMAND_BREAK_CONTROL:
    return;
  case COMMAND_TOOL_MEASURE:
    return;
  }

  var stringId = getCommandStringId(command);
  var mcode = mapCommand[stringId];
  if (mcode != undefined) {
    writeBlock(mFormat.format(mcode));
  } else {
    onUnsupportedCommand(command);
  }
}

function onSectionEnd() {
}

function onClose() {
}

function onMovement(movement) {
  feedOutput.reset();
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
