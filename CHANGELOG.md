# Changelog

## Unreleased

- The shortcut opens the chat in the notch when the floating window is off.
- ⌘N starts a new chat; Shift-Return inserts a line break.
- The prompt field takes focus when a chat opens or starts.
- Optional automatic new chat after DropChat has been closed for a set time.
- Floating window: a collapsible chat list (⌃⌘S) to open, rename and delete saved chats.
- Floating window: opens scrolled to the latest message (can be turned off in settings).
- Floating window: closes when you click elsewhere, unless pinned with the new pin button.
- Holding the shortcut peeks at the chat and hides it again on release; a quick press still toggles it.
- Fix: dragging over a reply in the floating window selects its text instead of moving the window. The window moves from its header.
- Fix: starting or opening another chat while an answer streams no longer writes the stopped answer into the new chat.

## 0.1.0

- Chat on Droppy's shelf with streaming answers, reasoning summaries and tool calls.
- Providers: OpenAI, Anthropic, Google Gemini, OpenRouter and OpenAI-compatible endpoints.
- MCP servers over stdio and Streamable HTTP, with per-server approval modes and JSON import.
- Agent skills from SKILL.md folders, with optional script execution that asks every time.
- Web search and page reading through Exa or Perplexity.
- Attachments: files, drag and drop, and Finder's selection.
- Optional floating window over full-screen apps, toggled with a shortcut.
- Saved chat history.
