--!strict

local io = zune.io
local process = zune.process

local out_dir = "/tmp/certs"
local days = "30"
local name = "example.test"

local cwd = io.cwd()

local function safeStatFile(dir: any, path: string)
    local ok, result = pcall(dir.statFile, dir, path)
    if not ok then
        if result == "FileNotFound" then
            return {
                kind = "none",
            }
        end
        error(result)
    end
    return result
end

if safeStatFile(cwd, out_dir).kind ~= "directory" then
    cwd:createDir(out_dir)
end

const certs_dir = cwd:openDir(out_dir)

local res = process.run("openssl", {
    "req",
    "-x509",
    "-newkey",
    "rsa:2048",
    "-nodes",
    "-keyout",
    `{out_dir}/test.key`,
    "-out",
    `{out_dir}/test.crt`,
    "-days",
    `{days}`,
    "-subj",
    `/CN={name}`,
    "-addext",
    `subjectAltName=DNS:{name},DNS:localhost,IP:127.0.0.1`,
})

if not res.ok then
    print(res.stderr)
    return process.exit(1)
end

local key = certs_dir:openFile(`test.key`, {
    mode = "w",
})

key:setPermissions(tonumber("600", 8) :: number)
key:close()

print(`key:  {out_dir}/test.key`)
print(`cert: {out_dir}/test.crt`)
