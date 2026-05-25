# Glass Pane System Documentation

## Overview
Minecraft-style auto-connecting glass panes for a Roblox building game. Glass panes automatically detect neighboring glass and change their model/rotation to create seamless connections.

**NEW: Glass panes can now be placed in two orientations based on camera direction:**
- **NS (North/South)**: Thin along Z axis, connects on X and Y
- **EW (East/West)**: Thin along X axis, connects on Z and Y

Glass panes only connect to other glass of the **same orientation**, allowing perpendicular glass walls.

## Glass Models (in `ReplicatedStorage/Decorations/Glass/`)

| Model | Connection Type | Description |
|-------|----------------|-------------|
| Glass_0 | isolated | Frame on all 4 edges (standalone pane) |
| Glass_1 | corner | Frame on 2 perpendicular edges (L-shaped) |
| Glass_2 | single | Frame on 1 edge (3 neighbors) |
| Glass_3 | blank | No frame visible (4 neighbors, fully connected) |
| Glass_4 | three_edge | Frame on 3 edges (1 neighbor) |
| Glass_5 | straight | Frame on 2 opposite edges (2 opposite neighbors) |

## Orientation System

Glass orientation is determined by camera look direction:
- Looking more along **Z axis** → **NS** glass (thin along Z)
- Looking more along **X axis** → **EW** glass (thin along X)

```lua
function GlassPlacement.GetOrientationFromLookVector(lookVector)
    local absX = math.abs(lookVector.X)
    local absZ = math.abs(lookVector.Z)
    
    if absX > absZ then
        return "EW"  -- Looking along X -> thin along X
    else
        return "NS"  -- Looking along Z -> thin along Z
    end
end
```

## Direction System

Glass panes connect on 4 directions. The horizontal directions depend on orientation:

**NS Orientation (thin along Z):**
```
Direction Index | Name    | Offset
----------------|---------|------------------
0               | UP      | (0, +3, 0)  +Y
1               | DOWN    | (0, -3, 0)  -Y
2               | PLUS_X  | (+3, 0, 0)  +X
3               | MINUS_X | (-3, 0, 0)  -X
```

**EW Orientation (thin along X):**
```
Direction Index | Name    | Offset
----------------|---------|------------------
0               | UP      | (0, +3, 0)  +Y
1               | DOWN    | (0, -3, 0)  -Y
2               | PLUS_Z  | (0, 0, +3)  +Z
3               | MINUS_Z | (0, 0, -3)  -Z
```

Block size is 3 studs.

## Connection Type Determination

Based on neighbor count (only same-orientation neighbors count):
- **4 neighbors** → `blank` (Glass_3) - fully surrounded
- **3 neighbors** → `single` (Glass_2) - frame on missing side
- **2 neighbors (opposite)** → `straight` (Glass_5) - frames on both missing sides
- **2 neighbors (perpendicular)** → `corner` (Glass_1) - L-shaped frame
- **1 neighbor** → `three_edge` (Glass_4) - frame on 3 sides
- **0 neighbors** → `isolated` (Glass_0) - frame on all 4 sides

## Rotation Logic

### Base Rotation by Orientation
- **NS**: No base rotation (identity)
- **EW**: 90° Y rotation applied first

### Connection Rotation (applied on top of base)
Same as before, but the base rotation handles the orientation difference.

### Isolated (Glass_0)
No additional rotation needed - symmetric on all sides.

### Single Edge (Glass_2)
`primaryDir` = the MISSING direction (where frame should face)
```lua
[0] UP:     CFrame.Angles(0, 0, 0)                    -- default
[1] DOWN:   CFrame.Angles(math.rad(180), 0, 0)       -- flip
[2] +H:     CFrame.Angles(0, 0, math.rad(-90))       -- rotate on Z
[3] -H:     CFrame.Angles(0, 0, math.rad(90))        -- rotate on Z
```

### Straight (Glass_5)
`primaryDir` = one of the MISSING directions
```lua
if primaryDir == 2 or primaryDir == 3 then
    -- Vertical stack (neighbors UP/DOWN, missing horizontal)
    return CFrame.Angles(0, 0, math.rad(90))
else
    -- Horizontal row (neighbors horizontal, missing UP/DOWN)
    return CFrame.Angles(0, 0, 0)
end
```

### Corner (Glass_1)
`primaryDir` and `secondaryDir` = the two MISSING directions
```lua
UP + +H:    CFrame.Angles(0, math.rad(180), 0)
UP + -H:    CFrame.Angles(0, 0, 0)
DOWN + +H:  CFrame.Angles(math.rad(180), math.rad(180), 0)
DOWN + -H:  CFrame.Angles(math.rad(180), 0, 0)
```

### Three Edge (Glass_4)
`primaryDir` = the CONNECTED direction (open side faces this way)
```lua
[0] Open UP:    CFrame.Angles(0, 0, math.rad(90))
[1] Open DOWN:  CFrame.Angles(0, 0, math.rad(-90))
[2] Open +H:    CFrame.Angles(0, 0, 0)              -- default
[3] Open -H:    CFrame.Angles(0, math.rad(180), 0)  -- flip 180
```

## Key Files

### Server
- `src/Server/BlockHandler.server.luau` - Handles glass placement, calls GlassPlacement module

### Shared
- `src/Shared/GlassPlacement.luau` - Core glass logic:
  - `IsGlass(blockType)` - Check if block type is glass
  - `GetOrientationFromLookVector(lookVector)` - Get NS or EW from camera direction
  - `GetGlassNeighbors(position, blocksFolder, orientation)` - Find adjacent glass of same orientation
  - `DetermineConnectionType(neighbors)` - Returns connectionType, primaryDir, secondaryDir
  - `GetGlassRotation(connectionType, primaryDir, secondaryDir, orientation)` - Returns CFrame rotation
  - `GetPlacementInfo(blockType, position, blocksFolder, orientation, debugOutput)` - Full placement data
  - `UpdateAdjacentGlass(position, blocksFolder, createFunc, orientation)` - Update neighbors when glass placed/broken

- `src/Shared/BlockPresets.luau` - Glass preset definition:
  - Uses `Glass_0` for inventory icon
  - `BlockModelFolder = "Decorations/Glass"`
  - `IsGlass = true` flag

### Client
- `src/Client/BuildingController.client.luau` - Handles:
  - Ghost preview with correct orientation
  - Orientation detection from camera
  - Sends `GlassData.Orientation` with placement request

## Neighbor Update Flow

When a glass pane is placed:
1. Client detects orientation from camera direction
2. Client sends placement with `GlassData.Orientation`
3. Server calculates placement info for new glass with that orientation
4. Server places new glass with correct model/rotation
5. Server calls `UpdateAdjacentGlass()` with the orientation, which:
   - Checks all 4 directions for existing glass **of same orientation**
   - Recalculates each neighbor's connection type
   - If changed, destroys old and creates new with updated model/rotation

## Attributes Stored on Glass Blocks

```lua
block:SetAttribute("BlockType", "Glass")
block:SetAttribute("IsGlass", true)
block:SetAttribute("GlassOrientation", orientation)             -- "NS" or "EW"
block:SetAttribute("GlassConnectionType", connectionType)       -- "blank", "single", etc.
block:SetAttribute("GlassPrimaryDir", primaryDir)               -- 0-3 or nil
block:SetAttribute("GlassSecondaryDir", secondaryDir)           -- 0-3 or nil
block:SetAttribute("PlacedBy", playerId)
```

## Common Issues & Solutions

### Glass laying flat instead of standing
- Check rotation logic for that connection type
- Three_edge and straight pieces need 90° Z rotation to stand upright

### Frame facing wrong direction
- Swap the rotation values for the affected directions
- Remember: `primaryDir` meaning differs by type (MISSING vs CONNECTED direction)

### Neighbors not updating
- Ensure `UpdateAdjacentGlass` is called after placement
- Check position tolerance in `GetGlassAtPosition` (currently 1.5 studs)
- **NEW**: Glass only connects to same-orientation glass - check orientations match

### Perpendicular glass not connecting
- This is expected behavior! NS and EW glass are separate connection networks
- This allows building L-shaped or T-shaped walls with clean edges

## Future Enhancements
- Ghost preview showing correct orientation before placement ✓ (implemented)
- Colored glass variants
- Glass blocks (full 3x3x3 cubes, not panes)
