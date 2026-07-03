local config = require("neotest-tryke.config")

describe("config.get", function()
	it("returns defaults when called with nil", function()
		local cfg = config.get(nil)
		assert.equal("tryke", cfg.tryke_command)
		assert.equal("direct", cfg.mode)
		assert.same({}, cfg.args)
		-- The stdio server (tryke PR #148) has no host/port/lifecycle
		-- options — the plugin owns the spawned process end to end.
		assert.is_nil(cfg.server)
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

	it("falls back to direct for the removed auto mode", function()
		local cfg = config.get({ mode = "auto" })
		assert.equal("direct", cfg.mode)
	end)

	it("tolerates a legacy `server` table without merging defaults into it", function()
		-- Users upgrading from the TCP transport may still pass
		-- `server = {...}`; it must merge cleanly (and get ignored by the
		-- runtime) rather than error.
		local cfg = config.get({ server = { port = 9999 } })
		assert.equal(9999, cfg.server.port)
		assert.is_nil(cfg.server.host)
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
