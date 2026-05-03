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
		-- The diagnostic leads with the test name (matching the test
		-- tree entry) rather than the raw assertion expression — same
		-- cascade as `falls back to function name when neither
		-- display_name nor case_label set` below.
		assert.equal("test_sub: expected 3, received 5", r.errors[1].message)
		assert.equal(9, r.errors[1].line)
	end)

	it("leads assertion diagnostics with display_name when present", function()
		-- The expression is already visible on the annotated line, so
		-- repeating it inside the diagnostic just crowds the gutter and
		-- often gets truncated. Leading with the test's display_name
		-- gives the diagnostic a stable, recognisable handle that
		-- matches the test tree entry. The per-expectation `name=`
		-- label is appended when set so individual asserts in a test
		-- with multiple expectations stay distinguishable.
		local r = results.convert_result({
			test = { name = "test_basic", display_name = "basic equality" },
			outcome = {
				status = "failed",
				detail = {
					assertions = {
						{
							expression = 'expect(1, name="1 equals itself").to_equal(2)',
							expected = "2",
							received = "1",
							line = 6,
						},
					},
				},
			},
		})
		assert.equal("basic equality: 1 equals itself: expected 2, received 1", r.errors[1].message)
		assert.equal(5, r.errors[1].line)
	end)

	it("composes display_name with case_label for parametrised cases", function()
		-- Mirrors the test-tree entry `basic[1+1]` when an `@test("basic")
		-- .cases(case("1+1"), …)` row fails.
		local r = results.convert_result({
			test = { name = "labelled_addition", display_name = "basic", case_label = "1 + 1" },
			outcome = {
				status = "failed",
				detail = {
					assertions = {
						{
							expression = 'expect(a + b, name="a + b matches expected").to_equal(expected)',
							expected = "2",
							received = "3",
							line = 4,
						},
					},
				},
			},
		})
		assert.equal(
			"basic[1 + 1]: a + b matches expected: expected 2, received 3",
			r.errors[1].message
		)
	end)

	it("uses function-name leaf for parametrised cases without @test(name)", function()
		-- Bare `@test.cases(...)` doesn't set display_name, so the cascade
		-- falls through to the python function name composed with the
		-- case label — a much cleaner handle than the raw expression.
		local r = results.convert_result({
			test = { name = "square_typed", case_label = "one" },
			outcome = {
				status = "failed",
				detail = {
					assertions = {
						{
							expression = 'expect(n * n, name="n squared matches expected").to_equal(expected)',
							expected = "2",
							received = "1",
							line = 5,
						},
					},
				},
			},
		})
		assert.equal(
			"square_typed[one]: n squared matches expected: expected 2, received 1",
			r.errors[1].message
		)
	end)

	it("falls back to function name when neither display_name nor case_label set", function()
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
		assert.equal("test_sub: expected 3, received 5", r.errors[1].message)
	end)

	it("recovers positional `expect(<simple>, \"label\")` form", function()
		-- vscode's parameter-name hints render `expect(1, "label")` as
		-- `expect(expr=1, name="label")` in the editor, but the wire
		-- expression carries the raw source — positional args, no
		-- `name=` kwarg. The label still needs to surface in the
		-- diagnostic.
		local r = results.convert_result({
			test = { name = "test_basic", display_name = "basic equality" },
			outcome = {
				status = "failed",
				detail = {
					assertions = {
						{
							expression = 'expect(1, "1 equals itself").to_equal(2)',
							expected = "2",
							received = "1",
							line = 27,
						},
					},
				},
			},
		})
		assert.equal(
			"basic equality: 1 equals itself: expected 2, received 1",
			r.errors[1].message
		)
	end)

	it("recovers single-quoted name= label from expression", function()
		local r = results.convert_result({
			test = { name = "test_basic", display_name = "basic" },
			outcome = {
				status = "failed",
				detail = {
					assertions = {
						{
							expression = "expect(x, name='quoted label').to_equal(2)",
							expected = "2",
							received = "1",
							line = 4,
						},
					},
				},
			},
		})
		assert.equal("basic: quoted label: expected 2, received 1", r.errors[1].message)
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

	it("appends traceback to message when emitted", function()
		local tb = 'Traceback (most recent call last):\n  File "/abs/proj/tests/m.py", line 6, in crashes\n    return a["k"]\nKeyError: \'k\'\n'
		local r = results.convert_result({
			test = { name = "crashes", file_path = "tests/m.py" },
			outcome = {
				status = "failed",
				detail = {
					message = "KeyError: 'k'",
					traceback = tb,
					assertions = {},
				},
			},
		})
		assert.equal("failed", r.status)
		assert.equal(1, #r.errors)
		assert.equal("KeyError: 'k'\n\n" .. tb, r.errors[1].message)
		assert.equal(5, r.errors[1].line)
	end)

	it("ignores empty traceback (assertion failures send '')", function()
		local r = results.convert_result({
			test = { name = "test_err", file_path = "tests/m.py" },
			outcome = {
				status = "failed",
				detail = {
					message = "RuntimeError: boom",
					traceback = "",
					assertions = {},
				},
			},
		})
		assert.equal(1, #r.errors)
		assert.equal("RuntimeError: boom", r.errors[1].message)
		assert.is_nil(r.errors[1].line)
	end)

	it("uses traceback alone when message is missing", function()
		local tb = 'Traceback (most recent call last):\n  File "/abs/proj/tests/m.py", line 9, in fn\n    raise ValueError\nValueError\n'
		local r = results.convert_result({
			test = { name = "fn", file_path = "tests/m.py" },
			outcome = {
				status = "failed",
				detail = {
					traceback = tb,
					assertions = {},
				},
			},
		})
		assert.equal(1, #r.errors)
		assert.equal(tb, r.errors[1].message)
		assert.equal(8, r.errors[1].line)
	end)

	it("does not pin a line for traceback frames in unrelated files", function()
		-- All frames are inside tryke's own worker/runtime, none in the
		-- user test file — line should remain unset so neotest renders
		-- the diagnostic at the position's default range.
		local tb = 'Traceback (most recent call last):\n  File "/abs/tryke/python/tryke/worker.py", line 42, in _run_test\n    raise RuntimeError\nRuntimeError\n'
		local r = results.convert_result({
			test = { name = "fn", file_path = "tests/m.py" },
			outcome = {
				status = "failed",
				detail = {
					message = "RuntimeError",
					traceback = tb,
					assertions = {},
				},
			},
		})
		assert.equal(1, #r.errors)
		assert.is_nil(r.errors[1].line)
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

	it("falls back to name when display_name is vim.NIL (JSON null)", function()
		local r = results.convert_result({
			test = { name = "test_add", display_name = vim.NIL },
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

	it("appends case_label suffix", function()
		local id = results.build_id("/project", {
			file_path = "tests/math.py",
			name = "square",
			case_label = "zero",
		})
		assert.equal("/project/tests/math.py::square[zero]", id)
	end)

	it("appends case_label with groups", function()
		local id = results.build_id("/project", {
			file_path = "tests/math.py",
			name = "square",
			groups = { "Math" },
			case_label = "two",
		})
		assert.equal("/project/tests/math.py::Math::square[two]", id)
	end)

	it("ignores vim.NIL case_label", function()
		local id = results.build_id("/project", {
			file_path = "tests/math.py",
			name = "test_add",
			case_label = vim.NIL,
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

	it("includes case_label in result id", function()
		local line = vim.json.encode({
			event = "test_complete",
			result = {
				test = {
					name = "square",
					file_path = "tests/math.py",
					case_label = "zero",
				},
				outcome = { status = "passed" },
			},
		})
		local r = results.parse_output(line, "/project")
		assert.is_not_nil(r["/project/tests/math.py::square[zero]"])
		assert.equal("passed", r["/project/tests/math.py::square[zero]"].status)
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
