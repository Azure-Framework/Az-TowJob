Config = {}


-- Job name that counts as tow operators. Adjust to match your Az-Framework job value.
Config.TowJobName = 'police'


-- AI call interval minutes (set to 0 to disable)
Config.AICallIntervalMinutes = 10


-- Maximum distance (meters) for tow players to see a call notification
Config.CallNotifyRadius = 99999 -- large so all tow players see by default


-- Tow truck models allowed to spawn
Config.TowTruckModels = { 'flatbed', 'towtruck' }


-- Simple set of anchor coordinates for AI random calls. Add or change as needed.
Config.AICallAnchors = {
vector3(215.0, -791.0, 30.9), -- southside
vector3(-342.0, -135.0, 39.0),
vector3(193.0, -1389.0, 30.6),
vector3(1200.0, -1300.0, 35.0),
}


-- How long a call will remain open (s)
Config.CallTimeoutSeconds = 300


-- NUI settings
Config.NUI_ENABLED = true