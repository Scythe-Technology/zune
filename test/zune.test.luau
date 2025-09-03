assert(zune, "Zune is not defined");

local success, err = pcall(function()
    zune.fs = {} :: any;
end)
assert(not success, "Zune should be readonly");
assert(err:find("readonly"), "Zune should be readonly");
