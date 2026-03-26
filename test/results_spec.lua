local results = require("neotest-tryke.results")

describe("convert_result", function()
	it("maps passed", function()
		local r = results.convert_result({
			test = { name = "test_add" },
			outcome = { status = "passed" },
		})
		assert.equal("passed", r.status)
		assert.equal("test_add: passed", r.short)
		assert.is_nil(r.errors)
	end)

	it("maps failed with assertions", function()
		local r = results.convert_result({
			test = { name = "test_sub" },
			outcome = {
				status = "failed",
				detail = {
					assertions = {
						{
							expression = "assert x == y",
							expected = "3",
							received = "5",
							line = 10,
						},
					},
				},
			},
		})
		assert.equal("failed", r.status)
		assert.equal("test_sub: failed", r.short)
		assert.equal(1, #r.errors)
		assert.equal("assert x == y: expected 3, received 5", r.errors[1].message)
		assert.equal(9, r.errors[1].line)
	end)

	it("maps failed with message only", function()
		local r = results.convert_result({
			test = { name = "test_err" },
			outcome = {
				status = "failed",
				detail = {
					message = "RuntimeError: boom",
					assertions = {},
				},
			},
		})
		assert.equal("failed", r.status)
		assert.equal(1, #r.errors)
		assert.equal("RuntimeError: boom", r.errors[1].message)
	end)

	it("uses display_name when present", function()
		local r = results.convert_result({
			test = { name = "test_add", display_name = "basic addition" },
			outcome = { status = "passed" },
		})
		assert.equal("passed", r.status)
		assert.equal("basic addition: passed", r.short)
	end)

	it("falls back to name when display_name is nil", function()
		local r = results.convert_result({
			test = { name = "test_add" },
			outcome = { status = "passed" },
		})
		assert.equal("test_add: passed", r.short)
	end)

	it("maps skipped", function()
		local r = results.convert_result({
			test = { name = "test_skip" },
			outcome = { status = "skipped" },
		})
		assert.equal("skipped", r.status)
		assert.equal("test_skip: skipped", r.short)
	end)

	it("maps error to failed", function()
		local r = results.convert_result({
			test = { name = "test_boom" },
			outcome = { status = "error", detail = { message = "setup failed" } },
		})
		assert.equal("failed", r.status)
		assert.equal(1, #r.errors)
		assert.equal("setup failed", r.errors[1].message)
	end)

	it("maps x_failed to passed", function()
		local r = results.convert_result({
			test = { name = "test_xfail" },
			outcome = { status = "x_failed" },
		})
		assert.equal("passed", r.status)
	end)

	it("maps x_passed to failed", function()
		local r = results.convert_result({
			test = { name = "test_xpass" },
			outcome = { status = "x_passed" },
		})
		assert.equal("failed", r.status)
	end)

	it("maps todo to skipped", function()
		local r = results.convert_result({
			test = { name = "test_todo" },
			outcome = { status = "todo" },
		})
		assert.equal("skipped", r.status)
	end)
end)

describe("build_id", function()
	it("builds id without groups", function()
		local id = results.build_id("/project", { file_path = "tests/math.py", name = "test_add" })
		assert.equal("/project/tests/math.py::test_add", id)
	end)

	it("builds id with single group", function()
		local id = results.build_id("/project", {
			file_path = "tests/math.py",
			name = "test_add",
			groups = { "Math" },
		})
		assert.equal("/project/tests/math.py::Math::test_add", id)
	end)

	it("builds id with nested groups", function()
		local id = results.build_id("/project", {
			file_path = "tests/math.py",
			name = "test_add",
			groups = { "Math", "addition" },
		})
		assert.equal("/project/tests/math.py::Math::addition::test_add", id)
	end)

	it("builds id with empty groups array", function()
		local id = results.build_id("/project", {
			file_path = "tests/math.py",
			name = "test_add",
			groups = {},
		})
		assert.equal("/project/tests/math.py::test_add", id)
	end)
end)

describe("parse_output", function()
	it("parses single test_complete NDJSON line", function()
		local line = vim.json.encode({
			event = "test_complete",
			result = {
				test = { name = "test_add", file_path = "tests/math.py" },
				outcome = { status = "passed" },
			},
		})
		local r = results.parse_output(line, "/project")
		assert.is_not_nil(r["/project/tests/math.py::test_add"])
		assert.equal("passed", r["/project/tests/math.py::test_add"].status)
	end)

	it("parses multiple test_complete lines", function()
		local lines = {}
		for _, name in ipairs({ "test_a", "test_b" }) do
			table.insert(
				lines,
				vim.json.encode({
					event = "test_complete",
					result = {
						test = { name = name, file_path = "tests/foo.py" },
						outcome = { status = "passed" },
					},
				})
			)
		end
		local r = results.parse_output(table.concat(lines, "\n"), "/project")
		assert.is_not_nil(r["/project/tests/foo.py::test_a"])
		assert.is_not_nil(r["/project/tests/foo.py::test_b"])
	end)

	it("skips non-test_complete events", function()
		local lines = table.concat({
			vim.json.encode({ event = "run_start" }),
			vim.json.encode({
				event = "test_complete",
				result = {
					test = { name = "test_x", file_path = "tests/x.py" },
					outcome = { status = "passed" },
				},
			}),
			vim.json.encode({ event = "run_complete" }),
		}, "\n")
		local r = results.parse_output(lines, "/project")
		local count = 0
		for _ in pairs(r) do
			count = count + 1
		end
		assert.equal(1, count)
	end)

	it("handles empty output", function()
		local r = results.parse_output("", "/project")
		assert.same({}, r)
	end)

	it("handles invalid JSON lines gracefully", function()
		local lines = "not json\n{bad\n"
		local r = results.parse_output(lines, "/project")
		assert.same({}, r)
	end)

	it("skips results with nil file_path", function()
		local line = vim.json.encode({
			event = "test_complete",
			result = {
				test = { name = "test_orphan" },
				outcome = { status = "passed" },
			},
		})
		local r = results.parse_output(line, "/project")
		assert.same({}, r)
	end)

	it("includes groups in result id", function()
		local line = vim.json.encode({
			event = "test_complete",
			result = {
				test = { name = "test_add", file_path = "tests/math.py", groups = { "Math", "addition" } },
				outcome = { status = "passed" },
			},
		})
		local r = results.parse_output(line, "/project")
		assert.is_not_nil(r["/project/tests/math.py::Math::addition::test_add"])
		assert.equal("passed", r["/project/tests/math.py::Math::addition::test_add"].status)
	end)

	it("strips trailing slashes from root path", function()
		local line = vim.json.encode({
			event = "test_complete",
			result = {
				test = { name = "test_add", file_path = "tests/math.py" },
				outcome = { status = "passed" },
			},
		})
		local r = results.parse_output(line, "/project/")
		assert.is_not_nil(r["/project/tests/math.py::test_add"])
	end)
end)
