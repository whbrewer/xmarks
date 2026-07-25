# xmarks — bashmarks-style install.
#   make install     install to ~/.local/bin (override with PREFIX=...)
#   make uninstall   remove it

PREFIX ?= $(HOME)/.local
BINDIR  = $(PREFIX)/bin

install:
	install -d $(BINDIR)
	install -m 644 xmarks.sh $(BINDIR)/xmarks.sh
	install -m 755 xs $(BINDIR)/xs
	ln -sf xs $(BINDIR)/xg
	ln -sf xs $(BINDIR)/xl
	ln -sf xs $(BINDIR)/xd
	@echo ''
	@echo 'Installed to $(BINDIR).'
	@echo 'For the full xg (one that leaves your shell in the starred session''s'
	@echo 'directory), add this to your ~/.bashrc — above the "not interactive"'
	@echo 'guard, so that `! xs` also works inside Claude Code sessions:'
	@echo ''
	@echo '  source $(BINDIR)/xmarks.sh'
	@echo ''
	@echo 'zsh users: tab completion for xg/xs/xd needs the completion system'
	@echo 'loaded first. If your ~/.zshrc doesn'"'"'t already do this, add it'
	@echo 'before the `source` line above:'
	@echo ''
	@echo '  autoload -Uz compinit && compinit'

uninstall:
	rm -f $(BINDIR)/xmarks.sh $(BINDIR)/xs $(BINDIR)/xg $(BINDIR)/xl $(BINDIR)/xd

# Register the SessionEnd and UserPromptSubmit journal hooks in every
# ~/.claude* settings.json (backs each up to settings.json.bak first).
# Browse the journal with xl.
install-hook:
	install -m 755 hooks/xmarks-sessionend $(BINDIR)/xmarks-sessionend
	install -m 755 hooks/xmarks-summarize-async $(BINDIR)/xmarks-summarize-async
	install -m 755 hooks/xmarks-userpromptsubmit $(BINDIR)/xmarks-userpromptsubmit
	@for d in $(HOME)/.claude $(HOME)/.claude-*; do \
	  [ -d $$d ] || continue; \
	  s=$$d/settings.json; [ -f $$s ] || echo '{}' > $$s; \
	  cp $$s $$s.bak; \
	  jq --arg cmd "$(BINDIR)/xmarks-sessionend" --arg cmd2 "$(BINDIR)/xmarks-userpromptsubmit" '.hooks.SessionEnd = ((.hooks.SessionEnd // []) | map(select((.hooks[0].command // "") != $$cmd))) + [{"hooks": [{"type": "command", "command": $$cmd}]}] | .hooks.UserPromptSubmit = ((.hooks.UserPromptSubmit // []) | map(select((.hooks[0].command // "") != $$cmd2))) + [{"hooks": [{"type": "command", "command": $$cmd2}]}]' \
	    $$s.bak > $$s.new && mv $$s.new $$s && echo "hooks registered in $$s"; \
	done

uninstall-hook:
	@for d in $(HOME)/.claude $(HOME)/.claude-*; do \
	  s=$$d/settings.json; [ -f $$s ] || continue; \
	  cp $$s $$s.bak; \
	  jq --arg cmd "$(BINDIR)/xmarks-sessionend" --arg cmd2 "$(BINDIR)/xmarks-userpromptsubmit" '.hooks.SessionEnd = ((.hooks.SessionEnd // []) | map(select((.hooks[0].command // "") != $$cmd))) | .hooks.UserPromptSubmit = ((.hooks.UserPromptSubmit // []) | map(select((.hooks[0].command // "") != $$cmd2)))' \
	    $$s.bak > $$s.new && mv $$s.new $$s && echo "hooks removed from $$s"; \
	done
	rm -f $(BINDIR)/xmarks-sessionend $(BINDIR)/xmarks-summarize-async $(BINDIR)/xmarks-userpromptsubmit

.PHONY: install uninstall install-hook uninstall-hook
