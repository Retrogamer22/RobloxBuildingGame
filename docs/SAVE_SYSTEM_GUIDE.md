# Save System Guide

## Overview

The save system automatically saves and loads player builds using Roblox DataStore. It handles:
- Block positions, types, and rotations
- All block attributes (states, settings, connections)
- Terrain modifications (dug holes)
- Wire connections between blocks
- Special states (piston extension, door open/closed, etc.)

---

## How It Works

### Automatic Saving

**ALL attributes on blocks are saved by default**, except those in the blacklist. You don't need to register new attributes - just set them on your block and they'll persist.

```lua
-- These will ALL save automatically:
block:SetAttribute("MyNewAttribute", "value")
block:SetAttribute("SomeNumber", 42)
block:SetAttribute("IsEnabled", true)
```

### Files Involved

| File | Purpose |
|------|---------|
| `src/Shared/PlotSerializer.luau` | Converts blocks to/from save format |
| `src/Server/SaveManager.server.luau` | Handles DataStore and block recreation |
| `src/Shared/BlockPresets.luau` | Block definitions (templates, shapes) |

---

## Adding New Blocks (Zero Code Needed)

### Step 1: Define the Block Preset

In `BlockPresets.luau`, add your block definition:

```lua
["MyNewBlock"] = {
    Shape = "Cube",           -- Or "Stair", "Slab", "Fence", etc.
    DefaultColor = Color3.fromRGB(255, 128, 0),
    Material = Enum.Material.SmoothPlastic,
    -- Optional:
    BlockModelName = "MyNewBlock",  -- If using a model from Blocks folder
    IsDoor = false,
    IsFence = false,
    IsDecoration = false,
},
```

### Step 2: Create the Block Model (if needed)

Place your block model in one of these locations:
- `ReplicatedStorage/Blocks/` - For full block models
- `ReplicatedStorage/BlockTemplates/` - For template shapes
- `ReplicatedStorage/Decorations/` - For decorations

### Step 3: Set Attributes When Placing

In your placement code, set any attributes your block needs:

```lua
block:SetAttribute("BlockType", "MyNewBlock")
block:SetAttribute("MyCustomState", "default")
block:SetAttribute("PowerLevel", 0)
-- These ALL save automatically!
```

**That's it!** The block will save and load with all its attributes.

---

## When You Need Extra Code

### Scenario 1: Transient/Internal Attributes (DON'T Save)

If an attribute should NOT be saved (temporary states, computed values):

**Edit `PlotSerializer.luau` - Add to `AttributeBlacklist`:**

```lua
local AttributeBlacklist = {
    -- ... existing entries ...
    ["MyTransientState"] = true,    -- ADD HERE
    ["ComputedValue"] = true,       -- ADD HERE
}
```

### Scenario 2: Visual State Restoration (Physical Changes)

If your block has visual/physical state that needs restoration on load (like piston extension, animated doors, etc.):

**Edit `SaveManager.server.luau` - Find `createBlockFromSave` function, add before `block.Parent = blocksFolder`:**

```lua
-- Handle MyNewBlock special state
local isMyBlock = blockData.blockType == "MyNewBlock"
if isMyBlock and blockData.attributes.IsActivated then
    -- Restore visual state here
    local glowPart = block:FindFirstChild("GlowPart")
    if glowPart then
        glowPart.Transparency = 0
        glowPart.Color = Color3.new(1, 1, 0)
    end
    print("[SaveManager] Restored MyNewBlock activated state")
end
```

**Examples of things that need visual restoration:**
- Piston arm extended position
- Trapdoor rotated open
- Lever flipped position
- Any part that moves/scales/changes

**Examples that DON'T need visual restoration:**
- Door IsOpen (client handles the visual via DoorStateChanged remote)
- Lamp IsPowered (already handled)
- Any attribute that's just data, not physical state

### Scenario 3: Compression for Common Attributes (Optional)

If an attribute is used on MANY blocks and you want smaller save files:

**Edit `PlotSerializer.luau` - Add to `ExtraKeyShort`:**

```lua
local ExtraKeyShort = {
    -- ... existing entries ...
    ["MyCommonAttribute"] = "mca",  -- Short code (2-3 chars)
}
```

> **Note:** This is purely optional optimization. Attributes work fine without short codes.

### Scenario 4: Dynamic Attribute Patterns (Like WireConn_1, WireConn_2)

If you have numbered/dynamic attributes like `Slot_1`, `Slot_2`, `Slot_3`:

**Edit `PlotSerializer.luau` - In `serializeExtraData` function:**

```lua
-- Handle dynamic Slot_ attributes (add near the WireConn_ handling)
local slotValues = {}
for attrName, value in pairs(allAttributes) do
    if string.sub(attrName, 1, 5) == "Slot_" then
        local slotNum = tonumber(string.sub(attrName, 6))
        if slotNum then
            slotValues[slotNum] = value
        end
    end
end
if next(slotValues) then
    extra["slots"] = slotValues
    hasExtra = true
end
```

**Edit `PlotSerializer.luau` - In `deserializeExtraData` function:**

```lua
-- Handle slots
if key == "slots" and type(value) == "table" then
    attributes["_SlotValues"] = value
```

**Edit `SaveManager.server.luau` - In `createBlockFromSave` function:**

```lua
-- Restore Slot_ attributes
local slotValues = blockData.attributes._SlotValues
if slotValues then
    for slotNum, val in pairs(slotValues) do
        block:SetAttribute("Slot_" .. slotNum, val)
    end
end
```

---

## Common Pitfalls & Solutions

### Problem: Block loads in wrong position

**Cause:** Block model has unexpected pivot point

**Check:** Does your model have pivot at bottom-center or true center?
- Models in `Blocks/` folder typically have bottom-center pivot
- The save system applies a -1.5 Y offset for these

**Solution:** If your block needs different handling, check the positioning logic in `createBlockFromSave` around line 450.

### Problem: Attribute not saving

**Cause 1:** Attribute is in blacklist
- Check `AttributeBlacklist` in PlotSerializer.luau

**Cause 2:** Attribute value is `false`
- False booleans are intentionally skipped to save space
- On load, missing boolean = false (the default)

**Cause 3:** Attribute name starts with `_`
- Internal attributes starting with `_` are used for special handling
- They won't be set directly on the block

### Problem: Block not loading at all

**Cause 1:** No preset defined
```
[SaveManager] Unknown block type: MyBlock
```
- Add entry to `BlockPresets.luau`

**Cause 2:** Template not found
```
[SaveManager] No template found for: MyBlock (Cube)
```
- Check model exists in `Blocks/` or `BlockTemplates/`
- Check `BlockModelName` in preset matches actual model name

### Problem: Wire connections not working after load

**Cause:** BlockId not set when block was placed

**Solution:** Ensure BlockId is set when your wirable block is placed:
```lua
local HttpService = game:GetService("HttpService")
block:SetAttribute("BlockId", HttpService:GenerateGUID(false))
```

### Problem: Visual state not restored (block looks wrong)

**Cause:** No restoration code for physical state changes

**Solution:** Add visual restoration in `createBlockFromSave` (see Scenario 2)

---

## Testing Checklist

When adding a new block type:

- [ ] Block preset defined in `BlockPresets.luau`
- [ ] Block model exists in correct folder
- [ ] Place block in game
- [ ] Set attributes correctly when placing
- [ ] Save game (click sign or use save UI)
- [ ] Load game
- [ ] Verify block position correct
- [ ] Verify all attributes restored (check with explorer)
- [ ] Verify visual state correct (if has animated/physical states)
- [ ] Test with wiring (if wireable block)
- [ ] Test breaking and re-placing

---

## Quick Reference Tables

### What Saves Automatically (No Code Needed)
| Data | Example | Notes |
|------|---------|-------|
| Position | X, Y, Z grid coords | Automatic |
| Rotation | 0, 90, 180, 270 | Via `Rotation` attribute |
| Block type | "OakStair" | Via `BlockType` attribute |
| All custom attributes | Any you set | Automatic! |
| Wire connections | `WireConn_1`, etc. | Automatic |
| Colors | RGB values | For template blocks |

### What Needs Blacklisting (Add to AttributeBlacklist)
| Type | Examples | Why |
|------|----------|-----|
| Transient states | `BeingPushed`, `IsHovered` | Only valid during gameplay |
| Computed values | `TerrainDepth`, `SurfaceY` | Recalculated on load |
| Internal flags | `BeingRemovedBySaveSystem` | System use only |
| Position cache | `BlockPosX/Y/Z` | Recalculated from grid |

### What Needs Visual Restoration (Add to createBlockFromSave)
| Block Type | State | What to Restore |
|------------|-------|-----------------|
| Piston | IsExtended | Move PistonTop, scale PistonArm |
| Lamp | IsPowered | Enable/disable Light objects |
| Lever | IsOn | Rotate lever handle |
| Trapdoor | IsOpen | Rotate trapdoor hinge |

### Current Short Codes (ExtraKeyShort)
| Attribute | Code | Attribute | Code |
|-----------|------|-----------|------|
| IsUpsideDown | u | DoorDirection | dd |
| CornerType | c | DoorDepth | dp |
| StairDirection | sd | DoorHingeSide | dh |
| LogAxis | la | IsOpen | o |
| SlabOrientation | so | IsPowered | pw |
| SurfaceFace | sf | IsExtended | ext |
| FenceConnectionType | fc | BlockId | bid |
| Rotation | r | IsDecoration | deco |

---

## Example: Adding a Lever Block

### 1. Add Preset (BlockPresets.luau)
```lua
["StoneLever"] = {
    Shape = "Lever",
    BlockModelName = "StoneLever",
    DefaultColor = Color3.fromRGB(128, 128, 128),
    Material = Enum.Material.Slate,
},
```

### 2. Create Model
- Create `StoneLever` model in `ReplicatedStorage/Blocks/`
- Include a `LeverHandle` part that rotates

### 3. Set Attributes When Placing
```lua
block:SetAttribute("BlockType", "StoneLever")
block:SetAttribute("BlockId", HttpService:GenerateGUID(false))
block:SetAttribute("IsOn", false)
block:SetAttribute("SurfaceFace", "Front")  -- Which face it's on
```

### 4. Add Visual Restoration (SaveManager.server.luau)
```lua
-- Handle lever state
local isLever = string.find(blockData.blockType, "Lever") ~= nil
if isLever and blockData.attributes.IsOn then
    local handle = block:FindFirstChild("LeverHandle")
    if handle then
        -- Rotate handle to "on" position
        handle.CFrame = handle.CFrame * CFrame.Angles(math.rad(45), 0, 0)
    end
    print("[SaveManager] Restored lever ON state")
end
```

### 5. Done!
The lever will now:
- Save its on/off state
- Save wire connections
- Restore physical handle position on load
- Work with wiring system

---

## Version History

| Version | Changes |
|---------|---------|
| 1 | Initial save system |
| 2 | Multi-depth dug tracking, lazy-loaded blocks |
| 2.1 | Piston state, wire connections, future-proof attribute saving |
