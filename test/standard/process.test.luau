--!strict

local fs = zune.fs;
local process = zune.process;
local testing = zune.testing;
local platform = zune.platform;

local describe = testing.describe;
local expect = testing.expect;
local test = testing.test;

local IS_WINDOWS = platform.os == "windows";

test("Context", function()
	expect(process).toBe(expect.any("table"));

	local cwd = process.cwd();
	expect(cwd).toBe(expect.any("string"));
	expect(#cwd).toBeGreaterThan(0);

	local pid = process.pid();
	expect(pid).toBe(expect.any("number"));
	expect(pid).toBeGreaterThan(0);

	expect(function()
		process.args = {};
	end).toThrow("attempt to modify a readonly table");
	
	if (IS_WINDOWS) then
		expect(cwd:sub(2, 3) == ":\\").toBeTruthy();
	else
		expect(cwd:sub(1, 1) == "/").toBeTruthy();
	end
end)

describe("Environment", function()
	expect(process.loadEnv).toBe(expect.any("function"));

	test("Context", function()
		expect(process.env).toBe(expect.any("table"));
	end)

	test("Load", function()
		process.env["Something"] = "Test";
		local success, result = pcall(process.loadEnv);
		expect(success).toBeTruthy();
		expect(result).toBe(expect.any("table"));
		expect(result.Something).toBe(nil);
		expect(process.env.Something).toBe("Test");
	end)

	describe("Dot Env", function()
		test("Parser", function()
			-- based on https://github.com/motdotla/dotenv/blob/8ab33066f90a20445d3c41e4fafba6c929c5e1a5/tests/.env
			-- based on https://github.com/motdotla/dotenv/blob/8ab33066f90a20445d3c41e4fafba6c929c5e1a5/tests/.env-multiline
			fs.writeFile("./.env", [[
BASIC=basic

# previous line intentionally left blank
AFTER_LINE=after_line
EMPTY=
EMPTY_SINGLE_QUOTES=''
EMPTY_DOUBLE_QUOTES=""
EMPTY_BACKTICKS=``
SINGLE_QUOTES='single_quotes'
SINGLE_QUOTES_SPACED='    single quotes    '
DOUBLE_QUOTES="double_quotes"
DOUBLE_QUOTES_SPACED="    double quotes    "
DOUBLE_QUOTES_INSIDE_SINGLE='double "quotes" work inside single quotes'
DOUBLE_QUOTES_WITH_NO_SPACE_BRACKET="{ port: $MONGOLAB_PORT}"
SINGLE_QUOTES_INSIDE_DOUBLE="single 'quotes' work inside double quotes"
BACKTICKS_INSIDE_SINGLE='`backticks` work inside single quotes'
BACKTICKS_INSIDE_DOUBLE="`backticks` work inside double quotes"
BACKTICKS=`backticks`
BACKTICKS_SPACED=`    backticks    `
DOUBLE_QUOTES_INSIDE_BACKTICKS=`double "quotes" work inside backticks`
SINGLE_QUOTES_INSIDE_BACKTICKS=`single 'quotes' work inside backticks`
DOUBLE_AND_SINGLE_QUOTES_INSIDE_BACKTICKS=`double "quotes" and single 'quotes' work inside backticks`
EXPAND_NEWLINES="expand\nnew\nlines"
DONT_EXPAND_UNQUOTED=dontexpand\nnewlines
DONT_EXPAND_SQUOTED='dontexpand\nnewlines'
# COMMENTS=work
INLINE_COMMENTS=inline comments # work #very #well
INLINE_COMMENTS_SINGLE_QUOTES='inline comments outside of #singlequotes' # work
INLINE_COMMENTS_DOUBLE_QUOTES="inline comments outside of #doublequotes" # work
INLINE_COMMENTS_BACKTICKS=`inline comments outside of #backticks` # work
INLINE_COMMENTS_SPACE=inline comments start with a#number sign. no space required.
EQUAL_SIGNS=equals==
RETAIN_INNER_QUOTES={"foo": "bar"}
RETAIN_INNER_QUOTES_AS_STRING='{"foo": "bar"}'
RETAIN_INNER_QUOTES_AS_BACKTICKS=`{"foo": "bar's"}`
TRIM_SPACE_FROM_UNQUOTED=    some spaced out string
USERNAME=therealnerdybeast@example.tld
    SPACED_KEY = parsed
STRING_MISSING_QUOTE="stringwithoutquotes
MULTI_DOUBLE_QUOTED="THIS
IS
A
MULTILINE
STRING"

MULTI_SINGLE_QUOTED='THIS
IS
A
MULTILINE
STRING'

MULTI_BACKTICKED=`THIS
IS
A
"MULTILINE'S"
STRING`
			]]);

			local success, result = pcall(process.loadEnv);
			expect(success).toBeTruthy();
			expect(result).toBe(expect.any("table"));

			expect(result.BASIC).toBe("basic");
			expect(result.AFTER_LINE).toBe("after_line");
			expect(result.EMPTY).toBe("");
			expect(result.EMPTY_SINGLE_QUOTES).toBe("");
			expect(result.EMPTY_DOUBLE_QUOTES).toBe("");
			expect(result.EMPTY_BACKTICKS).toBe("");
			expect(result.SINGLE_QUOTES).toBe("single_quotes");
			expect(result.SINGLE_QUOTES_SPACED).toBe("    single quotes    ");
			expect(result.DOUBLE_QUOTES).toBe("double_quotes");
			expect(result.DOUBLE_QUOTES_SPACED).toBe("    double quotes    ");
			expect(result.DOUBLE_QUOTES_INSIDE_SINGLE).toBe("double \"quotes\" work inside single quotes");
			expect(result.DOUBLE_QUOTES_WITH_NO_SPACE_BRACKET).toBe("{ port: $MONGOLAB_PORT}");
			expect(result.SINGLE_QUOTES_INSIDE_DOUBLE).toBe("single 'quotes' work inside double quotes");
			expect(result.BACKTICKS_INSIDE_SINGLE).toBe("`backticks` work inside single quotes");
			expect(result.BACKTICKS_INSIDE_DOUBLE).toBe("`backticks` work inside double quotes");
			expect(result.BACKTICKS).toBe("backticks");
			expect(result.BACKTICKS_SPACED).toBe("    backticks    ");
			expect(result.DOUBLE_QUOTES_INSIDE_BACKTICKS).toBe("double \"quotes\" work inside backticks");
			expect(result.SINGLE_QUOTES_INSIDE_BACKTICKS).toBe("single 'quotes' work inside backticks");
			expect(result.DOUBLE_AND_SINGLE_QUOTES_INSIDE_BACKTICKS).toBe("double \"quotes\" and single 'quotes' work inside backticks");
			expect(result.EXPAND_NEWLINES).toBe("expand\nnew\nlines");
			expect(result.DONT_EXPAND_UNQUOTED).toBe("dontexpand\\nnewlines");
			expect(result.DONT_EXPAND_SQUOTED).toBe("dontexpand\\nnewlines");
			expect(result.INLINE_COMMENTS).toBe("inline comments");
			expect(result.INLINE_COMMENTS_SINGLE_QUOTES).toBe("inline comments outside of #singlequotes");
			expect(result.INLINE_COMMENTS_DOUBLE_QUOTES).toBe("inline comments outside of #doublequotes");
			expect(result.INLINE_COMMENTS_BACKTICKS).toBe("inline comments outside of #backticks");
			expect(result.INLINE_COMMENTS_SPACE).toBe("inline comments start with a");
			expect(result.EQUAL_SIGNS).toBe("equals==");
			expect(result.RETAIN_INNER_QUOTES).toBe("{\"foo\": \"bar\"}");
			expect(result.RETAIN_INNER_QUOTES_AS_STRING).toBe("{\"foo\": \"bar\"}");
			expect(result.RETAIN_INNER_QUOTES_AS_BACKTICKS).toBe("{\"foo\": \"bar's\"}");
			expect(result.TRIM_SPACE_FROM_UNQUOTED).toBe("some spaced out string");
			expect(result.USERNAME).toBe("therealnerdybeast@example.tld");
			expect(result.SPACED_KEY).toBe("parsed");
			expect(result.STRING_MISSING_QUOTE).toBe("\"stringwithoutquotes");
			expect(result.MULTI_DOUBLE_QUOTED).toBe("THIS\nIS\nA\nMULTILINE\nSTRING");
			expect(result.MULTI_SINGLE_QUOTED).toBe("THIS\nIS\nA\nMULTILINE\nSTRING");
			expect(result.MULTI_BACKTICKED).toBe("THIS\nIS\nA\n\"MULTILINE'S\"\nSTRING");

			fs.deleteFile("./.env");
		end)

		test("Priority", function()
			fs.writeFile("./.env", 'A=2\nB=4');
			fs.writeFile("./.env.local", 'B=3');

			local success, result = pcall(process.loadEnv);
			expect(success).toBeTruthy();
			expect(result).toBe(expect.any("table"));
			expect(result.A).toBe("2");
			expect(result.B).toBe("3");

			fs.deleteFile("./.env");
			fs.deleteFile("./.env.local");
		end)
	end)
end)

test("Arguments", function()
	expect(process.args).toBe(expect.any("table"));

	local success, result, result2 = pcall(function()
		return process.args[1], process.args[2];
	end)
	expect(success).toBeTruthy();
	expect(result).toBe(expect.any("string"));
	expect(result2).toBe(expect.any("string"));
	expect(result).toBe("Test");
	expect(result2).toBe("someValue");

	local successGood = pcall(function()
		process.args[1] = "Test!";
	end)
	expect(successGood).toBeTruthy();
end)

describe("ChildProcess", function()
	describe("Run", function()
		test("Echo with arguments", function()
			local result = process.run("echo", {"some long message"});
			expect(result).toBe(expect.similar({
				ok = true,
				code = 0,
				stderr = "",
				stdout = "some long message\n",
			}));
		end)

		test("Echo with many arguments", function()
			local result = process.run("echo", {"some", "normal", "very", "long", "message", "test"});
			expect(result).toBe(expect.similar({
				ok = true,
				code = 0,
				stderr = "",
				stdout = "some normal very long message test\n",
			}));
		end)

		test("Echo with variables", function()
			-- Windows Powershell requires existing variables to run.
			local newEnv = table.clone(process.env);
			newEnv["NAME"] = "Test";
			local result = process.run("echo", {
				if IS_WINDOWS then '"$Env:NAME"' else '"$NAME"',
			}, {
				env = newEnv,
				shell = if IS_WINDOWS then "powershell" else "bash",
			});
			expect(result).toBe(expect.similar({
				ok = true,
				code = 0,
				stderr = "",
				stdout = if IS_WINDOWS then "Test\r\n" else "Test\n",
			}));
		end)

		test("Unknown Program/Command", function()
			expect(function()
				process.run("someunknownproc", {});
			end).toThrow("FileNotFound");
		end)

		test("ExitCode", function()
			do
				local result = process.run("exit", {"0"}, {
					shell = true,
				});
				expect(result).toBe(expect.similar({
					ok = true,
					code = 0,
					stderr = "",
					stdout = "",
				}));
			end
			for i = 1, 10 do
				local result = process.run("exit", {tostring(i)}, {
					shell = true,
				});
				expect(result).toBe(expect.similar({
					ok = false,
					code = i,
					stderr = "",
					stdout = "",
				}));
			end
		end)

		describe("Std Options", function()
			test("Both", function()
				local result = process.run("echo", {"some long message"}, {stdout = "pipe", stderr = "pipe"});
				expect(result).toBe(expect.similar({
					ok = true,
					code = 0,
					stderr = "",
					stdout = "some long message\n",
				}));
			end)
			test("Stdout", function()
				local result = process.run("echo", {"some long message"}, {stdout = "pipe", stderr = "ignore"});
				expect(result).toBe(expect.similar({
					ok = true,
					code = 0,
					stdout = "some long message\n",
				}));
			end)
			test("Stderr", function()
				local result = process.run("echo", {"some long message"}, {stdout = "ignore", stderr = "pipe"});
				expect(result).toBe(expect.similar({
					ok = true,
					code = 0,
					stderr = "",
				}));
			end)
			test("None", function()
				local result = process.run("echo", {"some long message"}, {stdout = "ignore", stderr = "ignore"});
				expect(result).toBe(expect.similar({
					ok = true,
					code = 0,
				}));
			end)
		end)
	end)

	describe("Create", function()
		test("Echo", function()
			local result = process.create("echo", {"some", "long", "message"});
			assert(result.stdin)
			assert(result.stdout)
			
			local status = result:wait();

			expect(result.stdout:read(4)).toBe("some");
			expect(result.stdout:read()).toBe(" long message\n");

			expect(status).toBe(expect.any("table"));
			expect(status).toBe(expect.similar({
				ok = true,
				code = 0,
			}));
		end)
		test("Wait", function()
			local result = process.create("exit", {"0"}, {
				shell = true,
			});
			assert(result.stdin)
			assert(result.stdout)
			expect(result.pid).toBe(expect.type("number"));
			local status = result:wait();
			expect(status).toBe(expect.any("table"));
			expect(status).toBe(expect.similar({
				ok = true,
				code = 0,
			}));
		end)
		test("Process Handle", function()
			local result = process.create("cat");
			assert(result.stdin)
			assert(result.stdout)
			expect(result.pid).toBe(expect.type("number"));
			result.stdin:write("Hello World\n");
			expect(result.stdout:read(5)).toBe("Hello");
			expect(result.stdout:read()).toBe(" World\n");

			local status = result:kill();
			expect(status).toBe(expect.any("table"));
			expect(status).toBe(expect.similar({
				ok = false,
				code = if IS_WINDOWS then 1 else 15,
			}));
		end)

		describe("Std Options", function()
			test("All", function()
				local result = process.create("echo", {"some", "long", "message"}, {stdout = "pipe", stderr = "pipe", stdin = "pipe"});
				assert(result.stdin ~= nil);
				assert(result.stdout ~= nil);
				assert(result.stderr ~= nil);

				local status = result:wait();

				expect(result.stdout:read()).toBe("some long message\n");

				expect(status).toBe(expect.any("table"));
				expect(status).toBe(expect.similar({
					ok = true,
					code = 0,
				}));
			end)
			test("Stdout/Stderr", function()
				local result = process.create("echo", {"some", "long", "message"}, {stdout = "pipe", stderr = "pipe", stdin = "ignore"});
				assert(result.stdin == nil);
				assert(result.stdout ~= nil);
				assert(result.stderr ~= nil);

				local status = result:wait();

				expect(result.stdout:read()).toBe("some long message\n");

				expect(status).toBe(expect.any("table"));
				expect(status).toBe(expect.similar({
					ok = true,
					code = 0,
				}));
			end)
			test("Stdout", function()
				local result = process.create("echo", {"some", "long", "message"}, {stdout = "pipe", stderr = "ignore", stdin = "ignore"});
				assert(result.stdin == nil);
				assert(result.stdout ~= nil);
				assert(result.stderr == nil);

				local status = result:wait();

				expect(result.stdout:read()).toBe("some long message\n");

				expect(status).toBe(expect.any("table"));
				expect(status).toBe(expect.similar({
					ok = true,
					code = 0,
				}));
			end)
			test("Stderr", function()
				local result = process.create("echo", {"some", "long", "message"}, {stdout = "ignore", stderr = "pipe", stdin = "ignore"});
				assert(result.stdin == nil);
				assert(result.stdout == nil);
				assert(result.stderr ~= nil);

				local status = result:wait();

				expect(status).toBe(expect.any("table"));
				expect(status).toBe(expect.similar({
					ok = true,
					code = 0,
				}));
			end)
			test("None", function()
				local result = process.create("echo", {"some", "long", "message"}, {stdout = "ignore", stderr = "ignore", stdin = "ignore"});
				assert(result.stdin == nil);
				assert(result.stdout == nil);
				assert(result.stderr == nil);

				local status = result:wait();

				expect(status).toBe(expect.any("table"));
				expect(status).toBe(expect.similar({
					ok = true,
					code = 0,
				}));
			end)
		end)
	end)
end)
