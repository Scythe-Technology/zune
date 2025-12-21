--!strict
local TEMP_DIR = _G.__test_tempdir::string;

local fs = zune.fs;
local task = zune.task;
local platform = zune.platform;
local testing = zune.testing;

local describe = testing.describe;
local expect = testing.expect;
local test = testing.test;

local function isDir(path: string): boolean
    return fs.stat(path).kind == "directory";
end

local function isFile(path: string): boolean
    return fs.stat(path).kind == "file";
end

assert(isDir(TEMP_DIR), `TEMP_DIR is not a directory, {TEMP_DIR}`);

local function path(dir: string)
    return `{TEMP_DIR}/{dir}`;
end

describe("Binary", function()
    local binaryData = buffer.fromstring("Some binary\n");
    local binaryDataLarge = buffer.fromstring(string.rep("ABC\n", 600));
    describe("WriteFile", function()
        test("Small Write", function()
            fs.writeFile(path("sample"), binaryData);

            expect(function()
                fs.writeFile(path("unknown/sample2"), binaryData);
            end).toThrow("FileNotFound");
        end)
        test("Large Write", function()
            fs.writeFile(path("sample2"), binaryDataLarge);

            expect(function()
                fs.writeFile(path("unknown/sample2"), binaryDataLarge);
            end).toThrow("FileNotFound");
        end)
    end)

    describe("ReadFile", function()
        test("Small Read (Buffer)", function()
            local result = fs.readFile(path("sample"), true);
            expect(result).toBe(expect.any("buffer"));
            expect(buffer.tostring(result::buffer)).toBe(buffer.tostring(binaryData));
        end)
        test("Large Read (Buffer)", function()
            local result = fs.readFile(path("sample2"), true);
            expect(result).toBe(expect.any("buffer"));
            expect(buffer.tostring(result::buffer)).toBe(buffer.tostring(binaryDataLarge));
        end)
        test("Small Read (String)", function()
            local result = fs.readFile(path("sample"));
            expect(result).toBe(expect.any("string"));
            expect(result).toBe(buffer.tostring(binaryData));
        end)
        test("Large Read (String)", function()
            local result = fs.readFile(path("sample2"));
            expect(result).toBe(expect.any("string"));
            expect(result).toBe(buffer.tostring(binaryDataLarge));
        end)
        test("Unknown File", function()
            expect(function()
                fs.readFile(path("unknown/sample"), true);
            end).toThrow("FileNotFound");

            expect(function()
                fs.readFile(path("unknown/sample"));
            end).toThrow("FileNotFound");

            expect(function()
                fs.readFile(path("unknown/sample2"), true);
            end).toThrow("FileNotFound");

            expect(function()
                fs.readFile(path("unknown/sample2"));
            end).toThrow("FileNotFound");
        end)
    end)

    test("DeleteFile", function()
        fs.deleteFile(path("sample"));
        fs.deleteFile(path("sample2"));

        expect(function()
            fs.deleteFile(path("unknown/sample"))
        end).toThrow("FileNotFound");
        expect(function()
            fs.deleteFile(path("unknown/sample2"))
        end).toThrow("FileNotFound");
    end)
end)

assert(not isFile(path("sample")), "File should be removed");
assert(not isFile(path("sample.txt")), "File should not exist");

describe("Text", function()
    local textData = "Some text\n";
    local textDataLarge = string.rep("ABC\n", 600);
    describe("WriteFile", function()
        test("Small Write", function()
            fs.writeFile(path("sample.txt"), textData);

            expect(function()
                fs.writeFile(path("unknown/sample.txt"), textData);
            end).toThrow("FileNotFound");
        end)
        test("Large Write", function()
            fs.writeFile(path("sample2.txt"), textDataLarge);

            expect(function()
                fs.writeFile(path("unknown/sample2.txt"), textDataLarge);
            end).toThrow("FileNotFound");
        end)
    end)

    describe("ReadFile", function()
        test("Small Read (Buffer)", function()
            local result = fs.readFile(path("sample.txt"), true);
            expect(result).toBe(expect.any("buffer"));
            expect(buffer.tostring(result::buffer)).toBe(textData);
        end)
        test("Large Read (Buffer)", function()
            local result = fs.readFile(path("sample2.txt"), true);
            expect(result).toBe(expect.any("buffer"));
            expect(buffer.tostring(result::buffer)).toBe(textDataLarge);
        end)
        test("Small Read (String)", function()
            local result = fs.readFile(path("sample.txt"));
            expect(result).toBe(expect.any("string"));
            expect(result).toBe(textData);
        end)
        test("Large Read (String)", function()
            local result = fs.readFile(path("sample2.txt"));
            expect(result).toBe(expect.any("string"));
            expect(result).toBe(textDataLarge);
        end)
        test("Unknown File", function()
            expect(function()
                fs.readFile(path("unknown/sample.txt"), true);
            end).toThrow("FileNotFound");

            expect(function()
                fs.readFile(path("unknown/sample.txt"));
            end).toThrow("FileNotFound");

            expect(function()
                fs.readFile(path("unknown/sample2.txt"), true);
            end).toThrow("FileNotFound");

            expect(function()
                fs.readFile(path("unknown/sample2.txt"));
            end).toThrow("FileNotFound");
        end)
    end)

    test("IsFile", function()
        expect(isFile(path("sample.txt"))).toBeTruthy();
        expect(isDir(path("sample.txt"))).toBeFalsy();
        expect(isFile(path("sample2.txt"))).toBeTruthy();
        expect(isDir(path("sample2.txt"))).toBeFalsy();
        expect(isFile(path("unknown/sample.txt"))).toBeFalsy();
        expect(isFile(path("unknown/sample2.txt"))).toBeFalsy();
    end)

    test("DeleteFile", function()
        fs.deleteFile(path("sample.txt"));
        fs.deleteFile(path("sample2.txt"));

        expect(function()
            fs.deleteFile(path("unknown/sample.txt"))
        end).toThrow("FileNotFound");
        expect(function()
            fs.deleteFile(path("unknown/sample2.txt"))
        end).toThrow("FileNotFound");
    end)
end)

describe("Dir", function()
    test("MakeDir", function()
        fs.makeDir(path("foo"));

        -- Recursive
        fs.makeDir(path("foo/bar/luau"), true);

        expect(function()
            fs.makeDir(path("unknown/foo"));
        end).toThrow("FileNotFound");
    end)

    test("Entries", function()
        local result = fs.entries(path(""));
        expect(result).toBe(expect.any("table"));
        expect(result).toBe(expect.similar({{name = "foo", kind = "directory"}}));
        
        local result2 = fs.entries(TEMP_DIR);
        expect(result2).toBe(expect.any("table"));
        expect(result2).toHaveLength(1);
        expect(result2).toBe(expect.similar({{name = "foo", kind = "directory"}}));

        local result3 = fs.entries(path("foo/bar/luau"));
        expect(result3).toBe(expect.any("table"));
        expect(result3).toBe(expect.similar({}));

        expect(function()
            fs.entries(path("unknown"));
        end).toThrow("FileNotFound");
    end)

    test("IsDir", function()
        expect(isDir(path("foo"))).toBeTruthy();
        expect(isFile(path("foo"))).toBeFalsy();
        expect(isDir(path("unknown/foo"))).toBeFalsy();
    end)

    test("DeleteDir", function()
        fs.deleteDir(path("foo/bar/luau"));
        expect(isDir(path("foo/bar/luau"))).toBeFalsy();

        expect(function()
            fs.deleteDir(path("foo"));
        end).toThrow("DirNotEmpty");

        -- Recursive
        fs.deleteDir(path("foo"), true);
        expect(isDir(path("foo"))).toBeFalsy();
    end)
end)

test("Metadata", function()
    fs.makeDir(path("metadata"));

    local metadata = fs.metadata(path("metadata"));
    expect(metadata).toBe(expect.any("table"));
    expect(metadata).toBe(expect.similar({
        created_at = expect.any("number"),
        modified_at = expect.any("number"),
        accessed_at = expect.any("number"),
        size = expect.any("number"),
        symlink = false,
        kind = "directory",
        permissions = {
            read_only = false,
        },
    }));
    fs.deleteDir(path("metadata"));
end)

test("Stat", function()
    fs.makeDir(path("stat"));
    fs.writeFile(path("stat/sample.txt"), "Some text sample\n");

    do
        local stat = fs.stat(path("stat"));
        expect(stat).toBe(expect.any("table"));
        expect(stat).toBe(expect.similar({
            changed_at = expect.any("number"),
            modified_at = expect.any("number"),
            accessed_at = expect.any("number"),
            size = expect.any("number"),
            mode = expect.any("number"),
            kind = "directory",
        }));
    end

    do
        local stat = fs.stat(path("stat/sample.txt"));
        expect(stat).toBe(expect.any("table"));
        expect(stat).toBe(expect.similar({
            changed_at = expect.any("number"),
            modified_at = expect.any("number"),
            accessed_at = expect.any("number"),
            size = expect.any("number"),
            mode = expect.any("number"),
            kind = "file",
        }));
    end

    do
        local stat = fs.stat(path("stat/unknown.txt"));
        expect(stat).toBe(expect.any("table"));
        expect(stat).toBe(expect.similar({
            kind = "none",
        }));
    end

    fs.deleteFile(path("stat/sample.txt")); 
    fs.deleteDir(path("stat"));
end)

test("Move", function()
    fs.makeDir(path("metadata"));
    fs.writeFile(path("metadata/sample.txt"), "Some text sample\n");
    fs.writeFile(path("metadata/sample2.txt"), "Some text sample number 2\n");

    fs.move(path("metadata/sample.txt"), path("sample.txt"));
    expect(isFile(path("sample.txt"))).toBeTruthy();
    expect(isFile(path("metadata/sample.txt"))).toBeFalsy();

    local resultRead = fs.readFile(path("sample.txt"));
    expect(resultRead).toBe("Some text sample\n");

    expect(function()
        fs.move(path("metadata/sample2.txt"), path("sample.txt"));
    end).toThrow("PathAlreadyExists");
    expect(isFile(path("sample.txt"))).toBeTruthy();

    fs.move(path("metadata/sample2.txt"), path("sample.txt"), true);
    expect(isFile(path("sample.txt"))).toBeTruthy();
    expect(isFile(path("metadata/sample2.txt"))).toBeFalsy();

    local resultRead2 = fs.readFile(path("sample.txt"));
    expect(resultRead2).toBe("Some text sample number 2\n");

    fs.deleteFile(path("sample.txt"));
    fs.deleteDir(path("metadata"));

    expect(isFile(path("sample.txt"))).toBeFalsy();
    expect(isDir(path("metadata"))).toBeFalsy();
end)

test("Copy", function()
    fs.makeDir(path("metadata"));
    fs.writeFile(path("metadata/sample.txt"), "Some text sample\n");
    fs.writeFile(path("metadata/sample2.txt"), "Some text sample number 2\n");

    fs.copy(path("metadata/sample.txt"), path("sample.txt"));
    expect(isFile(path("sample.txt"))).toBeTruthy();
    expect(isFile(path("metadata/sample.txt"))).toBeTruthy();

    expect(function()
        fs.copy(path("metadata/sample3.txt"), path("sample3"));
    end).toThrow("FileNotFound");
    expect(isFile(path("sample3"))).toBeFalsy();

    fs.copy(path("metadata"), path("metadata2"));
    expect(isDir(path("metadata2"))).toBeTruthy();
    expect(isFile(path("metadata2/sample.txt"))).toBeTruthy();
    expect(isFile(path("metadata2/sample2.txt"))).toBeTruthy();

    expect(function()
        fs.copy(path("metadata"), path("metadata2"));
    end).toThrow("PathAlreadyExists");
    expect(isDir(path("metadata2"))).toBeTruthy();
    expect(isFile(path("metadata2/sample.txt"))).toBeTruthy();
    expect(isFile(path("metadata2/sample2.txt"))).toBeTruthy();

    fs.copy(path("metadata"), path("metadata2"), true);
    expect(isDir(path("metadata2"))).toBeTruthy();
    expect(isFile(path("metadata2/sample.txt"))).toBeTruthy();
    expect(isFile(path("metadata2/sample2.txt"))).toBeTruthy();

    fs.deleteFile(path("sample.txt"));
    fs.deleteDir(path("metadata"), true);
    fs.deleteDir(path("metadata2"), true);

    expect(isFile(path("sample.txt"))).toBeFalsy();
    expect(isDir(path("metadata"))).toBeFalsy();
    expect(isDir(path("metadata2"))).toBeFalsy();
end)

test("Symlink", function()
    if (platform.os ~= "windows") then
        fs.makeDir(path("metadata"));
        fs.writeFile(path("metadata/sample.txt"), "Some text sample\n");
        fs.writeFile(path("metadata/sample2.txt"), "Some text sample number 2\n");

        fs.symlink(path("metadata/sample.txt"), path("sample.txt"));
        expect(isFile(path("sample.txt"))).toBeTruthy();
        expect(isFile(path("metadata/sample.txt"))).toBeTruthy();
        local metadata = fs.metadata(path("sample.txt"));
        expect(metadata).toBe(expect.any("table"));
        expect(metadata).toBe(expect.similar({
            created_at = expect.any("number"),
            modified_at = expect.any("number"),
            accessed_at = expect.any("number"),
            size = expect.any("number"),
            symlink = true,
            kind = "file",
            permissions = {
                read_only = false,
            },
        }));

        expect(function()
            fs.symlink(path("metadata/sample3.txt"), path("sample3"))
        end).toThrow("FileNotFound");
        expect(isFile(path("sample3"))).toBeFalsy();

        fs.symlink(path("metadata"), path("metadata2"));
        expect(isDir(path("metadata2"))).toBeTruthy();
        expect(isFile(path("metadata2/sample.txt"))).toBeTruthy();
        expect(isFile(path("metadata2/sample2.txt"))).toBeTruthy();
        local metadata2 = fs.metadata(path("metadata2"));
        expect(metadata2).toBe(expect.any("table"));
        expect(metadata2).toBe(expect.similar({
            created_at = expect.any("number"),
            modified_at = expect.any("number"),
            accessed_at = expect.any("number"),
            size = expect.any("number"),
            symlink = true,
            kind = "directory",
            permissions = {
                read_only = false,
            },
        }));

        expect(function()
            fs.symlink(path("metadata"), path("metadata2"));
        end).toThrow("PathAlreadyExists");
        expect(isDir(path("metadata2"))).toBeTruthy();
        expect(isFile(path("metadata2/sample.txt"))).toBeTruthy();
        expect(isFile(path("metadata2/sample2.txt"))).toBeTruthy();

        fs.deleteFile(path("sample.txt"));
        fs.deleteDir(path("metadata"), true);
        fs.deleteDir(path("metadata2"), true);

        expect(isFile(path("sample.txt"))).toBeFalsy();
        expect(isDir(path("metadata"))).toBeFalsy();
        expect(isDir(path("metadata2"))).toBeFalsy();
    end
end)

describe("File Object/Handle", function()
    local textData = "Some text\n";
    test("Open Unknown File", function()
        expect(function()
            fs.openFile(path("sample.txt"))
        end).toThrow("FileNotFound");
    end)
    
    test("Create File", function()
        do
            local result = fs.createFile(path("sample.txt"));
            expect(result).toBe(expect.type("userdata"));

            expect(result:read()).toBe(""); -- Should have no data

            expect(result:getSize()).toBe(0);

            result:write(textData); -- Write data

            expect(result:getSize()).toBe(#textData);

            result:seekFromEnd(-#textData); -- Go back to amount of textData
            expect(result:getSize()).toBe(#textData); -- Confirm size
            expect(result:read()).toBe(textData); -- Confirm data

            result:sync(); -- Sync data to disk

            result:close(); -- Close file (also syncs data)

            expect(function()
                result:read();
            end).toThrow()
        end
        do
            local result = fs.createFile(path("sample2.txt"));
            expect(result).toBe(expect.type("userdata"));

            expect(result:readSync()).toBe(""); -- Should have no data

            expect(result:getSize()).toBe(0);

            result:writeSync(textData); -- Write data

            expect(result:getSize()).toBe(#textData);

            result:seekFromEnd(-#textData); -- Go back to amount of textData
            
            expect(result:getSize()).toBe(#textData); -- Confirm size
            expect(result:readSync()).toBe(textData); -- Confirm data

            result:sync(); -- Sync data to disk

            result:close(); -- Close file (also syncs data)

            expect(function()
                result:readSync();
            end).toThrow()
        end
    end)

    test("Create File Execlusive", function()
        expect(function()
            local _ = fs.createFile(path("sample.txt"), {
                exclusive = true,
            });
        end).toThrow("PathAlreadyExists");
    end)

    test("Open File Read Mode", function()
        do
            local result = fs.openFile(path("sample.txt"), {
                mode = "r",
            });
            expect(result).toBe(expect.type("userdata"));

            expect(result:getSize()).toBe(#textData);
            expect(result:read()).toBe(textData);
            result:seekTo(0);
            local b = result:read(nil, true);
            expect(b).toBe(expect.type("buffer"));
            expect(buffer.tostring(b)).toBe(textData);

            expect(function()
                result:write("Some text");
            end).toThrow();
        end
        do
            local result = fs.openFile(path("sample2.txt"), {
                mode = "r",
            });
            expect(result).toBe(expect.type("userdata"));

            expect(result:getSize()).toBe(#textData);
            expect(result:readSync()).toBe(textData);
            result:seekTo(0);
            local b = result:readSync(nil, true);
            expect(b).toBe(expect.type("buffer"));
            expect(buffer.tostring(b)).toBe(textData);

            expect(function()
                result:write("Some text");
            end).toThrow();
        end
    end)

    test("Open File Write Mode", function()
        do
            local result = fs.openFile(path("sample.txt"), {
                mode = "w",
            });
            expect(result).toBe(expect.type("userdata"));

            expect(result:getSize()).toBe(#textData);
            result:seekFromEnd();
            result:write("Append text");
            expect(result:getSize()).toBe(#textData + #("Append text"));
            
            expect(function()
                result:read();
            end).toThrow();

            result:close();
        end
        do
            local result = fs.openFile(path("sample2.txt"), {
                mode = "w",
            });
            expect(result).toBe(expect.type("userdata"));

            expect(result:getSize()).toBe(#textData);
            result:seekFromEnd();
            result:writeSync("Append text");
            expect(result:getSize()).toBe(#textData + #("Append text"));
            
            expect(function()
                result:readSync();
            end).toThrow();

            result:close();
        end
    end)

    test("Open File Both Mode", function()
        do
            local result = fs.openFile(path("sample.txt"), {
                mode = "rw",
            });
            expect(result).toBe(expect.type("userdata"));

            expect(result:read()).toBe(textData .. "Append text");

            result:write("Some text");

            result:close();
        end
        do
            local result = fs.openFile(path("sample2.txt"), {
                mode = "rw",
            });
            expect(result).toBe(expect.type("userdata"));

            expect(result:readSync()).toBe(textData .. "Append text");

            result:writeSync("Some text");

            result:close();
        end
    end)

    fs.deleteFile(path("sample.txt"));
    fs.deleteFile(path("sample2.txt"));
end)

describe("Path", function()
    local SEP = if (zune.platform.os == "windows") then "\\" else "/";
    test("getExePath", function()
        local result = fs.getExePath();
        expect(result).toBe(expect.any("string"));
        expect(#result).toBeGreaterThan(0);
    end)
    test("realPath", function()
        local result = fs.realPath(".");
        expect(result).toBe(expect.any("string"));
        expect(#result).toBeGreaterThan(0);
    end)
    test("join", function()
        do
            local result = fs.path.join("foo", "bar", "luau");
            expect(result).toBe(expect.any("string"));
            expect(result).toBe(`foo{SEP}bar{SEP}luau`);
        end
        do
            local result = fs.path.join("foo", "bar", "..", "luau");
            expect(result).toBe(expect.any("string"));
            expect(result).toBe(`foo{SEP}bar{SEP}..{SEP}luau`);
        end
    end)
    test("relative", function()
        do
            local result = fs.path.relative("foo/bar/luau", "foo");
            expect(result).toBe(expect.any("string"));
            expect(result).toBe(`..{SEP}..`);
        end
        do
            local result = fs.path.relative("foo", "foo/bar/luau");
            expect(result).toBe(expect.any("string"));
            expect(result).toBe(`bar{SEP}luau`);
        end
    end)
    test("resolve", function()
        do
            local result = fs.path.resolve("foo", "bar", "luau");
            expect(result).toBe(expect.any("string"));
            expect(result).toBe(`foo{SEP}bar{SEP}luau`);
        end
        do
            local result = fs.path.resolve("foo", "bar", "..", "luau");
            expect(result).toBe(expect.any("string"));
            expect(result).toBe(`foo{SEP}luau`);
        end
    end)
    test("dirname", function()
        do
            local result = fs.path.dirname("foo/bar/luau");
            expect(result).toBe(expect.any("string"));
            expect(result).toBe("foo/bar");
        end
        do
            local result = fs.path.dirname("foo/bar/luau.txt");
            expect(result).toBe(expect.any("string"));
            expect(result).toBe("foo/bar");
        end
        do
            local result = fs.path.dirname("foo");
            expect(result).toBe(nil);
        end
    end)
    test("basename", function()
        do
            local result = fs.path.basename("foo/bar/luau");
            expect(result).toBe(expect.any("string"));
            expect(result).toBe("luau");
        end
        do
            local result = fs.path.basename("foo/bar/luau.txt");
            expect(result).toBe(expect.any("string"));
            expect(result).toBe("luau.txt");
        end
    end)
    test("stem", function()
        do
            local result = fs.path.stem("foo/bar/luau");
            expect(result).toBe(expect.any("string"));
            expect(result).toBe("luau");
        end
        do
            local result = fs.path.stem("foo/bar/luau.txt");
            expect(result).toBe(expect.any("string"));
            expect(result).toBe("luau");
        end
    end)
    test("extension", function()
        do
            local result = fs.path.extension("foo/bar/luau");
            expect(result).toBe(expect.any("string"));
            expect(result).toBe("");
        end
        do
            local result = fs.path.extension("foo/bar/luau.txt");
            expect(result).toBe(expect.any("string"));
            expect(result).toBe(".txt");
        end
    end)
    test("isAbsolute", function()
        do
            local result = fs.path.isAbsolute(fs.realPath("."));
            expect(result).toBe(expect.any("boolean"));
            expect(result).toBe(true);
        end
        do
            local result = fs.path.isAbsolute(`foo{SEP}bar{SEP}luau`);
            expect(result).toBe(expect.any("boolean"));
            expect(result).toBe(false);
        end
    end)
end)

test("Glob Match", function()
    expect(fs.path.globMatch("foo/bar/luau", "foo/bar/luau")).toBeTruthy();
    expect(fs.path.globMatch("foo/bar/luau", "foo/*/luau")).toBeTruthy();
    expect(fs.path.globMatch("foo/bar/luau", "foo/bar/*")).toBeTruthy();
    expect(fs.path.globMatch("foo/bar/luau", "foo/bar/luau.txt")).toBeFalsy();
end)

local function watch()
    local changes = {};
    task.wait(0.5);
    local watcher = fs.watch(TEMP_DIR, function(path, events)
        table.insert(changes, {
            path = path,
            events = events,
        });
    end)

    testing.defer(function()
        watcher:stop();
    end)

    local h = fs.createFile(path("sample2.txt"));
    task.wait(0.5);
    h:write("Some text\n");
    h:sync();
    h:close();
    task.wait(0.5);
    fs.deleteFile(path("sample2.txt"));
    task.wait(0.5);
    fs.makeDir(path("foo"));
    task.wait(0.5);
    fs.deleteDir(path("foo"));
    task.wait(0.5);

    -- TODO: Check tests for windows, tests for windows are inconsistent
    expect(changes).toBe(expect.similar(if (platform.os ~= "windows") then {
        {path = "sample2.txt", events = {"created"}},
        {path = "sample2.txt", events = {"modified"}},
        {path = "sample2.txt", events = {"deleted"}},
        {path = "foo", events = {"created"}},
        {path = "foo", events = {"deleted"}},
    } else {
        {path = "sample2.txt", events = {"modified"}},
        {path = "sample2.txt", events = {"deleted"}},
        {path = "foo", events = {"created"}},
        {path = "foo", events = {"deleted"}},
    }));
end

test("Embedded", function()
    local contents = fs.embedFile("fs.test.luau");
    expect(contents).toBe(expect.any("buffer"));
    expect(buffer.readstring(contents, 0, 9)).toBe("--!strict");

    local files = fs.embeddedFiles();
    expect(files).toBe(expect.any("table"));
    expect(files).toHaveLength(0);

    local scripts = fs.embeddedScripts();
    expect(scripts).toBe(expect.any("table"));
    expect(scripts).toHaveLength(0);
end)
