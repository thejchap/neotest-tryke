LUA_LS ?= $(shell command -v lua-language-server 2>/dev/null || echo "$(HOME)/.local/share/nvim/mason/bin/lua-language-server")

.PHONY: test check

test:
	./test/bin/busted

check:
	$(LUA_LS) --check lua/ --configpath "$(CURDIR)/.luarc.json" --checklevel=Warning
