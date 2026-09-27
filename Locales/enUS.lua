local _, ns = ...
ns.Locales = ns.Locales or {}
ns.Locales.enUS = setmetatable({}, {
    __index = function(_, key) return key end,
})
