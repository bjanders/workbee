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
// - Set feed only at beginning of move
// - Show router specific RPM settings for Makita and DeWalt routerss
//
// Todo:
// - Implement onCommand() commands 
// - Optional XY probing, manual and auto

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


const NO_ROUTER = "Do not show";

// user-defined properties
properties = {
  showSequenceNumbers: false, // show sequence numbers
  sequenceNumberStart: 10, // first sequence number
  toolChangePrompt: true,
  useProbingTool: false,
  routerRPM: NO_ROUTER
};


// user-defined property definitions
propertyDefinitions = {
  showSequenceNumbers: {
    title: "Use sequence numbers",
    description: "Use sequence numbers for each block of outputted code.",
    group: 1,
    type:"boolean"
  },
  sequenceNumberStart:
    {title: "Start sequence number",
    description: "The number at which to start the sequence numbers.",
    group: 1,
    type: "integer"
  },
  toolChangePrompt: {
    title: "Prompt for tool change",
    description: "Prompts to change tool and probe between operations if the tool changes",
    type: "boolean"
  },
  useProbingTool: { 
    title: "Use probing tool",
    description: "Use a probing tool to automatically probe for Z-origin during tool change, else manual probing will be performed.",
    type: "boolean"
  },
  routerRPM: {
    title: "Show router RPM dial setting",
    description: "On tool change, in addition to showing RPM values show the router specific setting",
    type: "enum",
    values: [NO_ROUTER, "Makita", "DeWalt"]
  }
};



var gFormat = createFormat({prefix:"G", decimals:0});
var mFormat = createFormat({prefix:"M", decimals:0});
var iFormat = createFormat({decimals:0});

var xyzFormat = createFormat({decimals:(unit == MM ? 3 : 4), trim:false});
var feedFormat = createFormat({decimals:(unit == MM ? 1 : 2)});
var secFormat = createFormat({decimals:3, forceDecimal:true}); // seconds - range 0.001-1000

var xOutput = createVariable({prefix:"X", force:true}, xyzFormat);
var yOutput = createVariable({prefix:"Y", force:true}, xyzFormat);
var zOutput = createVariable({prefix:"Z", force:true}, xyzFormat);
var feedOutput = createVariable({prefix:"F", force:false}, feedFormat);
var pParam = createVariable({prefix:"P", force:true}, iFormat);

// circular output
var iOutput = createReferenceVariable({prefix:"I", force:true}, xyzFormat);
var jOutput = createReferenceVariable({prefix:"J", force:true}, xyzFormat);

var gMotionModal = createModal({force:true}, gFormat); // modal group 1 // G0-G3, ...
var gAbsIncModal = createModal({}, gFormat); // modal group 3 // G90-91
var gUnitModal = createModal({}, gFormat); // modal group 6 // G20-21

// collected state
var sequenceNumber;

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
  rSpeeds = routerSpeeds[properties.routerRPM];
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
if (properties.showSequenceNumbers) {
    writeWords2("N" + sequenceNumber, arguments);
    sequenceNumber++;
  } else {
    writeWords(arguments);
  }
}

function writeComment(){
  writeWords(";", arguments);
}

function onOpen() {

  sequenceNumber = properties.sequenceNumberStart;

  if (hasParameter("generated-at")) {
    var generatedAt = getParameter("generated-at");
    if (generatedAt) {
      writeComment("Generated on " + generatedAt);
    }
  }

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

  if (unit == IN) {
    error(localize("Please select millimeters as unit when post processing."));
    return;
  }
  writeBlock(gUnitModal.format(21));    // Units in mm
  writeBlock(gAbsIncModal.format(90));  // absolute coordinates

}

function onComment(message) {
  writeComment(message);
}

function homeZ() {
  //writeBlock('M98 P"homez.g"');
  writeBlock("G91");
  writeBlock("G1 H1 Z94 F1500");
  writeBlock("G1 Z-3 F2400");	// go back 3mm
  writeBlock("G1 H1 Z94 F300");//  move slowly to Z axis endstop
  writeBlock("G90"); 		// absolute positioning
}

function onSection() {
  
  var insertToolCall = isFirstSection() ||
    currentSection.getForceToolChange && currentSection.getForceToolChange() ||
    (tool.toolId != getPreviousSection().getTool().toolId);

  writeln("");

  if (hasParameter("operation-comment")) {
    var comment = getParameter("operation-comment");
    if (comment) {
      writeComment(comment);
    }
  }


  if (properties.toolChangePrompt && insertToolCall) {
    homeZ(); // Raise so we can remove dust shoe and insert tool
    var msg = "Insert tool #" + tool.number;
    if (tool.description) {
      toolDesc = tool.description.replace('"','""')
      msg += ": " + toolDesc;
      toolName = 'S"' + toolDesc + '"';
    } else {
      toolName = 'S"Unnamed"';
    }
    if (properties.useProbingTool) {
      msg += ". Connect the probe."
      writeBlock("M291", 'P"' + msg + '"', "S3");
      msg = "Probe connected? Move the tool over the probe plate to probe the " +
      "workplane's Z origin. Press OK to start probing.";
    } else {
      msg += ". Move the tool tip so that it touches the workplane's Z origin.";
    }
    writeBlock("M291", 'P"' + msg + '"', "S3", "X1", "Y1", "Z1");
    writeBlock("M563", pParam.format(tool.number), toolName);  // Define tool
    writeBlock("T" + tool.number); // Select tool
    if (properties.useProbingTool) {
      writeBlock("M585 Z15 E3 L0 F500 S1");
      // Z15  Expected distance 15mm
      // E3   Endstop 3
      // L0   Trigger leve active low
      // F500 Feedrate 500mm/min
      // S1   Move probe towards axis minimum
      writeBlock("G10 L20 Z5"); // Set workplane Z offset 5mm above tool position 
    } else {
      writeBlock("G10 L20 Z0"); // Set workplane Z offset to tool position 
    }
    homeZ(); // Raise so we can put on dust shoe
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
}

function onSectionEnd() {
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

function onClose() {
  //writeBlock("T-1"); // Remove tool
  homeZ();
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
