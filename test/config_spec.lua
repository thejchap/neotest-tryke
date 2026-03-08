local config = require("neotest-tryke.config")

describe("config.get", function()
	it("returns defaults when called with nil", function()
		local cfg = config.get(nil)
		assert.equal("tryke", cfg.tryke_command)
		assert.equal("direct", cfg.mode)
		assert.same({}, cfg.args)
		assert.equal(2337, cfg.server.port)
		assert.equal("127.0.0.1", cfg.server.host)
		assert.is_true(cfg.server.auto_start)
		assert.is_true(cfg.server.auto_stop)
		assert.is_nil(cfg.workers)
		assert.is_false(cfg.fail_fast)
	end)

	it("returns defaults when called with empty table", function()
		local cfg = config.get({})
		assert.equal("tryke", cfg.tryke_command)
		assert.equal("direct", cfg.mode)
	end)

	it("merges top-level user options", function()
		local cfg = config.get({ mode = "server" })
		assert.equal("server", cfg.mode)
		assert.equal("tryke", cfg.tryke_command)
	end)

	it("deep-merges nested server options", function()
		local cfg = config.get({ server = { port = 9999 } })
		assert.equal(9999, cfg.server.port)
		assert.equal("127.0.0.1", cfg.server.host)
		assert.is_true(cfg.server.auto_start)
		assert.is_true(cfg.server.auto_stop)
	end)

	it("user values override defaults", function()
		local cfg = config.get({
			tryke_command = "/usr/local/bin/tryke",
			fail_fast = true,
			workers = 4,
		})
		assert.equal("/usr/local/bin/tryke", cfg.tryke_command)
		assert.is_true(cfg.fail_fast)
		assert.equal(4, cfg.workers)
	end)
end)
