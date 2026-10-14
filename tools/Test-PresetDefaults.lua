local Migrate = ns.Defaults.migrateRemovedDefensives
local IsPristine = ns.Defaults.isPristineRemovedDefensives

local function check(name, condition, detail)
    if not condition then error("FAIL " .. name .. (detail and (" " .. detail) or "")) end
    print("PASS " .. name)
end

local function raw()
    return {
        presetID = "defensives", name = "Defensives", alertCategory = "defensive", spellIDs = {},
        enabled = false, applyEnabled = false, applyMessage = "", expireEnabled = false, expireMessage = "",
    }
end

local function normalized()
    local rule = raw()
    rule.expireCategory = "none"
    rule.oneEffect = false
    rule.applySoundEnabled, rule.expireSoundEnabled = false, false
    rule.applySoundKitID, rule.expireSoundKitID = 8959, 8959
    rule.applySoundChannel, rule.expireSoundChannel = "Master", "Master"
    rule.voiceID, rule.volume, rule.speechSpeed = 7, 100, 100
    rule.screenProfiles = {
        apply = { enabled = false, text = "", font = "Friz Quadrata", size = 32, style = "SOFT_SHADOW",
            color = { r = 1, g = 0.82, b = 0.2, a = 1 },
            anchor = { point = "CENTER", relativePoint = "CENTER", x = 0, y = 120 } },
        expire = { enabled = false, text = "", font = "Friz Quadrata", size = 32, style = "SOFT_SHADOW",
            color = { r = 1, g = 0.82, b = 0.2, a = 1 },
            anchor = { point = "CENTER", relativePoint = "CENTER", x = 0, y = 120 } },
    }
    return rule
end

check("raw historical starter predicate", IsPristine(raw()))
local rawList = { raw() }
check("exact historical starter removed", Migrate(rawList) == 1 and #rawList == 0)

local canonicalList = { normalized() }
check("normalized fields make provenance uncertain", Migrate(canonicalList) == 0
    and #canonicalList == 1 and canonicalList[1].screenProfiles.apply.font == "Friz Quadrata")

local noMessages = raw(); noMessages.applyMessage = nil; noMessages.expireMessage = nil
local noMessagesList = { noMessages }
check("missing historical fields are preserved", Migrate(noMessagesList) == 0 and #noMessagesList == 1)

local noOptions = { raw() }
check("migration accepts the historical list shape", Migrate(noOptions) == 1 and #noOptions == 0)
local generatedID = raw(); generatedID.id = "rule-17"
check("generated rule ID does not block removal", Migrate({ generatedID }) == 1)
local customID = raw(); customID.id = "my-rule"
local customIDList = { customID }
check("unrecognized ID kept", Migrate(customIDList) == 0 and #customIDList == 1
    and customIDList[1] == customID)

local allProfiles = { settings = {}, auras = { raw() } }
check("profile data input accepted", Migrate(allProfiles) == 1 and #allProfiles.auras == 0)
check("profile data migration idempotent", Migrate(allProfiles) == 0 and #allProfiles.auras == 0)

local function assertKept(name, rule)
    local list = { rule }
    check(name, Migrate(list) == 0 and #list == 1 and list[1] == rule)
end

local renamed = raw(); renamed.name = "My defensives"
assertKept("renamed group kept", renamed)
local active = raw(); active.enabled = true
assertKept("active group kept", active)
local noEnabled = raw(); noEnabled.enabled = nil
assertKept("group without an enabled field (normalized to active) kept", noEnabled)
local applyActive = raw(); applyActive.applyEnabled = true
assertKept("apply-enabled group kept", applyActive)
local expireActive = raw(); expireActive.expireEnabled = true
assertKept("expire-enabled group kept", expireActive)
local addedID = raw(); addedID.spellIDs = { 12345 }
assertKept("added trigger kept", addedID)
local mapID = raw(); mapID.spellIDs.custom = 12345
assertKept("non-array trigger key kept", mapID)
local applyText = raw(); applyText.applyMessage = "Defensive!"
assertKept("custom apply message kept", applyText)
local expireText = raw(); expireText.expireMessage = "Defensive over"
assertKept("custom expire message kept", expireText)

local customVoice = raw(); customVoice.voiceID = 8
assertKept("custom voice kept", customVoice)
local customSound = raw(); customSound.applySoundEnabled = true; customSound.applySoundKitID = 12345
assertKept("custom sound kept", customSound)
local customCategory = raw(); customCategory.alertCategory = "offensive"
assertKept("custom category kept", customCategory)
local customSpec = raw(); customSpec.specializationIDs = { 66 }
assertKept("custom specialization kept", customSpec)
local customApplyScreen = raw(); customApplyScreen.screenProfiles = { apply = { enabled = true, text = "My start" } }
assertKept("custom apply screen profile kept", customApplyScreen)
local customFont = raw(); customFont.screenProfiles = { apply = { font = "User font" } }
assertKept("custom screen font kept", customFont)
local customExpireScreen = raw(); customExpireScreen.screenProfiles = { expire = { enabled = true, text = "My end" } }
assertKept("custom expire screen profile kept", customExpireScreen)
local unknown = raw(); unknown.futureSetting = "keep me"
assertKept("unknown field kept", unknown)

local manual = { name = "Manual", spellIDs = {} }
local mixed = { raw(), manual, raw() }
check("manual group retained while pristine groups removed", Migrate(mixed) == 2
    and #mixed == 1 and mixed[1] == manual)
check("second migration remains idempotent", Migrate(mixed) == 0 and #mixed == 1 and mixed[1] == manual)
