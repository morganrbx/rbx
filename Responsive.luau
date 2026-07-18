local Workspace = game:GetService("Workspace")
local UserInputService = game:GetService("UserInputService")

-- Viewport-driven UI scaling. The package's GUIs are authored in fixed offset
-- pixels against a reference resolution; on their own they'd render the same
-- physical pixel size on a 4K monitor, a phone, and a TV. `Responsive.apply`
-- parents a UIScale to a GuiObject and keeps its Scale tied to the live viewport
-- so those fixed layouts stay proportional everywhere:
--   * phones/tablets scale the panel down to fit the (smaller) screen,
--   * a TV / console "10-foot" view scales up so text is legible from a couch,
--   * touch devices get an extra nudge so tap targets stay finger-friendly.
-- It deliberately scales uniformly (one factor) rather than stretching, so
-- aspect ratios and the authored proportions are preserved.
local Responsive = {}

-- Design resolution the offsets were authored against (a 720p-ish landscape).
local REFERENCE = Vector2.new(1280, 720)
-- Clamp so the UI never collapses to unreadable on a tiny phone nor balloons on
-- an ultrawide. The upper bound leans generous for the console big-screen case.
local MIN_SCALE = 0.65
local MAX_SCALE = 1.4
-- On touch, fingers need bigger targets than a mouse cursor; on a console the
-- player sits far from the screen. Both warrant a little extra size on top of
-- the raw resolution ratio.
local TOUCH_BOOST = 1.1
local CONSOLE_BOOST = 1.15

-- Console = a gamepad with no mouse and no touch (Xbox). Touch tablets often also
-- report GamepadEnabled, so the touch/mouse checks come first to disambiguate.
local function isConsole()
	return UserInputService.GamepadEnabled and not UserInputService.TouchEnabled and not UserInputService.MouseEnabled
end

local function isTouch()
	return UserInputService.TouchEnabled and not UserInputService.MouseEnabled
end

-- The scale factor for the current viewport + input mode. Uniform: we take the
-- limiting dimension so the UI fits both axes rather than overflowing one.
local function computeScale()
	local camera = Workspace.CurrentCamera
	local viewport = camera and camera.ViewportSize or REFERENCE
	-- Early in load (or in tests) the viewport can read (0,0); fall back to 1x.
	if viewport.X < 1 or viewport.Y < 1 then
		return 1
	end

	local scale = math.min(viewport.X / REFERENCE.X, viewport.Y / REFERENCE.Y)
	if isTouch() then
		scale *= TOUCH_BOOST
	elseif isConsole() then
		scale *= CONSOLE_BOOST
	end

	return math.clamp(scale, MIN_SCALE, MAX_SCALE)
end

Responsive.computeScale = computeScale

-- Attach (or reuse) a UIScale on `guiObject` and keep it current. Recomputes on
-- viewport resize, camera swaps (the camera instance is replaced on respawn), and
-- when the active input device changes (e.g. a controller is plugged into a PC,
-- flipping us between the mouse and console branches). All connections are torn
-- down when the GuiObject is destroyed, so callers can fire-and-forget. Returns
-- the UIScale for callers that want to read/tween it.
function Responsive.apply(guiObject)
	local scale = guiObject:FindFirstChildOfClass("UIScale") or Instance.new("UIScale")
	scale.Scale = computeScale()
	scale.Parent = guiObject

	local function refresh()
		scale.Scale = computeScale()
	end

	local connections = {}

	-- (Re)bind the per-camera ViewportSize listener whenever the current camera
	-- instance changes; the old connection is dropped so we never leak across
	-- respawns. Held in its own variable (not the array) so swaps replace only it.
	local cameraConnection
	local function trackCamera(camera)
		if cameraConnection then
			cameraConnection:Disconnect()
			cameraConnection = nil
		end
		if camera then
			cameraConnection = camera:GetPropertyChangedSignal("ViewportSize"):Connect(refresh)
		end
		refresh()
	end
	trackCamera(Workspace.CurrentCamera)

	table.insert(
		connections,
		Workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(function()
			trackCamera(Workspace.CurrentCamera)
		end)
	)
	-- Input-device changes flip the touch/console/mouse branches above.
	table.insert(connections, UserInputService:GetPropertyChangedSignal("MouseEnabled"):Connect(refresh))
	table.insert(connections, UserInputService:GetPropertyChangedSignal("TouchEnabled"):Connect(refresh))
	table.insert(connections, UserInputService.GamepadConnected:Connect(refresh))
	table.insert(connections, UserInputService.GamepadDisconnected:Connect(refresh))

	guiObject.Destroying:Connect(function()
		if cameraConnection then
			cameraConnection:Disconnect()
			cameraConnection = nil
		end
		for _, connection in connections do
			connection:Disconnect()
		end
		table.clear(connections)
	end)

	return scale
end

return Responsive
